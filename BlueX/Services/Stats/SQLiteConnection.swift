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
    /// Thrown by an `SQLRow` accessor called after the row callback that produced it has
    /// returned. The row wraps a live statement pointer that is only valid for the
    /// duration of that one callback invocation; using it later would read a finalized
    /// (or reused, on the next iteration) statement. See `SQLRow` below.
    case rowUsedAfterCallback
}

/// One row of a result set, handed to the callback passed to `SQLiteConnection.query`.
///
/// It wraps a live statement pointer that is only valid for the duration of that single
/// callback invocation — the pointer is reused (or finalized) on the very next loop
/// iteration. Swift 5.9 has no type-level way to forbid the callback from stashing this
/// object somewhere and reading it later, so instead it enforces the rule at runtime:
/// every accessor throws `SQLiteError.rowUsedAfterCallback` once the row has been
/// invalidated (which `SQLiteConnection.query` does immediately after each callback
/// returns). A caller that lets an `SQLRow` escape its callback gets a legible failure
/// instead of undefined behaviour on a stale or finalized pointer.
final class SQLRow {
    fileprivate let stmt: OpaquePointer
    fileprivate var isValid = true

    fileprivate init(stmt: OpaquePointer) {
        self.stmt = stmt
    }

    private func checkValid() throws {
        guard isValid else { throw SQLiteError.rowUsedAfterCallback }
    }

    func int(_ i: Int32) throws -> Int64 {
        try checkValid()
        return sqlite3_column_int64(stmt, i)
    }

    func double(_ i: Int32) throws -> Double {
        try checkValid()
        return sqlite3_column_double(stmt, i)
    }

    func isNull(_ i: Int32) throws -> Bool {
        try checkValid()
        return sqlite3_column_type(stmt, i) == SQLITE_NULL
    }

    func text(_ i: Int32) throws -> String? {
        try checkValid()
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
        //
        // sqlite3_threadsafe() reports the library's compile-time default, and on
        // this platform's system libsqlite3 that default is 2 (Multi-thread), not 1
        // (Serialized) — so we cannot rely on the default. SQLITE_OPEN_FULLMUTEX
        // requests serialized threading mode for THIS connection specifically,
        // regardless of that default, as long as the library was built with mutex
        // support at all (sqlite3_threadsafe() != 0). That is the guard below, and
        // it is the precondition a future Sendable read layer on this connection can
        // actually rely on — the serialization comes from FULLMUTEX on the open call,
        // not from the library default.
        let uri = "file:\(url.path)?mode=ro"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_threadsafe() != 0 else {
            throw SQLiteError.cannotOpen("sqlite compiled without thread-safety support")
        }
        // sqlite3_open_v2 may allocate a handle even when it returns an error — the
        // caller is expected to sqlite3_close it regardless of the return code. Bind
        // the success case to a *new* name (openedHandle) rather than shadowing
        // `handle`, so the failure branch can still see and close whatever
        // sqlite3_open_v2 put in `handle`, and so we can read sqlite3_errmsg on it
        // before closing — a bare path string says nothing about why the open failed.
        let rc = sqlite3_open_v2(uri, &handle, flags, nil)
        guard rc == SQLITE_OK, let openedHandle = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) }
                ?? "sqlite3_open_v2 returned code \(rc)"
            if let handle {
                sqlite3_close(handle)
            }
            throw SQLiteError.cannotOpen("\(url.path): \(message)")
        }
        self.db = openedHandle
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
                let sqlRow = SQLRow(stmt: stmt)
                defer { sqlRow.isValid = false }
                out.append(try row(sqlRow))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw SQLiteError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
        return out
    }
}
