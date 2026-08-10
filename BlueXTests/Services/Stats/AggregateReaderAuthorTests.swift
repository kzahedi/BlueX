import XCTest
@testable import BlueX

final class AggregateReaderAuthorTests: XCTestCase {
    private var reader: AggregateReader!

    override func setUpWithError() throws {
        reader = try AggregateReader(storeURL: try StoreFixture.make())
    }

    /// The fixture has 4 distinct DIDs but one of them only ever authors root posts.
    /// Root authors are the tracked outlets, not the public — counting them would
    /// inflate the population.
    func testAuthorCountExcludesRootAuthors() throws {
        XCTAssertEqual(try reader.authorCount(), 3)
    }

    func testAuthorsSortedByReplyCount() throws {
        let authors = try reader.authors(sort: .replyCount, limit: 10)
        XCTAssertEqual(authors.map(\.did), ["did:a", "did:b", "did:c"])
        XCTAssertEqual(authors.map(\.replyCount), [3, 2, 1])
    }

    func testLimitCapsResultsButNotSelection() throws {
        let top = try reader.authors(sort: .replyCount, limit: 1)
        XCTAssertEqual(top.count, 1)
        // The cap must select the top of the whole population, not the first row found.
        XCTAssertEqual(top.first?.did, "did:a")
    }

    func testFirstAndLastSeenSpanTheAuthorsReplies() throws {
        let a = try XCTUnwrap(try reader.authorDetail(did: "did:a"))
        XCTAssertEqual(a.firstSeen, StoreFixture.date("2024-01-01T00:00:00Z"))
        XCTAssertEqual(a.lastSeen, StoreFixture.date("2024-03-01T00:00:00Z"))
        XCTAssertEqual(a.replyCount, 3)
    }

    func testOutletCountDetectsCrossOutletAuthor() throws {
        let b = try XCTUnwrap(try reader.authorDetail(did: "did:b"))
        XCTAssertEqual(b.outletCount, 2, "did:b replies to both outlets")
        let a = try XCTUnwrap(try reader.authorDetail(did: "did:a"))
        XCTAssertEqual(a.outletCount, 1)
    }

    func testMinRepliesFilter() throws {
        let heavy = try reader.authors(sort: .replyCount, limit: 10, minReplies: 2)
        XCTAssertEqual(heavy.map(\.did), ["did:a", "did:b"])
    }

    func testOutletFilter() throws {
        let outletTwo = try reader.authors(sort: .replyCount, limit: 10, outletPK: 2)
        XCTAssertEqual(Set(outletTwo.map(\.did)), ["did:b", "did:c"])
    }

    func testRepliesPerWeekBucketsByISOWeek() throws {
        let weeks = try reader.repliesPerWeek(did: "did:a")
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
