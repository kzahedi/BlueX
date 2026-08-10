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
}
