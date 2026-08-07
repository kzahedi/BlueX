import XCTest
@testable import BlueX

final class SQLiteConnectionTests: XCTestCase {
    /// Builds a throwaway SQLite file so the tests never touch the real store.
    private func makeFixture() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fixture.sqlite")
        let write = try SQLiteWriteHelper(at: url)
        try write.exec("CREATE TABLE T (name TEXT, n INTEGER, x REAL, maybe TEXT)")
        try write.exec("INSERT INTO T VALUES ('a', 1, 1.5, NULL), ('b', 2, 2.5, 'set')")
        try write.close()
        return url
    }

    func testReadsTypedColumns() throws {
        let url = try makeFixture()
        let conn = try SQLiteConnection(readOnlyAt: url)
        let rows = try conn.query("SELECT name, n, x, maybe FROM T ORDER BY n") { r in
            (r.text(0), r.int(1), r.double(2), r.isNull(3))
        }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].0, "a")
        XCTAssertEqual(rows[0].1, 1)
        XCTAssertEqual(rows[0].2, 1.5, accuracy: 0.0001)
        XCTAssertTrue(rows[0].3)
        XCTAssertFalse(rows[1].3)
    }

    func testBindsParameters() throws {
        let url = try makeFixture()
        let conn = try SQLiteConnection(readOnlyAt: url)
        let names = try conn.query("SELECT name FROM T WHERE n > ?", [.int(1)]) { $0.text(0) }
        XCTAssertEqual(names, ["b"])
    }

    func testRejectsWrites() throws {
        let url = try makeFixture()
        let conn = try SQLiteConnection(readOnlyAt: url)
        // A read-only connection must refuse to mutate, so a bug elsewhere can never
        // corrupt the store SwiftData owns.
        XCTAssertThrowsError(try conn.query("DELETE FROM T") { _ in 0 })
    }

    func testMissingFileThrows() {
        let missing = URL(fileURLWithPath: "/nonexistent/definitely-not-here.sqlite")
        XCTAssertThrowsError(try SQLiteConnection(readOnlyAt: missing)) { error in
            guard case SQLiteError.cannotOpen = error else {
                return XCTFail("expected cannotOpen, got \(error)")
            }
        }
    }
}
