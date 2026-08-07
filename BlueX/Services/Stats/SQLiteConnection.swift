import Foundation
import SQLite3

enum SQLValue {
    case text(String)
    case int(Int64)
    case double(Double)
}

enum SQLiteError: Error {
    case cannotOpen(String)
    case prepareFailed(String)
    case stepFailed(String)
}

/// One row of a result set. Valid only inside the row callback — it wraps a live
/// statement pointer and must not escape.
struct SQLRow {
    fileprivate let stmt: OpaquePointer

    func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    func text(_ i: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }
}

/// A read-only SQLite handle.
///
/// Why this exists: aggregating by materialising SwiftData objects was measured at
/// 2h44m for a fold the equivalent `GROUP BY` does in 0.50s. This is the read path
/// for counting. SwiftData remains the only writer.
final class SQLiteConnection {
    private let db: OpaquePointer

    init(readOnlyAt url: URL) throws {
        var handle: OpaquePointer?
        // mode=ro, never immutable=1 — immutable ignores the WAL and has already
        // reported 0 rows on a store that held 6.
        let uri = "file:\(url.path)?mode=ro"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2(uri, &handle, flags, nil) == SQLITE_OK, let handle else {
            throw SQLiteError.cannotOpen(url.path)
        }
        // sqlite3_threadsafe() reflects the compile-time SQLITE_THREADSAFE setting:
        // 0 means mutexing was omitted entirely (unsafe at any concurrency), while 1
        // or 2 both mean the mutex code is present. On this machine's system libsqlite3
        // it reports 2 (multi-thread compiled in), not 1 (serialized default) — a future
        // Sendable read layer built on this connection must not assume "serialized" from
        // this value alone. Here we only guard against the truly unsafe case.
        guard sqlite3_threadsafe() != 0 else {
            sqlite3_close(handle)
            throw SQLiteError.cannotOpen("sqlite compiled without thread-safety support")
        }
        self.db = handle
    }

    deinit { sqlite3_close(db) }

    func query<T>(_ sql: String,
                  _ bind: [SQLValue] = [],
                  row: (SQLRow) throws -> T) throws -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        // SQLITE_TRANSIENT: sqlite must copy the bytes, since Swift may free the
        // String's storage before the statement runs.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, value) in bind.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case .text(let s):   sqlite3_bind_text(stmt, index, s, -1, transient)
            case .int(let n):    sqlite3_bind_int64(stmt, index, n)
            case .double(let d): sqlite3_bind_double(stmt, index, d)
            }
        }

        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                out.append(try row(SQLRow(stmt: stmt)))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw SQLiteError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
        return out
    }
}
