import XCTest
@testable import BlueX

final class AggregateReaderPopulationTests: XCTestCase {
    private var reader: AggregateReader!

    override func setUpWithError() throws {
        reader = try AggregateReader(storeURL: try StoreFixture.make())
    }

    func testTotals() throws {
        let s = try reader.populationStats(now: StoreFixture.date("2024-04-01T00:00:00Z"))
        XCTAssertEqual(s.totalAuthors, 7)
        // 1 (did:a) + 2 (did:b) + 3 (did:c) + 9 (did:n9) + 10 (did:n10) + 99 (did:n99)
        // + 100 (did:n100)
        XCTAssertEqual(s.totalReplies, 224)
    }

    func testMedianRepliesPerAuthor() throws {
        // Reply counts sorted ascending: 1, 2, 3, 9, 10, 99, 100 (n=7, odd) — the true
        // middle element (index 3) is 9, so no upper/lower-middle ambiguity applies here.
        // The even-population convention is covered separately in
        // testMedianTakesUpperMiddleForEvenPopulation.
        let s = try reader.populationStats(now: StoreFixture.date("2024-04-01T00:00:00Z"))
        XCTAssertEqual(s.medianRepliesPerAuthor, 9)
    }

    func testMedianTakesUpperMiddleForEvenPopulation() throws {
        // Four authors, reply counts 1, 2, 3, 4 — an even-sized population. The reader's
        // documented convention takes the upper-middle element (sortedCounts[n/2] = index
        // 2), giving a median of 3, not an interpolated 2.5.
        let evenReader = try AggregateReader(storeURL: try StoreFixture.makeMedianEven())
        let s = try evenReader.populationStats(now: StoreFixture.date("2024-04-01T00:00:00Z"))
        XCTAssertEqual(s.medianRepliesPerAuthor, 3)
    }

    func testMedianAndTotalsAreZeroForEmptyPopulation() throws {
        let emptyReader = try AggregateReader(storeURL: try StoreFixture.makeEmpty())
        let s = try emptyReader.populationStats(now: StoreFixture.date("2024-04-01T00:00:00Z"))
        XCTAssertEqual(s.totalAuthors, 0)
        XCTAssertEqual(s.totalReplies, 0)
        XCTAssertEqual(s.medianRepliesPerAuthor, 0)
    }

    func testBinsCoverEveryAuthorExactlyOnce() throws {
        let s = try reader.populationStats(now: StoreFixture.date("2024-04-01T00:00:00Z"))
        XCTAssertEqual(s.bins.map(\.authors).reduce(0, +), s.totalAuthors,
                       "every author must land in exactly one bin")
        let singles = try XCTUnwrap(s.bins.first { $0.lowerBound == 1 && $0.upperBound == 1 })
        XCTAssertEqual(singles.authors, 1, "did:a has one reply")
    }

    /// Bins are 1 / 2–9 / 10–99 / 100–999 / 1000+. Summing to the total (above) is
    /// necessary but not sufficient — an off-by-one at a boundary (e.g. treating an edge
    /// as exclusive) would still sum correctly while misplacing an author. The fixture
    /// puts did:n9/did:n10 astride the 2–9 / 10–99 edge and did:n99/did:n100 astride the
    /// 10–99 / 100–999 edge specifically to catch that. The 999/1000 edge is NOT covered:
    /// exercising it would need an author with 999 or 1000 replies, i.e. ~1000 more rows
    /// in the fixture, which isn't worth the bulk for one more boundary.
    func testHistogramBoundariesNoOffByOne() throws {
        let s = try reader.populationStats(now: StoreFixture.date("2024-04-01T00:00:00Z"))
        func bin(_ label: String) throws -> HistogramBin {
            try XCTUnwrap(s.bins.first { $0.label == label })
        }
        XCTAssertEqual(try bin("2–9").authors, 3, "did:b(2), did:c(3), did:n9(9)")
        XCTAssertEqual(try bin("10–99").authors, 2, "did:n10(10), did:n99(99)")
        XCTAssertEqual(try bin("100–999").authors, 1, "did:n100(100)")
    }

    func testActiveLast30Days() throws {
        // Latest reply overall is 2024-03-01 (did:c) — every boundary author (n9/n10/n99/
        // n100) is dated in early January 2024, well outside this window either way.
        let recent = try reader.populationStats(now: StoreFixture.date("2024-03-15T00:00:00Z"))
        XCTAssertEqual(recent.activeLast30Days, 1)
        let stale = try reader.populationStats(now: StoreFixture.date("2025-01-01T00:00:00Z"))
        XCTAssertEqual(stale.activeLast30Days, 0)
    }

    func testOutletCountsSumAboveTotalBecauseAuthorsSpanOutlets() throws {
        let s = try reader.populationStats(now: StoreFixture.date("2024-04-01T00:00:00Z"))
        let summed = s.outlets.map(\.authors).reduce(0, +)
        // Outlet 1: did:b, did:c, did:n9, did:n10, did:n99, did:n100 = 6.
        // Outlet 2: did:a, did:b = 2. did:b counted under both.
        XCTAssertEqual(summed, 8, "did:b counted under both outlets")
        XCTAssertGreaterThan(summed, s.totalAuthors)
    }

    func testStatusCountsEmptyBeforeBackfill() throws {
        let s = try reader.populationStats(now: StoreFixture.date("2024-04-01T00:00:00Z"))
        XCTAssertTrue(s.statusCounts.isEmpty,
                      "ZREPLYAUTHOR is empty until the backfill runs")
    }

    func testNewAuthorsPerWeekCountsFirstAppearanceOnly() throws {
        let weeks = try reader.newAuthorsPerWeek()
        XCTAssertEqual(weeks.map(\.count).reduce(0, +), 7,
                       "each of the 7 authors is new exactly once")
        XCTAssertEqual(weeks, weeks.sorted { $0.weekStart < $1.weekStart })
    }
}
