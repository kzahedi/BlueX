import XCTest
@testable import BlueX

final class IndexPlanTests: XCTestCase {
    private let outletJoin = """
    SELECT r.ZACCOUNT, COUNT(DISTINCT p.ZAUTHORDID)
    FROM ZPOST p JOIN ZPOST r ON p.ZROOTURI = r.ZURI AND r.ZISROOTPOST = 1
    WHERE p.ZISROOTPOST = 0 GROUP BY r.ZACCOUNT
    """

    func testUnindexedFixtureScans() throws {
        let url = try StoreFixture.make()
        let reader = try AggregateReader(storeURL: url)
        let plan = try reader.explainQueryPlan(outletJoin).joined(separator: " | ")
        XCTAssertTrue(plan.contains("SCAN"), "expected a scan without indexes, got: \(plan)")
    }

    func testIndexOnRootURIIsUsed() throws {
        let url = try StoreFixture.make()
        let w = try SQLiteWriteHelper(at: url)
        try w.exec("CREATE INDEX IF NOT EXISTS IDX_ZPOST_ZURI ON ZPOST(ZURI)")
        try w.exec("CREATE INDEX IF NOT EXISTS IDX_ZPOST_ZROOTURI ON ZPOST(ZROOTURI)")
        try w.exec("CREATE INDEX IF NOT EXISTS IDX_ZPOST_ZAUTHORDID ON ZPOST(ZAUTHORDID)")
        try w.close()

        let reader = try AggregateReader(storeURL: url)
        let plan = try reader.explainQueryPlan(outletJoin).joined(separator: " | ")
        XCTAssertTrue(plan.contains("USING INDEX") || plan.contains("SEARCH"),
                      "expected the join to use an index, got: \(plan)")
    }
}
