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
        "ZPOST": ["ZURI", "ZTEXT", "ZCREATEDAT", "ZAUTHORDID", "ZAUTHORHANDLE",
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

    // MARK: - Population

    /// Bin edges chosen to show the power law: half the population replies once, and a
    /// fraction of a percent replies 100+ times.
    private static let binEdges: [(label: String, lower: Int, upper: Int?)] = [
        ("1", 1, 1), ("2–9", 2, 9), ("10–99", 10, 99),
        ("100–999", 100, 999), ("1000+", 1000, nil),
    ]

    func populationStats(now: Date = Date()) throws -> PopulationStats {
        // One pass yields every per-author reply count; the summaries below are folded
        // from it rather than re-queried.
        let counts = try conn.query("""
            SELECT COUNT(*) AS c, MAX(ZCREATEDAT) AS last_seen
            FROM ZPOST WHERE ZISROOTPOST = 0
            GROUP BY ZAUTHORDID
            """) { (Int(try $0.int(0)), Self.date(fromCoreData: try $0.double(1))) }

        let totalAuthors = counts.count
        let totalReplies = counts.map(\.0).reduce(0, +)

        // Convention, deliberate: for an even-sized population this takes the
        // upper-middle element (index n/2), not an interpolated average of the two
        // middle values — e.g. counts [1,2,3,4] have median 3, not 2.5. Empty is 0.
        let sortedCounts = counts.map(\.0).sorted()
        let median = sortedCounts.isEmpty ? 0 : sortedCounts[sortedCounts.count / 2]

        let cutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
        let active = counts.filter { $0.1 >= cutoff && $0.1 <= now }.count

        let bins = Self.binEdges.map { edge in
            HistogramBin(
                label: edge.label,
                lowerBound: edge.lower,
                upperBound: edge.upper,
                authors: counts.filter { count in
                    count.0 >= edge.lower && (edge.upper.map { u in count.0 <= u } ?? true)
                }.count
            )
        }

        let outlets = try conn.query("""
            SELECT r.ZACCOUNT, t.ZHANDLE,
                   COUNT(DISTINCT p.ZAUTHORDID), COUNT(*)
            FROM ZPOST p
            JOIN ZPOST r ON p.ZROOTURI = r.ZURI AND r.ZISROOTPOST = 1
            JOIN ZTRACKEDACCOUNT t ON t.Z_PK = r.ZACCOUNT
            WHERE p.ZISROOTPOST = 0
            GROUP BY r.ZACCOUNT, t.ZHANDLE
            ORDER BY COUNT(*) DESC
            """) { r in
            OutletCount(accountPK: try r.int(0),
                        handle: try r.text(1) ?? "unknown",
                        authors: Int(try r.int(2)),
                        replies: Int(try r.int(3)))
        }

        var statusCounts: [String: Int] = [:]
        let statusRows = try conn.query(
            "SELECT ZCURRENTSTATUS, COUNT(*) FROM ZREPLYAUTHOR GROUP BY ZCURRENTSTATUS",
            row: { (r: SQLRow) in (try r.text(0) ?? "unknown", Int(try r.int(1))) }
        )
        for row in statusRows {
            statusCounts[row.0] = row.1
        }

        return PopulationStats(
            totalAuthors: totalAuthors,
            totalReplies: totalReplies,
            medianRepliesPerAuthor: median,
            activeLast30Days: active,
            bins: bins,
            outlets: outlets,
            statusCounts: statusCounts
        )
    }

    /// One first/last-reply range per distinct author DID. The whole fold, in one query.
    /// Backs `AuthorBackfill`, which used to page `Post` through SwiftData sorted by
    /// `uri` — re-sorting ~892k unindexed strings on every page (measured 1.9–4.8s per
    /// page across ~1,786 pages; a live run hit 2h44m without writing a row). This
    /// `GROUP BY` does the same fold in 0.50s.
    func authorSeenRanges() throws -> [(did: String, first: Date, last: Date)] {
        try conn.query("""
            SELECT ZAUTHORDID, MIN(ZCREATEDAT), MAX(ZCREATEDAT)
            FROM ZPOST WHERE ZISROOTPOST = 0 GROUP BY ZAUTHORDID
            """) { r in
            (did: try r.text(0) ?? "",
             first: Self.date(fromCoreData: try r.double(1)),
             last: Self.date(fromCoreData: try r.double(2)))
        }
    }

    /// An author is "new" in the week of their first reply, and never again.
    func newAuthorsPerWeek() throws -> [WeekCount] {
        let firsts = try conn.query("""
            SELECT MIN(ZCREATEDAT) FROM ZPOST WHERE ZISROOTPOST = 0 GROUP BY ZAUTHORDID
            """) { Self.date(fromCoreData: try $0.double(0)) }

        let calendar = Calendar(identifier: .iso8601)
        var counts: [Date: Int] = [:]
        for stamp in firsts {
            let start = calendar.dateInterval(of: .weekOfYear, for: stamp)?.start ?? stamp
            counts[start, default: 0] += 1
        }
        return counts.map { WeekCount(weekStart: $0.key, count: $0.value) }
            .sorted { $0.weekStart < $1.weekStart }
    }

    // MARK: - Charts (account/group aggregate views)

    /// Replies to any root post owned by the given accounts, bucketed by ISO week.
    /// Replaces a `Set.contains` predicate over up to ~1M rows materialised as `Post`.
    func repliesPerWeek(accountPKs: [Int64]) throws -> [WeekCount] {
        guard !accountPKs.isEmpty else { return [] }
        let placeholders = accountPKs.map { _ in "?" }.joined(separator: ",")
        let stamps = try conn.query("""
            SELECT p.ZCREATEDAT
            FROM ZPOST p
            JOIN ZPOST r ON p.ZROOTURI = r.ZURI AND r.ZISROOTPOST = 1
            WHERE p.ZISROOTPOST = 0 AND r.ZACCOUNT IN (\(placeholders))
            """, accountPKs.map { .int($0) }) { Self.date(fromCoreData: try $0.double(0)) }
        return Self.weekly(stamps)
    }

    /// Root posts owned by the given accounts, bucketed by ISO week.
    func rootPostsPerWeek(accountPKs: [Int64]) throws -> [WeekCount] {
        guard !accountPKs.isEmpty else { return [] }
        let placeholders = accountPKs.map { _ in "?" }.joined(separator: ",")
        let stamps = try conn.query("""
            SELECT ZCREATEDAT FROM ZPOST
            WHERE ZISROOTPOST = 1 AND ZACCOUNT IN (\(placeholders))
            """, accountPKs.map { .int($0) }) { Self.date(fromCoreData: try $0.double(0)) }
        return Self.weekly(stamps)
    }

    /// ISO-week bucketing, Monday-aligned. SQLite has no ISO-week function, so the
    /// alignment happens in Swift against the raw timestamps.
    static func weekly(_ stamps: [Date]) -> [WeekCount] {
        let calendar = Calendar(identifier: .iso8601)
        var counts: [Date: Int] = [:]
        for stamp in stamps {
            let start = calendar.dateInterval(of: .weekOfYear, for: stamp)?.start ?? stamp
            counts[start, default: 0] += 1
        }
        return counts.map { WeekCount(weekStart: $0.key, count: $0.value) }
            .sorted { $0.weekStart < $1.weekStart }
    }

    /// Root posts for an account with their reply counts, optionally restricted to a
    /// reply-count range. Filtering happens in SQL, via `HAVING`: doing it in memory
    /// would require loading every reply, which is what this whole task exists to stop.
    ///
    /// `LEFT JOIN`, not an inner join: roots with zero replies must still appear when
    /// `minReplies` is nil — an inner join would silently drop them. An absent
    /// `maxReplies` means unbounded, never a silent cap.
    func rootPosts(accountPK: Int64,
                   minReplies: Int? = nil,
                   maxReplies: Int? = nil,
                   limit: Int) throws -> [RootPostSummary] {
        var bind: [SQLValue] = [.int(accountPK)]
        var having: [String] = []
        if let minReplies {
            having.append("c >= ?")
            bind.append(.int(Int64(minReplies)))
        }
        if let maxReplies {
            having.append("c <= ?")
            bind.append(.int(Int64(maxReplies)))
        }
        bind.append(.int(Int64(limit)))

        let havingClause = having.isEmpty ? "" : "HAVING \(having.joined(separator: " AND "))"

        let sql = """
        SELECT r.ZURI, r.ZTEXT, r.ZCREATEDAT, COUNT(p.ZURI) AS c
        FROM ZPOST r
        LEFT JOIN ZPOST p ON p.ZROOTURI = r.ZURI AND p.ZISROOTPOST = 0
        WHERE r.ZISROOTPOST = 1 AND r.ZACCOUNT = ?
        GROUP BY r.ZURI, r.ZTEXT, r.ZCREATEDAT
        \(havingClause)
        ORDER BY c DESC
        LIMIT ?
        """
        return try conn.query(sql, bind) { r in
            RootPostSummary(
                uri: try r.text(0) ?? "",
                text: try r.text(1) ?? "",
                createdAt: Self.date(fromCoreData: try r.double(2)),
                replyCount: Int(try r.int(3))
            )
        }
    }
}
