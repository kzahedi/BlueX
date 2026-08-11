import XCTest
@testable import BlueX

final class AggregateReaderAuthorTests: XCTestCase {
    private var reader: AggregateReader!

    override func setUpWithError() throws {
        reader = try AggregateReader(storeURL: try StoreFixture.make())
    }

    /// The fixture has 8 distinct DIDs but one of them (did:root) only ever authors root
    /// posts. Root authors are the tracked outlets, not the public — counting them would
    /// inflate the population.
    func testAuthorCountExcludesRootAuthors() throws {
        XCTAssertEqual(try reader.authorCount(), 7)
    }

    func testAuthorsSortedByReplyCount() throws {
        let authors = try reader.authors(sort: .replyCount, limit: 10)
        XCTAssertEqual(authors.map(\.did),
                       ["did:n100", "did:n99", "did:n10", "did:n9", "did:c", "did:b", "did:a"])
        XCTAssertEqual(authors.map(\.replyCount), [100, 99, 10, 9, 3, 2, 1])
    }

    func testLimitCapsResultsButNotSelection() throws {
        let top = try reader.authors(sort: .replyCount, limit: 1)
        XCTAssertEqual(top.count, 1)
        // did:a is both alphabetically first and inserted first in the fixture, yet has
        // the LOWEST reply count. did:n100 is inserted last and has the HIGHEST. A query
        // that caps against encounter order instead of ranking the whole population first
        // would return did:a here, not the true top — so this assertion only holds if the
        // real implementation ranks before it limits. See StoreFixture.make() doc comment.
        XCTAssertEqual(top.first?.did, "did:n100")
    }

    func testFirstAndLastSeenSpanTheAuthorsReplies() throws {
        let c = try XCTUnwrap(try reader.authorDetail(did: "did:c"))
        XCTAssertEqual(c.firstSeen, StoreFixture.date("2024-01-01T00:00:00Z"))
        XCTAssertEqual(c.lastSeen, StoreFixture.date("2024-03-01T00:00:00Z"))
        XCTAssertEqual(c.replyCount, 3)
    }

    func testOutletCountDetectsCrossOutletAuthor() throws {
        let b = try XCTUnwrap(try reader.authorDetail(did: "did:b"))
        XCTAssertEqual(b.outletCount, 2, "did:b replies to both outlets")
        let a = try XCTUnwrap(try reader.authorDetail(did: "did:a"))
        XCTAssertEqual(a.outletCount, 1)
    }

    func testMinRepliesFilter() throws {
        let heavy = try reader.authors(sort: .replyCount, limit: 10, minReplies: 2)
        XCTAssertEqual(heavy.map(\.did),
                       ["did:n100", "did:n99", "did:n10", "did:n9", "did:c", "did:b"])
    }

    func testOutletFilter() throws {
        // Outlet 2 (did:o2) is only ever the root of did:a's one reply and one of did:b's
        // two — every boundary author (n9/n10/n99/n100) and did:c reply to outlet 1 only.
        let outletTwo = try reader.authors(sort: .replyCount, limit: 10, outletPK: 2)
        XCTAssertEqual(Set(outletTwo.map(\.did)), ["did:a", "did:b"])
    }

    func testRepliesPerWeekBucketsByISOWeek() throws {
        let weeks = try reader.repliesPerWeek(did: "did:c")
        XCTAssertEqual(weeks.map(\.count).reduce(0, +), 3)
        XCTAssertEqual(weeks.count, 3, "three replies a month apart fall in three weeks")
        XCTAssertEqual(weeks, weeks.sorted { $0.weekStart < $1.weekStart },
                       "weeks must come back in chronological order")
    }

    func testUnknownAuthorReturnsNil() throws {
        XCTAssertNil(try reader.authorDetail(did: "did:nobody"))
    }

    func testHandleIsNilWhenNotProbed() throws {
        // ZREPLYAUTHOR is empty in the fixture, mirroring the real store before probing.
        let a = try XCTUnwrap(try reader.authorDetail(did: "did:a"))
        XCTAssertNil(a.handle)
    }

    func testMaxRepliesFilter() throws {
        let light = try reader.authors(sort: .replyCount, limit: 10, maxReplies: 9)
        XCTAssertEqual(Set(light.map(\.did)), ["did:a", "did:b", "did:c", "did:n9"])
    }

    func testMinAndMaxRepliesTogether() throws {
        let mid = try reader.authors(sort: .replyCount, limit: 10, minReplies: 2, maxReplies: 9)
        XCTAssertEqual(Set(mid.map(\.did)), ["did:b", "did:c", "did:n9"])
    }

    func testMaxRepliesFilterAppliesToCountToo() throws {
        XCTAssertEqual(try reader.authorCount(minReplies: 1, maxReplies: 9, outletPK: nil), 4)
    }

    /// Pins down the deliberate join/no-join disagreement: `authors`/`authorCount` omit
    /// the join to the root post whenever there's no outlet filter to support (measured
    /// 5.2s vs. 27.8s against the live store), and that join is exactly what drops a
    /// reply whose root post never made it into the store. The two paths must therefore
    /// return the same authors EXCEPT for orphaned-reply authors, which only the unjoined
    /// (no outlet filter) path counts.
    func testUnjoinedCountIncludesOrphanedReplyAuthorsThatTheJoinedOutletFilterExcludes() throws {
        let orphanReader = try AggregateReader(storeURL: try StoreFixture.makeWithOrphanedReply())

        // Unjoined path (no outlet filter): every author who wrote a reply is counted,
        // including did:orphan, whose reply's root URI isn't in the store at all.
        XCTAssertEqual(try orphanReader.authorCount(minReplies: 1, outletPK: nil), 2)
        let unjoined = try orphanReader.authors(sort: .replyCount, limit: 10, outletPK: nil)
        XCTAssertEqual(Set(unjoined.map(\.did)), ["did:normal", "did:orphan"])

        // Joined path (outlet filter set): did:orphan's reply has no matching root row,
        // so the join silently drops it — a real semantic difference, not rounding.
        XCTAssertEqual(try orphanReader.authorCount(minReplies: 1, outletPK: 1), 1)
        let joined = try orphanReader.authors(sort: .replyCount, limit: 10, outletPK: 1)
        XCTAssertEqual(joined.map(\.did), ["did:normal"])
    }

    /// The unjoined path (no outlet filter) still reports an honest `outletCount` for
    /// each returned author — it is back-filled from a second, small query scoped to
    /// just the returned page, not silently zeroed out for lack of the join.
    func testUnjoinedPathStillReportsOutletCountCorrectly() throws {
        let b = try reader.authors(sort: .replyCount, limit: 10, outletPK: nil)
            .first { $0.did == "did:b" }
        XCTAssertEqual(b?.outletCount, 2, "did:b replies to both outlets, even off the no-join path")
    }
}
