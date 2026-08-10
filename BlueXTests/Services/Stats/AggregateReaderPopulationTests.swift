import XCTest
@testable import BlueX

final class AggregateReaderPopulationTests: XCTestCase {
    private var reader: AggregateReader!

    override func setUpWithError() throws {
        reader = try AggregateReader(storeURL: try StoreFixture.make())
    }

    func testTotals() throws {
        let s = try reader.populationStats(now: StoreFixture.date("2024-04-01T00:00:00Z"))
        XCTAssertEqual(s.totalAuthors, 3)
        XCTAssertEqual(s.totalReplies, 6)
    }

    func testMedianRepliesPerAuthor() throws {
        // Reply counts are 3, 2, 1 — median 2.
        let s = try reader.populationStats(now: StoreFixture.date("2024-04-01T00:00:00Z"))
        XCTAssertEqual(s.medianRepliesPerAuthor, 2)
    }

    func testBinsCoverEveryAuthorExactlyOnce() throws {
        let s = try reader.populationStats(now: StoreFixture.date("2024-04-01T00:00:00Z"))
        XCTAssertEqual(s.bins.map(\.authors).reduce(0, +), s.totalAuthors,
                       "every author must land in exactly one bin")
        let singles = try XCTUnwrap(s.bins.first { $0.lowerBound == 1 && $0.upperBound == 1 })
        XCTAssertEqual(singles.authors, 1, "did:c has one reply")
    }

    func testActiveLast30Days() throws {
        // Latest reply overall is 2024-03-01 (did:a).
        let recent = try reader.populationStats(now: StoreFixture.date("2024-03-15T00:00:00Z"))
        XCTAssertEqual(recent.activeLast30Days, 1)
        let stale = try reader.populationStats(now: StoreFixture.date("2025-01-01T00:00:00Z"))
        XCTAssertEqual(stale.activeLast30Days, 0)
    }

    func testOutletCountsSumAboveTotalBecauseAuthorsSpanOutlets() throws {
        let s = try reader.populationStats(now: StoreFixture.date("2024-04-01T00:00:00Z"))
        let summed = s.outlets.map(\.authors).reduce(0, +)
        XCTAssertEqual(summed, 4, "did:b counted under both outlets")
        XCTAssertGreaterThan(summed, s.totalAuthors)
    }

    func testStatusCountsEmptyBeforeBackfill() throws {
        let s = try reader.populationStats(now: StoreFixture.date("2024-04-01T00:00:00Z"))
        XCTAssertTrue(s.statusCounts.isEmpty,
                      "ZREPLYAUTHOR is empty until the backfill runs")
    }

    func testNewAuthorsPerWeekCountsFirstAppearanceOnly() throws {
        let weeks = try reader.newAuthorsPerWeek()
        XCTAssertEqual(weeks.map(\.count).reduce(0, +), 3,
                       "each author is new exactly once")
        XCTAssertEqual(weeks, weeks.sorted { $0.weekStart < $1.weekStart })
    }
}
