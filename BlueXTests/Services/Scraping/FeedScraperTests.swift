import XCTest
import SwiftData
@testable import BlueX

final class FeedScraperTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!
    var mockSession: MockURLSession!

    override func setUpWithError() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: TrackedAccount.self, AccountGroup.self,
            Post.self, Annotation.self, AccountSnapshot.self,
            ScrapeLog.self, ModelConfig.self, CoordinatorState.self,
            configurations: config
        )
        context = ModelContext(container)
        mockSession = MockURLSession()
    }

    override func tearDownWithError() throws { container = nil; context = nil; mockSession = nil }

    // Helper: build a fake ATProtoFeedResponse with N posts for the given DID
    private func makeFeedJSON(did: String, count: Int, cursor: String? = nil) throws -> Data {
        var feedPosts: [[String: Any]] = []
        for i in 0..<count {
            feedPosts.append([
                "post": [
                    "uri": "at://\(did)/app.bsky.feed.post/post\(i)",
                    "cid": "cid\(i)",
                    "author": ["did": did, "handle": "test.de"],
                    "record": [
                        "text": "Post \(i)",
                        "createdAt": "2024-06-01T10:00:00.000Z"
                    ],
                    "indexedAt": "2024-06-01T10:00:00.000Z"
                ]
            ])
        }
        var response: [String: Any] = ["feed": feedPosts]
        if let cursor = cursor { response["cursor"] = cursor }
        return try JSONSerialization.data(withJSONObject: response)
    }

    func testScrapeSavesNewPosts() async throws {
        let did = "did:plc:testaccount"
        mockSession.mockData = try makeFeedJSON(did: did, count: 3)

        let account = TrackedAccount(did: did, handle: "test.de", displayName: "Test",
                                     startAt: Date(timeIntervalSince1970: 0))
        context.insert(account)
        try context.save()

        let client = BlueskyAPIClient(session: mockSession)
        let scraper = FeedScraper(api: client, context: context)
        let newCount = try await scraper.scrape(account: account, token: "tok")

        XCTAssertEqual(newCount, 3)
        let posts = try context.fetch(FetchDescriptor<Post>())
        XCTAssertEqual(posts.count, 3)
    }

    func testScrapeSkipsDuplicates() async throws {
        let did = "did:plc:testaccount"
        mockSession.mockData = try makeFeedJSON(did: did, count: 2)

        let account = TrackedAccount(did: did, handle: "test.de", displayName: "Test",
                                     startAt: Date(timeIntervalSince1970: 0))
        context.insert(account)

        // Pre-insert one of the posts as a duplicate
        let existing = Post(uri: "at://\(did)/app.bsky.feed.post/post0",
                           text: "Already stored", createdAt: Date(),
                           authorDID: did, authorHandle: "test.de",
                           parentURI: nil, rootURI: "at://\(did)/app.bsky.feed.post/post0",
                           isRootPost: true, depth: 0)
        context.insert(existing)
        try context.save()

        let client = BlueskyAPIClient(session: mockSession)
        let scraper = FeedScraper(api: client, context: context)
        let newCount = try await scraper.scrape(account: account, token: "tok")

        XCTAssertEqual(newCount, 1)  // only post1 is new
        let posts = try context.fetch(FetchDescriptor<Post>())
        XCTAssertEqual(posts.count, 2)  // existing + 1 new
    }

    func testScrapeCreatesCompleteLog() async throws {
        let did = "did:plc:testaccount"
        mockSession.mockData = try makeFeedJSON(did: did, count: 1)

        let account = TrackedAccount(did: did, handle: "test.de", displayName: "Test",
                                     startAt: Date(timeIntervalSince1970: 0))
        context.insert(account)
        try context.save()

        let client = BlueskyAPIClient(session: mockSession)
        let scraper = FeedScraper(api: client, context: context)
        _ = try await scraper.scrape(account: account, token: "tok")

        let logs = try context.fetch(FetchDescriptor<ScrapeLog>())
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs[0].status, "complete")
        XCTAssertNil(logs[0].resumeCursor)
        XCTAssertEqual(logs[0].postCount, 1)
    }

    func testScrapeCallsOnNewRootPostOncePerNewPost() async throws {
        let did = "did:plc:testaccount"
        mockSession.mockData = try makeFeedJSON(did: did, count: 3)

        let account = TrackedAccount(did: did, handle: "test.de", displayName: "Test",
                                     startAt: Date(timeIntervalSince1970: 0))
        context.insert(account)
        try context.save()

        let client = BlueskyAPIClient(session: mockSession)
        let scraper = FeedScraper(api: client, context: context)

        var callbackURIs: [String] = []
        let newCount = try await scraper.scrape(account: account, token: "tok") { post in
            callbackURIs.append(post.uri)
        }

        XCTAssertEqual(newCount, 3)
        XCTAssertEqual(callbackURIs.count, 3, "callback should fire once per new post (depth-first hook)")
        XCTAssertEqual(Set(callbackURIs).count, 3, "each new post delivered exactly once")
    }

    func testScrapeFiltersPostsByStartDate() async throws {
        let did = "did:plc:testaccount"
        // Feed has 1 post at 2024-06-01, account starts at 2025-01-01 → should be filtered
        mockSession.mockData = try makeFeedJSON(did: did, count: 1)

        let startDate = ISO8601DateFormatter().date(from: "2025-01-01T00:00:00Z")!
        let account = TrackedAccount(did: did, handle: "test.de", displayName: "Test", startAt: startDate)
        context.insert(account)
        try context.save()

        let client = BlueskyAPIClient(session: mockSession)
        let scraper = FeedScraper(api: client, context: context)
        let newCount = try await scraper.scrape(account: account, token: "tok")

        XCTAssertEqual(newCount, 0)  // post is before startDate
    }

    // MARK: - Stale-cursor bug (2026-08-13 – 2026-08-19 data loss)
    //
    // Root cause: a pass that completes successfully only clears the cursor on
    // the log IT created. Any older `failed` log with a live `resumeCursor` is
    // left untouched, so every subsequent pass re-resumes from that same stale
    // cursor forever. `getAuthorFeed` pages newest→oldest, so resuming at an old
    // cursor walks only deeper into already-stored history — the top of the feed
    // (all new posts) is never visited again, and the pass "succeeds" having
    // found zero new posts. Six days, five outlets, zero new roots stored.

    private func extractCursor(from request: URLRequest) -> String? {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        return components.queryItems?.first(where: { $0.name == "cursor" })?.value
    }

    func testCompletedResumePassClearsStaleCursorSoNextPassStartsFresh() async throws {
        let did = "did:plc:testaccount"
        let account = TrackedAccount(did: did, handle: "test.de", displayName: "Test",
                                     startAt: Date(timeIntervalSince1970: 0))
        context.insert(account)
        try context.save()

        let client = BlueskyAPIClient(session: mockSession)
        let scraper = FeedScraper(api: client, context: context)

        // --- Pass A: page 1 succeeds and hands back a cursor, page 2 fails ---
        // (mid-walk interruption; the log is left `failed` with a live cursor).
        mockSession.scriptedResponses = [
            .init(data: try makeFeedJSON(did: did, count: 1, cursor: "cursorA"), statusCode: 200),
            .init(data: Data(), statusCode: 500)
        ]
        do {
            _ = try await scraper.scrape(account: account, token: "tok")
            XCTFail("expected pass A to throw on the page-2 failure")
        } catch {
            // expected
        }

        let logsAfterA = try context.fetch(FetchDescriptor<ScrapeLog>())
        XCTAssertEqual(logsAfterA.count, 1)
        XCTAssertEqual(logsAfterA[0].status, "failed")
        XCTAssertEqual(logsAfterA[0].resumeCursor, "cursorA")

        // --- Pass B: resumes from cursorA, completes cleanly (empty final page) ---
        mockSession.capturedRequests = []
        mockSession.scriptedResponses = [
            .init(data: try makeFeedJSON(did: did, count: 0, cursor: nil), statusCode: 200)
        ]
        let newCountB = try await scraper.scrape(account: account, token: "tok")
        XCTAssertEqual(newCountB, 0)
        XCTAssertEqual(extractCursor(from: mockSession.capturedRequests.first!), "cursorA",
                       "pass B should resume from the stale cursor left by pass A")

        // The OLD log from pass A must have its cursor cleared too, not just the
        // new log pass B created for itself.
        let logsAfterB = try context.fetch(FetchDescriptor<ScrapeLog>(sortBy: [SortDescriptor(\.date)]))
        XCTAssertEqual(logsAfterB.count, 2)
        for log in logsAfterB {
            XCTAssertNil(log.resumeCursor, "every incomplete log for this account must be cleared once a pass completes")
        }

        // --- Pass C: must start from the TOP of the feed, not the stale cursor ---
        mockSession.capturedRequests = []
        mockSession.scriptedResponses = [
            .init(data: try makeFeedJSON(did: did, count: 0, cursor: nil), statusCode: 200)
        ]
        _ = try await scraper.scrape(account: account, token: "tok")

        XCTAssertEqual(mockSession.capturedRequests.count, 1)
        XCTAssertNil(extractCursor(from: mockSession.capturedRequests.first!),
                    "pass C's first request must have cursor == nil — the top of the feed — " +
                    "not the stale cursor from pass A. Resuming it here is the Aug 13–19 data-loss bug.")
    }

    func testTwoStaleLogsBothClearedByOneCompletedPass() async throws {
        let did = "did:plc:testaccount"
        let account = TrackedAccount(did: did, handle: "test.de", displayName: "Test",
                                     startAt: Date(timeIntervalSince1970: 0))
        context.insert(account)

        let staleLog1 = ScrapeLog(date: Date().addingTimeInterval(-3600), type: "feed",
                                  status: "failed", postCount: 0, resumeCursor: "oldCursor1")
        staleLog1.account = account
        let staleLog2 = ScrapeLog(date: Date().addingTimeInterval(-1800), type: "feed",
                                  status: "failed", postCount: 0, resumeCursor: "oldCursor2")
        staleLog2.account = account
        context.insert(staleLog1)
        context.insert(staleLog2)
        try context.save()

        mockSession.mockData = try makeFeedJSON(did: did, count: 0, cursor: nil)

        let client = BlueskyAPIClient(session: mockSession)
        let scraper = FeedScraper(api: client, context: context)
        _ = try await scraper.scrape(account: account, token: "tok")

        XCTAssertNil(staleLog1.resumeCursor)
        XCTAssertNil(staleLog2.resumeCursor)
        // status is left as the historical record — only the cursor is cleared
        XCTAssertEqual(staleLog1.status, "failed")
        XCTAssertEqual(staleLog2.status, "failed")
    }

    // MARK: - 48h staleness guard on the read side

    func testIncompleteLogOlderThan48HoursIsIgnoredOnResume() async throws {
        let did = "did:plc:testaccount"
        let account = TrackedAccount(did: did, handle: "test.de", displayName: "Test",
                                     startAt: Date(timeIntervalSince1970: 0))
        context.insert(account)

        let fixedNow = Date(timeIntervalSince1970: 1_000_000)
        let ancientLog = ScrapeLog(date: fixedNow.addingTimeInterval(-3 * 24 * 3600), type: "feed",
                                   status: "failed", postCount: 0, resumeCursor: "ancientCursor")
        ancientLog.account = account
        context.insert(ancientLog)
        try context.save()

        mockSession.mockData = try makeFeedJSON(did: did, count: 0, cursor: nil)

        let client = BlueskyAPIClient(session: mockSession)
        let scraper = FeedScraper(api: client, context: context, now: { fixedNow })
        _ = try await scraper.scrape(account: account, token: "tok")

        XCTAssertEqual(mockSession.capturedRequests.count, 1)
        XCTAssertNil(extractCursor(from: mockSession.capturedRequests.first!),
                    "a 3-day-old cursor is ancient and must be ignored")
    }

    func testIncompleteLogWithinLast48HoursIsStillUsedOnResume() async throws {
        let did = "did:plc:testaccount"
        let account = TrackedAccount(did: did, handle: "test.de", displayName: "Test",
                                     startAt: Date(timeIntervalSince1970: 0))
        context.insert(account)

        let fixedNow = Date(timeIntervalSince1970: 1_000_000)
        let recentLog = ScrapeLog(date: fixedNow.addingTimeInterval(-3600), type: "feed",
                                  status: "failed", postCount: 0, resumeCursor: "recentCursor")
        recentLog.account = account
        context.insert(recentLog)
        try context.save()

        mockSession.mockData = try makeFeedJSON(did: did, count: 0, cursor: nil)

        let client = BlueskyAPIClient(session: mockSession)
        let scraper = FeedScraper(api: client, context: context, now: { fixedNow })
        _ = try await scraper.scrape(account: account, token: "tok")

        XCTAssertEqual(mockSession.capturedRequests.count, 1)
        XCTAssertEqual(extractCursor(from: mockSession.capturedRequests.first!), "recentCursor",
                       "a 1-hour-old cursor is fresh and should still be resumed")
    }
}
