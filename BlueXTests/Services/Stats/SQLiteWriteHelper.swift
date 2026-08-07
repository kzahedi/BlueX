import Foundation
import SQLite3
@testable import BlueX

/// Minimal writable sqlite handle, used only to build test fixtures.
struct SQLiteWriteHelper {
    private let db: OpaquePointer

    init(at url: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            throw SQLiteError.cannotOpen(url.path)
        }
        self.db = handle
    }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "unknown"
            throw SQLiteError.stepFailed(message)
        }
    }

    func close() throws { sqlite3_close(db) }
}
