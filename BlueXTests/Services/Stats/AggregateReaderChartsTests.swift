import XCTest
@testable import BlueX

/// Covers the SQL aggregates that replace materialising ~2.15M `Post` objects per
/// account click: weekly reply/root buckets, ISO-week bucketing, and the reply-count
/// range filter behind `rootPosts`.
final class AggregateReaderChartsTests: XCTestCase {
    private var reader: AggregateReader!

    override func setUpWithError() throws {
        reader = try AggregateReader(storeURL: try StoreFixture.make())
    }

    // MARK: - repliesPerWeek / rootPostsPerWeek

    func testRepliesPerWeekSumsToAllRepliesOnOwnedRoots() throws {
        // Account 1 owns only root r1. Its replies: did:c x3, did:n9 x9, did:n10 x10,
        // did:n99 x99, did:n100 x100, did:b x1 = 222, matching
        // AggregateReaderPopulationTests' 224 total minus the 2 replies to r2 (owned by
        // account 2: did:a x1, did:b x1).
        let weeks = try reader.repliesPerWeek(accountPKs: [1])
        XCTAssertEqual(weeks.map(\.count).reduce(0, +), 222)
        XCTAssertEqual(weeks.map(\.weekStart), weeks.map(\.weekStart).sorted(),
                       "buckets must come back in ascending week order")
    }

    func testRepliesPerWeekAcrossMultipleAccountsUnionsTheirRoots() throws {
        let weeks = try reader.repliesPerWeek(accountPKs: [1, 2])
        // 222 (account 1's r1) + 2 (account 2's r2: did:a, did:b) = 224.
        XCTAssertEqual(weeks.map(\.count).reduce(0, +), 224)
    }

    func testRepliesPerWeekEmptyAccountListReturnsNoBuckets() throws {
        XCTAssertEqual(try reader.repliesPerWeek(accountPKs: []), [])
    }

    func testRepliesPerWeekUnknownAccountReturnsNoBuckets() throws {
        XCTAssertEqual(try reader.repliesPerWeek(accountPKs: [999]), [])
    }

    func testRootPostsPerWeekCountsOnlyRootsForThatAccount() throws {
        // Account 1 owns exactly one root (r1, 2024-01-01).
        let weeks = try reader.rootPostsPerWeek(accountPKs: [1])
        XCTAssertEqual(weeks.map(\.count).reduce(0, +), 1)
    }

    func testRootPostsPerWeekAcrossMultipleAccounts() throws {
        // Account 1 owns r1, account 2 owns r2 — both created 2024-01-01, same ISO week.
        let weeks = try reader.rootPostsPerWeek(accountPKs: [1, 2])
        XCTAssertEqual(weeks.map(\.count).reduce(0, +), 2)
    }

    func testRootPostsPerWeekEmptyAccountListReturnsNoBuckets() throws {
        XCTAssertEqual(try reader.rootPostsPerWeek(accountPKs: []), [])
    }

    // MARK: - weekly bucketing

    func testWeeklyBucketsAreMondayAligned() {
        // Noon, not midnight, deliberately: a midnight UTC stamp can cross the local-
        // timezone day boundary the production Calendar(identifier: .iso8601) uses (it
        // has no explicit .timeZone override, so it reads the system zone), which would
        // make this test flaky rather than pinning down bucketing behaviour. Assert
        // against the same calendar computation the implementation uses, rather than a
        // literal UTC string, so the test verifies bucketing (one stamp -> one bucket
        // whose start is the week's Monday) without also asserting a specific timezone.
        let wednesday = StoreFixture.date("2024-01-03T12:00:00Z")
        let calendar = Calendar(identifier: .iso8601)
        let expectedStart = calendar.dateInterval(of: .weekOfYear, for: wednesday)!.start
        let buckets = AggregateReader.weekly([wednesday])
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets[0].weekStart, expectedStart)
    }

    func testWeeklyGroupsStampsInTheSameWeekTogether() {
        // Noon (not midnight) stamps, for the same local-timezone-boundary reason as
        // testWeeklyBucketsAreMondayAligned above.
        let stamps = [
            StoreFixture.date("2024-01-01T12:00:00Z"), // Mon
            StoreFixture.date("2024-01-07T12:00:00Z"), // Sun, same ISO week
            StoreFixture.date("2024-01-08T12:00:00Z"), // Mon, next week
        ]
        let buckets = AggregateReader.weekly(stamps)
        XCTAssertEqual(buckets.count, 2)
        XCTAssertEqual(buckets.map(\.count), [2, 1])
    }

    func testWeeklyReturnsBucketsInAscendingOrder() {
        let stamps = [
            StoreFixture.date("2024-03-01T00:00:00Z"),
            StoreFixture.date("2024-01-01T00:00:00Z"),
            StoreFixture.date("2024-02-01T00:00:00Z"),
        ]
        let buckets = AggregateReader.weekly(stamps)
        XCTAssertEqual(buckets.map(\.weekStart), buckets.map(\.weekStart).sorted())
    }

    func testWeeklyOfEmptyStampsIsEmpty() {
        XCTAssertTrue(AggregateReader.weekly([]).isEmpty)
    }

    // MARK: - rootPosts (reply-count range filter)

    func testRootPostsWithNoFilterIncludesZeroReplyRoots() throws {
        let countsReader = try AggregateReader(storeURL: try StoreFixture.makeRootPostCounts())
        let roots = try countsReader.rootPosts(accountPK: 1, limit: 10)
        XCTAssertEqual(roots.count, 5, "all five roots, including the one with zero replies")
        let zero = try XCTUnwrap(roots.first { $0.uri == "at://z0" })
        XCTAssertEqual(zero.replyCount, 0)
    }

    func testRootPostsOrdersByReplyCountDescending() throws {
        let countsReader = try AggregateReader(storeURL: try StoreFixture.makeRootPostCounts())
        let roots = try countsReader.rootPosts(accountPK: 1, limit: 10)
        XCTAssertEqual(roots.map(\.replyCount), [120, 75, 50, 3, 0])
    }

    func testRootPostsMinRepliesIsInclusiveOfTheBoundary() throws {
        let countsReader = try AggregateReader(storeURL: try StoreFixture.makeRootPostCounts())
        let roots = try countsReader.rootPosts(accountPK: 1, minReplies: 50, limit: 10)
        XCTAssertEqual(roots.map(\.replyCount).sorted(), [50, 75, 120],
                       "50 sits exactly on the boundary and must be included")
    }

    func testRootPostsMinAndMaxRepliesTogetherFormARange() throws {
        let countsReader = try AggregateReader(storeURL: try StoreFixture.makeRootPostCounts())
        let roots = try countsReader.rootPosts(accountPK: 1, minReplies: 50, maxReplies: 100,
                                                limit: 10)
        XCTAssertEqual(roots.map(\.replyCount).sorted(), [50, 75],
                       "120 exceeds maxReplies and must be excluded")
    }

    func testRootPostsAbsentMaxRepliesIsUnboundedNotASilentCap() throws {
        let countsReader = try AggregateReader(storeURL: try StoreFixture.makeRootPostCounts())
        let roots = try countsReader.rootPosts(accountPK: 1, minReplies: 100, limit: 10)
        XCTAssertEqual(roots.map(\.replyCount), [120],
                       "no maxReplies means unbounded — 120 must not be capped out")
    }

    func testRootPostsLimitCapsResultsAfterOrdering() throws {
        let countsReader = try AggregateReader(storeURL: try StoreFixture.makeRootPostCounts())
        let roots = try countsReader.rootPosts(accountPK: 1, limit: 2)
        XCTAssertEqual(roots.map(\.replyCount), [120, 75],
                       "limit applies to the ranked result, not an arbitrary subset")
    }

    func testRootPostsUnknownAccountReturnsNoRoots() throws {
        let countsReader = try AggregateReader(storeURL: try StoreFixture.makeRootPostCounts())
        XCTAssertTrue(try countsReader.rootPosts(accountPK: 999, limit: 10).isEmpty)
    }

    func testRootPostsCarriesUriTextAndCreatedAt() throws {
        let countsReader = try AggregateReader(storeURL: try StoreFixture.makeRootPostCounts())
        let roots = try countsReader.rootPosts(accountPK: 1, minReplies: 120, limit: 10)
        let top = try XCTUnwrap(roots.first)
        XCTAssertEqual(top.uri, "at://z4")
        XCTAssertEqual(top.text, "text")
        XCTAssertEqual(top.createdAt, StoreFixture.date("2024-01-05T00:00:00Z"))
    }

    func testRootPostsCarriesReplyTreeStatus() throws {
        // The fixture defaults every ZPOST row's ZREPLYTREESTATUS to 'complete'.
        let countsReader = try AggregateReader(storeURL: try StoreFixture.makeRootPostCounts())
        let roots = try countsReader.rootPosts(accountPK: 1, limit: 10)
        XCTAssertTrue(roots.allSatisfy { $0.replyTreeStatus == "complete" },
                      "small trees are a lower bound, not necessarily quiet — the scrape " +
                      "status must ride along so the UI can tell the two apart")
    }

    // MARK: - rootPostCount

    func testRootPostCountMatchesTheRowCountOfRootPostsForTheSameFilter() throws {
        let countsReader = try AggregateReader(storeURL: try StoreFixture.makeRootPostCounts())
        let count = try countsReader.rootPostCount(accountPK: 1, minReplies: 50, maxReplies: 100)
        XCTAssertEqual(count, 2, "50 and 75 fall in range; 3, 0 and 120 do not")
    }

    func testRootPostCountWithNoFilterCountsAllRootsIncludingZeroReplies() throws {
        let countsReader = try AggregateReader(storeURL: try StoreFixture.makeRootPostCounts())
        XCTAssertEqual(try countsReader.rootPostCount(accountPK: 1), 5)
    }

    func testRootPostCountAbsentMaxIsUnbounded() throws {
        let countsReader = try AggregateReader(storeURL: try StoreFixture.makeRootPostCounts())
        XCTAssertEqual(try countsReader.rootPostCount(accountPK: 1, minReplies: 100), 1,
                       "only 120 has 100+ replies; no maxReplies must not cap it out")
    }

    func testRootPostCountUnknownAccountIsZero() throws {
        let countsReader = try AggregateReader(storeURL: try StoreFixture.makeRootPostCounts())
        XCTAssertEqual(try countsReader.rootPostCount(accountPK: 999), 0)
    }

    // MARK: - accountPK

    func testAccountPKResolvesByDID() throws {
        XCTAssertEqual(try reader.accountPK(did: "did:o1"), 1)
        XCTAssertEqual(try reader.accountPK(did: "did:o2"), 2)
    }

    func testAccountPKUnknownDIDReturnsNil() throws {
        XCTAssertNil(try reader.accountPK(did: "did:does-not-exist"))
    }
}
