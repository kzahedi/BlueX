import Foundation

enum AggregateError: Error {
    case schemaMismatch(String)
}

/// Every SQL statement in the app lives here.
///
/// The reader queries Core Data's private Z-prefixed schema, which Apple does not
/// contract to keep stable. `verifySchema()` is the guard: a model change fails a test
/// instead of quietly producing wrong dashboard numbers.
///
/// **Concurrency.** This wraps a raw `sqlite3` handle, which Swift cannot prove is
/// `Sendable`, so the type is marked `@unchecked Sendable` to let view models hand it to
/// `Task.detached`.
///
/// That is sound because `SQLiteConnection` opens with `SQLITE_OPEN_FULLMUTEX`, which
/// puts *that connection* in serialized threading mode, so SQLite serialises concurrent
/// use internally.
///
/// **Measured 2026-08-07, correcting an earlier claim in this plan:** macOS system
/// libsqlite3 returns `sqlite3_threadsafe() == 2` — Multi-thread, **not** Serialized.
/// Serialized is therefore *not* the library default here, and an earlier draft of this
/// plan wrongly told Task 1 to assert `== 1`. The guarantee comes from the per-connection
/// `FULLMUTEX` flag; the open-time guard only asserts the weaker precondition that
/// mutexes were compiled in at all (`sqlite3_threadsafe() != 0`).
final class AggregateReader: @unchecked Sendable {
    /// Core Data stores dates as seconds since 2001-01-01.
    static let coreDataEpochOffset: TimeInterval = 978_307_200

    private let conn: SQLiteConnection

    init(storeURL: URL) throws {
        self.conn = try SQLiteConnection(readOnlyAt: storeURL)
    }

    /// Convenience for the app: opens against the configured store.
    convenience init() throws {
        try self.init(storeURL: BlueXStore.url)
    }

    // MARK: - Schema guard

    private static let required: [String: [String]] = [
        "ZPOST": ["ZURI", "ZCREATEDAT", "ZAUTHORDID", "ZAUTHORHANDLE",
                  "ZROOTURI", "ZISROOTPOST", "ZACCOUNT"],
        "ZTRACKEDACCOUNT": ["Z_PK", "ZHANDLE"],
        "ZREPLYAUTHOR": ["ZDID", "ZFIRSTSEENAT", "ZLASTSEENAT",
                         "ZCURRENTHANDLE", "ZCURRENTSTATUS", "ZLASTPROBEDAT"],
    ]

    func verifySchema() throws {
        for (table, columns) in Self.required.sorted(by: { $0.key < $1.key }) {
            let present = try conn.query(
                "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
                [.text(table)]
            ) { try $0.text(0) }
            guard !present.isEmpty else {
                throw AggregateError.schemaMismatch("missing table \(table)")
            }
            let actual = Set(try conn.query("PRAGMA table_info(\(table))") { try $0.text(1) }
                .compactMap { $0 })
            for column in columns where !actual.contains(column) {
                throw AggregateError.schemaMismatch("missing column \(table).\(column)")
            }
        }
    }

    // MARK: - Query plan inspection

    /// Returns SQLite's plan for a statement. Used to prove an index is actually used
    /// rather than assumed.
    func explainQueryPlan(_ sql: String) throws -> [String] {
        try conn.query("EXPLAIN QUERY PLAN \(sql)") { try $0.text(3) ?? "" }
    }

    // MARK: - Date helpers

    static func date(fromCoreData seconds: Double) -> Date {
        Date(timeIntervalSince1970: seconds + coreDataEpochOffset)
    }

    static func coreData(from date: Date) -> Double {
        date.timeIntervalSince1970 - coreDataEpochOffset
    }
}
