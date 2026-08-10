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

    // MARK: - Authors

    /// Distinct reply authors. Root posts are excluded: their authors are the tracked
    /// outlets, not members of the public.
    func authorCount() throws -> Int {
        let rows = try conn.query(
            "SELECT COUNT(DISTINCT ZAUTHORDID) FROM ZPOST WHERE ZISROOTPOST = 0"
        ) { try Int($0.int(0)) }
        return rows.first ?? 0
    }

    /// `limit` caps what is returned, never what is considered — ordering happens across
    /// the whole population before the cap applies.
    func authors(sort: AuthorSort,
                 limit: Int,
                 minReplies: Int = 1,
                 outletPK: Int64? = nil) throws -> [AuthorSummary] {
        var bind: [SQLValue] = []
        var outletFilter = ""
        if let outletPK {
            outletFilter = "AND r.ZACCOUNT = ?"
            bind.append(.int(outletPK))
        }
        bind.append(.int(Int64(minReplies)))
        bind.append(.int(Int64(limit)))

        let sql = """
        SELECT p.ZAUTHORDID AS did,
               COUNT(*) AS reply_count,
               MIN(p.ZCREATEDAT) AS first_seen,
               MAX(p.ZCREATEDAT) AS last_seen,
               COUNT(DISTINCT r.ZACCOUNT) AS outlet_count,
               (SELECT a.ZCURRENTHANDLE FROM ZREPLYAUTHOR a WHERE a.ZDID = p.ZAUTHORDID)
        FROM ZPOST p
        JOIN ZPOST r ON p.ZROOTURI = r.ZURI AND r.ZISROOTPOST = 1
        WHERE p.ZISROOTPOST = 0 \(outletFilter)
        GROUP BY p.ZAUTHORDID
        HAVING reply_count >= ?
        ORDER BY \(sort.orderBy)
        LIMIT ?
        """
        return try conn.query(sql, bind) { r in
            AuthorSummary(
                did: try r.text(0) ?? "",
                handle: try r.text(5),
                replyCount: try Int(r.int(1)),
                firstSeen: Self.date(fromCoreData: try r.double(2)),
                lastSeen: Self.date(fromCoreData: try r.double(3)),
                outletCount: try Int(r.int(4))
            )
        }
    }

    func authorDetail(did: String) throws -> AuthorSummary? {
        let sql = """
        SELECT p.ZAUTHORDID,
               COUNT(*),
               MIN(p.ZCREATEDAT),
               MAX(p.ZCREATEDAT),
               COUNT(DISTINCT r.ZACCOUNT),
               (SELECT a.ZCURRENTHANDLE FROM ZREPLYAUTHOR a WHERE a.ZDID = p.ZAUTHORDID)
        FROM ZPOST p
        JOIN ZPOST r ON p.ZROOTURI = r.ZURI AND r.ZISROOTPOST = 1
        WHERE p.ZISROOTPOST = 0 AND p.ZAUTHORDID = ?
        GROUP BY p.ZAUTHORDID
        """
        return try conn.query(sql, [.text(did)]) { r in
            AuthorSummary(
                did: try r.text(0) ?? "",
                handle: try r.text(5),
                replyCount: try Int(r.int(1)),
                firstSeen: Self.date(fromCoreData: try r.double(2)),
                lastSeen: Self.date(fromCoreData: try r.double(3)),
                outletCount: try Int(r.int(4))
            )
        }.first
    }

    /// Weekly buckets, aligned to ISO Monday. SQLite has no ISO-week function, so the
    /// alignment happens in Swift against the raw timestamps.
    func repliesPerWeek(did: String) throws -> [WeekCount] {
        let stamps = try conn.query(
            "SELECT ZCREATEDAT FROM ZPOST WHERE ZISROOTPOST = 0 AND ZAUTHORDID = ?",
            [.text(did)]
        ) { Self.date(fromCoreData: try $0.double(0)) }

        let calendar = Calendar(identifier: .iso8601)
        var counts: [Date: Int] = [:]
        for stamp in stamps {
            let start = calendar.dateInterval(of: .weekOfYear, for: stamp)?.start ?? stamp
            counts[start, default: 0] += 1
        }
        return counts.map { WeekCount(weekStart: $0.key, count: $0.value) }
            .sorted { $0.weekStart < $1.weekStart }
    }

    func outletBreakdown(did: String) throws -> [OutletCount] {
        let sql = """
        SELECT r.ZACCOUNT, t.ZHANDLE, COUNT(*)
        FROM ZPOST p
        JOIN ZPOST r ON p.ZROOTURI = r.ZURI AND r.ZISROOTPOST = 1
        JOIN ZTRACKEDACCOUNT t ON t.Z_PK = r.ZACCOUNT
        WHERE p.ZISROOTPOST = 0 AND p.ZAUTHORDID = ?
        GROUP BY r.ZACCOUNT, t.ZHANDLE
        ORDER BY COUNT(*) DESC
        """
        return try conn.query(sql, [.text(did)]) { r in
            OutletCount(accountPK: try r.int(0),
                        handle: try r.text(1) ?? "unknown",
                        authors: 1,
                        replies: try Int(r.int(2)))
        }
    }
}
