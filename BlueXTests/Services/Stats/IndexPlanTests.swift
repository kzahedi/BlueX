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
        // "SCAN" alone is too weak: the indexed plan below also scans `p` (SQLite
        // always table-scans the outer side of this join), and SQLite's own
        // AUTOMATIC PARTIAL COVERING INDEX for the unindexed join already contains
        // the substring "SEARCH" — so neither of those alone distinguishes "no real
        // index" from "index in use". Assert the absence of the specific hand-made
        // index by name instead; that is what actually changes between the two tests.
        XCTAssertFalse(plan.contains("USING INDEX IDX_ZPOST"),
                       "expected no hand-made index to be used before one exists, got: \(plan)")
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
        // Assert on the specific index by name, not on "SEARCH" or "USING INDEX"
        // alone: SQLite's automatic covering index for the *unindexed* case also
        // emits a "SEARCH ... USING AUTOMATIC PARTIAL COVERING INDEX" line, which
        // contains the substring "SEARCH" but never "USING INDEX IDX_ZPOST_ZURI" —
        // measured directly from EXPLAIN QUERY PLAN output (see fix report in
        // task-3-report.md). Only the real, named index satisfies this.
        XCTAssertTrue(plan.contains("USING INDEX IDX_ZPOST_ZURI"),
                      "expected the join to use IDX_ZPOST_ZURI by name, got: \(plan)")
    }
}
