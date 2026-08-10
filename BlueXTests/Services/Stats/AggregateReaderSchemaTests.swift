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
}
