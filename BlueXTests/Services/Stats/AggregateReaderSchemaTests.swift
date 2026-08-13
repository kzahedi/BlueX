import XCTest
@testable import BlueX

final class AggregateReaderSchemaTests: XCTestCase {
    func testAcceptsExpectedSchema() throws {
        let url = try StoreFixture.make()
        let reader = try AggregateReader(storeURL: url)
        XCTAssertNoThrow(try reader.verifySchema())
    }

    /// The reader queries Core Data's private Z-schema, which Apple does not promise to
    /// keep stable. A model change must fail loudly here rather than silently returning
    /// wrong numbers on a dashboard.
    func testRejectsMissingColumn() throws {
        let url = try StoreFixture.make()
        let w = try SQLiteWriteHelper(at: url)
        try w.exec("ALTER TABLE ZPOST DROP COLUMN ZAUTHORDID")
        try w.close()

        let reader = try AggregateReader(storeURL: url)
        XCTAssertThrowsError(try reader.verifySchema()) { error in
            guard case AggregateError.schemaMismatch(let detail) = error else {
                return XCTFail("expected schemaMismatch, got \(error)")
            }
            XCTAssertTrue(detail.contains("ZAUTHORDID"),
                          "the message must name the missing column, got: \(detail)")
        }
    }

    func testRejectsMissingTable() throws {
        let url = try StoreFixture.make()
        let w = try SQLiteWriteHelper(at: url)
        try w.exec("DROP TABLE ZREPLYAUTHOR")
        try w.close()

        let reader = try AggregateReader(storeURL: url)
        XCTAssertThrowsError(try reader.verifySchema()) { error in
            guard case AggregateError.schemaMismatch(let detail) = error else {
                return XCTFail("expected schemaMismatch, got \(error)")
            }
            XCTAssertTrue(detail.contains("ZREPLYAUTHOR"))
        }
    }

    // MARK: - Index health

    /// `StoreFixture.make()` never creates the hand-made indexes, so a fresh fixture
    /// must report degraded — this is the honest baseline `indexHealth()` promises:
    /// a read-only reader never assumes indexes exist just because the tables do.
    func testIndexHealthDegradedWhenIndexesAreMissing() throws {
        let url = try StoreFixture.make()
        let reader = try AggregateReader(storeURL: url)
        let health = try reader.indexHealth()
        XCTAssertFalse(health.isHealthy)
        XCTAssertEqual(Set(health.missing), Set(StoreIndexPlan.names))
    }

    /// Once every planned index exists in `sqlite_master`, the checker reports
    /// healthy — using `StoreIndexPlan.all` itself to build them, not a hand-copied
    /// literal list, so this test can't pass by coincidence if the checker and the
    /// creator ever diverge.
    func testIndexHealthHealthyWhenAllIndexesPresent() throws {
        let url = try StoreFixture.make()
        let w = try SQLiteWriteHelper(at: url)
        for index in StoreIndexPlan.all {
            try w.exec(index.createSQL)
        }
        try w.close()

        let reader = try AggregateReader(storeURL: url)
        let health = try reader.indexHealth()
        XCTAssertTrue(health.isHealthy, "expected healthy, missing: \(health.missing)")
        XCTAssertEqual(health.missing, [])
    }

    /// Exactly one index missing must be named, not just flagged — a human
    /// diagnosing a slow dashboard needs to know which one to look for.
    func testIndexHealthNamesExactlyWhatIsMissing() throws {
        let url = try StoreFixture.make()
        let w = try SQLiteWriteHelper(at: url)
        for index in StoreIndexPlan.all where index.name != "IDX_ZPOST_ZROOTURI" {
            try w.exec(index.createSQL)
        }
        try w.close()

        let reader = try AggregateReader(storeURL: url)
        let health = try reader.indexHealth()
        XCTAssertEqual(health.missing, ["IDX_ZPOST_ZROOTURI"])
    }
}
