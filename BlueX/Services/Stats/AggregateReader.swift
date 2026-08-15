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
                  "ZROOTURI", "ZISROOTPOST", "ZACCOUNT", "ZREPLYTREESTATUS", "ZPARENTURI"],
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

    // MARK: - Index health

    /// Whether `StoreIndexPlan.all` is present in `sqlite_master`. `missing` names
    /// exactly which ones are not — never just a boolean, since a human diagnosing a
    /// slow dashboard needs to know which index to look for.
    struct IndexHealth: Equatable {
        let missing: [String]
        var isHealthy: Bool { missing.isEmpty }

        static let healthy = IndexHealth(missing: [])
    }

    /// A cheap `sqlite_master` lookup — this type is read-only by construction and
    /// cannot repair anything it finds missing. `IndexReasserter.reassert`, called
    /// from `BlueXStore.openContainer()` on every store open, is what actually keeps
    /// `StoreIndexPlan.all` present; this only reports whether that worked, so a
    /// process that only ever reads (the dashboard) can surface a degraded state
    /// instead of silently running unindexed. Uses `StoreIndexPlan.all` — the same
    /// list `IndexReasserter` creates from — so the two can never quietly diverge.
    func indexHealth() throws -> IndexHealth {
        let present = Set(try conn.query(
            "SELECT name FROM sqlite_master WHERE type='index'"
        ) { try $0.text(0) }.compactMap { $0 })
        let missing = StoreIndexPlan.names.filter { !present.contains($0) }
        return IndexHealth(missing: missing)
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

    /// Authors matching the same filters `authors(sort:limit:minReplies:maxReplies:outletPK:)`
    /// uses, ignoring any display cap — lets a view model report how many authors match
    /// beyond whatever page it actually loaded.
    ///
    /// `maxReplies` mirrors `rootPosts`'s `HAVING` pattern: an absent value means
    /// unbounded, never a silent cap.
    ///
    /// **Join only when an outlet filter needs it.** When `outletPK` is nil (the default,
    /// and by far the common case), this counts straight off `ZPOST` with no join at all.
    /// Measured on the live store (2.16M posts): the joined form (joining every reply to
    /// its root purely to support the optional outlet filter) took 27.8s; the same query
    /// without the join took 5.2s. The join is only there for `r.ZACCOUNT`, which nothing
    /// needs when there's no outlet filter to apply.
    ///
    /// **The two forms disagree by design, and that's deliberate.** Joined: 76,446
    /// authors. Unjoined: 76,457. The gap is 11 authors whose replies all point at a root
    /// post that isn't in the store (an orphaned reply — the root was never scraped, or
    /// was later pruned). The join drops those replies before they're counted; the
    /// unjoined form counts every row the author actually wrote. For "how many replies did
    /// this author write," the unjoined count is the honest one — the join's exclusion is
    /// an artifact of what happens to be in the store, not a fact about the author. Pinned
    /// by `testUnjoinedCountIncludesOrphanedReplyAuthors`.
    func authorCount(minReplies: Int, maxReplies: Int? = nil, outletPK: Int64?) throws -> Int {
        var bind: [SQLValue] = []
        let sql: String
        if let outletPK {
            var having = "HAVING COUNT(*) >= ?"
            bind.append(.int(Int64(minReplies)))
            if let maxReplies {
                having += " AND COUNT(*) <= ?"
                bind.append(.int(Int64(maxReplies)))
            }
            bind.insert(.int(outletPK), at: 0)
            sql = """
            SELECT COUNT(*) FROM (
              SELECT p.ZAUTHORDID
              FROM ZPOST p
              JOIN ZPOST r ON p.ZROOTURI = r.ZURI AND r.ZISROOTPOST = 1
              WHERE p.ZISROOTPOST = 0 AND r.ZACCOUNT = ?
              GROUP BY p.ZAUTHORDID
              \(having)
            )
            """
        } else {
            var having = "HAVING COUNT(*) >= ?"
            bind.append(.int(Int64(minReplies)))
            if let maxReplies {
                having += " AND COUNT(*) <= ?"
                bind.append(.int(Int64(maxReplies)))
            }
            sql = """
            SELECT COUNT(*) FROM (
              SELECT ZAUTHORDID
              FROM ZPOST
              WHERE ZISROOTPOST = 0
              GROUP BY ZAUTHORDID
              \(having)
            )
            """
        }
        return try conn.query(sql, bind) { try Int($0.int(0)) }.first ?? 0
    }

    /// `limit` caps what is returned, never what is considered — ordering happens across
    /// the whole population before the cap applies.
    ///
    /// `maxReplies` mirrors `rootPosts`'s `HAVING` pattern: an absent value means
    /// unbounded, never a silent cap.
    ///
    /// See `authorCount(minReplies:maxReplies:outletPK:)` for why the join to the root
    /// post is only present when `outletPK` is set — it exists solely to expose
    /// `r.ZACCOUNT` for that filter, and joining unconditionally cost 22.6s on the live
    /// store for no benefit in the (default, common) unfiltered case. The joined and
    /// unjoined forms also differ slightly in which authors they count: see that method's
    /// doc comment for why the unjoined count (used here whenever there's no outlet
    /// filter) is the honest one.
    ///
    /// **Handle.** `ZREPLYAUTHOR.ZCURRENTHANDLE` wins when present — it is the profile
    /// probe's answer and, once the backfill/probe run, more current than anything in
    /// `ZPOST`. Until then `ZREPLYAUTHOR` is empty for everyone, so this falls back to
    /// `ZPOST.ZAUTHORHANDLE` on the author's most recent reply (`handleFallbackSubquery`)
    /// — populated on every reply row already, per-author-DID, with no missing values on
    /// the live store. That fallback is the handle *at the time of that reply*, not
    /// necessarily current — callers must label it that way (see
    /// `AuthorsFormatting.mostRecentHandleCaption`), same as `mostRecentHandle` already
    /// does for the detail pane.
    func authors(sort: AuthorSort,
                 limit: Int,
                 minReplies: Int = 1,
                 maxReplies: Int? = nil,
                 outletPK: Int64? = nil) throws -> [AuthorSummary] {
        var bind: [SQLValue] = []
        let sql: String
        if let outletPK {
            bind.append(.int(outletPK))
            var having = "HAVING reply_count >= ?"
            bind.append(.int(Int64(minReplies)))
            if let maxReplies {
                having += " AND reply_count <= ?"
                bind.append(.int(Int64(maxReplies)))
            }
            bind.append(.int(Int64(limit)))
            sql = """
            SELECT p.ZAUTHORDID AS did,
                   COUNT(*) AS reply_count,
                   MIN(p.ZCREATEDAT) AS first_seen,
                   MAX(p.ZCREATEDAT) AS last_seen,
                   COUNT(DISTINCT r.ZACCOUNT) AS outlet_count,
                   \(Self.handleSubquery(correlatingOn: "p.ZAUTHORDID"))
            FROM ZPOST p
            JOIN ZPOST r ON p.ZROOTURI = r.ZURI AND r.ZISROOTPOST = 1
            WHERE p.ZISROOTPOST = 0 AND r.ZACCOUNT = ?
            GROUP BY p.ZAUTHORDID
            \(having)
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

        var having = "HAVING reply_count >= ?"
        bind.append(.int(Int64(minReplies)))
        if let maxReplies {
            having += " AND reply_count <= ?"
            bind.append(.int(Int64(maxReplies)))
        }
        bind.append(.int(Int64(limit)))
        // No join here: this is the aggregate the 5.2s-vs-27.8s measurement is about.
        // `outlet_count` needs `r.ZACCOUNT`, which only the join exposes, so it is left
        // out of this pass and back-filled below for just the rows this query actually
        // returns (at most `limit`, i.e. the display cap — never the whole population).
        sql = """
        SELECT ZAUTHORDID AS did,
               COUNT(*) AS reply_count,
               MIN(ZCREATEDAT) AS first_seen,
               MAX(ZCREATEDAT) AS last_seen,
               \(Self.handleSubquery(correlatingOn: "ZPOST.ZAUTHORDID"))
        FROM ZPOST
        WHERE ZISROOTPOST = 0
        GROUP BY ZAUTHORDID
        \(having)
        ORDER BY \(sort.orderBy)
        LIMIT ?
        """
        let page = try conn.query(sql, bind) { r in
            (did: try r.text(0) ?? "",
             replyCount: Int(try r.int(1)),
             firstSeen: Self.date(fromCoreData: try r.double(2)),
             lastSeen: Self.date(fromCoreData: try r.double(3)),
             handle: try r.text(4))
        }
        guard !page.isEmpty else { return [] }

        let outletCounts = try Self.outletCounts(for: page.map(\.did), conn: conn)
        return page.map { row in
            AuthorSummary(
                did: row.did,
                handle: row.handle,
                replyCount: row.replyCount,
                firstSeen: row.firstSeen,
                lastSeen: row.lastSeen,
                outletCount: outletCounts[row.did] ?? 0
            )
        }
    }

    /// `AuthorSummary.handle` for `authors(...)`'s list, correlated on `didColumn` (the
    /// outer query's `ZAUTHORDID`, aliased differently in the joined vs. unjoined SQL
    /// shape). `ZREPLYAUTHOR.ZCURRENTHANDLE` wins when present; otherwise falls back to
    /// `ZPOST.ZAUTHORHANDLE` on that author's most recent reply — the same "newest wins"
    /// correlated-subquery shape as `mostRecentHandle`, self-joined against `ZPOST`
    /// under the alias `h` so it never collides with the outer query's own `ZPOST`
    /// reference. Measured against the live store: 0.135s with this subquery vs. 0.205s
    /// without it (top 500, min 100 replies) — adding the handle costs nothing because
    /// `IDX_ZPOST_AUTHOR_COVERING` on `(ZAUTHORDID, ZISROOTPOST, ZCREATEDAT)` already
    /// makes the per-author lookup cheap.
    private static func handleSubquery(correlatingOn didColumn: String) -> String {
        """
        (SELECT COALESCE(
            (SELECT a.ZCURRENTHANDLE FROM ZREPLYAUTHOR a WHERE a.ZDID = \(didColumn)),
            (SELECT h.ZAUTHORHANDLE FROM ZPOST h
             WHERE h.ZAUTHORDID = \(didColumn) AND h.ZISROOTPOST = 0
             ORDER BY h.ZCREATEDAT DESC LIMIT 1)
        ))
        """
    }

    /// Distinct outlet counts for exactly the given DIDs — the join `authors(...)` skips
    /// in its unfiltered path, run afterward but scoped to only the (at most `limit`)
    /// authors that path actually returned, never the whole population. Keeps the "how
    /// many outlets does this author reply to" figure honest without paying the 27.8s
    /// join cost across all 2.16M posts to get it.
    private static func outletCounts(for dids: [String], conn: SQLiteConnection) throws -> [String: Int] {
        let placeholders = dids.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT p.ZAUTHORDID, COUNT(DISTINCT r.ZACCOUNT)
        FROM ZPOST p
        JOIN ZPOST r ON p.ZROOTURI = r.ZURI AND r.ZISROOTPOST = 1
        WHERE p.ZISROOTPOST = 0 AND p.ZAUTHORDID IN (\(placeholders))
        GROUP BY p.ZAUTHORDID
        """
        let rows = try conn.query(sql, dids.map { .text($0) }) { r in
            (did: try r.text(0) ?? "", count: Int(try r.int(1)))
        }
        return Dictionary(rows.map { ($0.did, $0.count) }, uniquingKeysWith: { a, _ in a })
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

    /// The handle on this author's most recent reply (`ZPOST.ZAUTHORHANDLE`, ordered by
    /// `ZCREATEDAT DESC`, one row).
    ///
    /// **This is not `AuthorSummary.handle`.** That comes from
    /// `ZREPLYAUTHOR.ZCURRENTHANDLE`, which the profile probe would populate — and the
    /// probe has never run, so it is always nil (see `testHandleIsNilWhenNotProbed`).
    /// `ZPOST.ZAUTHORHANDLE`, by contrast, is written on every reply row at scrape time
    /// and is populated on all 2,001,731 reply rows in the live store, with zero missing.
    /// It is therefore the handle *at the time of that reply*, not necessarily the
    /// author's handle today — callers must label it that way rather than implying it is
    /// current.
    func mostRecentHandle(did: String) throws -> String? {
        let rows = try conn.query("""
            SELECT ZAUTHORHANDLE FROM ZPOST
            WHERE ZISROOTPOST = 0 AND ZAUTHORDID = ?
            ORDER BY ZCREATEDAT DESC LIMIT 1
            """, [.text(did)]) { try $0.text(0) }
        guard let row = rows.first else { return nil }
        return row
    }

    /// Every distinct handle this author's replies have carried, sorted for a stable
    /// display order. More than one entry is signal, not noise: the research spec calls
    /// out handle changes as an evasion indicator, so a multi-handle author should be
    /// surfaced rather than silently collapsed to just their latest handle.
    func distinctHandles(did: String) throws -> [String] {
        try conn.query("""
            SELECT DISTINCT ZAUTHORHANDLE FROM ZPOST
            WHERE ZISROOTPOST = 0 AND ZAUTHORDID = ? AND ZAUTHORHANDLE IS NOT NULL
            ORDER BY ZAUTHORHANDLE
            """, [.text(did)]) { try $0.text(0) }.compactMap { $0 }
    }

    /// An author's replies, newest first, capped at `limit`. Measured on the live store
    /// (100 newest replies for the heaviest author): 0.012s — `IDX_ZPOST_AUTHOR_COVERING`
    /// makes this trivial. `authorReplyCount` is the companion query for "showing N of M" —
    /// never present this list without also stating the total it was capped from.
    func authorReplies(did: String, limit: Int) throws -> [AuthorReply] {
        try conn.query("""
            SELECT ZURI, ZTEXT, ZCREATEDAT, ZROOTURI
            FROM ZPOST
            WHERE ZISROOTPOST = 0 AND ZAUTHORDID = ?
            ORDER BY ZCREATEDAT DESC
            LIMIT ?
            """, [.text(did), .int(Int64(limit))]) { r in
            AuthorReply(
                uri: try r.text(0) ?? "",
                text: try r.text(1) ?? "",
                createdAt: Self.date(fromCoreData: try r.double(2)),
                rootURI: try r.text(3) ?? ""
            )
        }
    }

    /// How many replies this author has in total — the "of N" half of "showing 100 of N
    /// replies", so `authorReplies`'s cap is always stated, never silent.
    func authorReplyCount(did: String) throws -> Int {
        try conn.query(
            "SELECT COUNT(*) FROM ZPOST WHERE ZISROOTPOST = 0 AND ZAUTHORDID = ?",
            [.text(did)]
        ) { try Int($0.int(0)) }.first ?? 0
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

    // MARK: - Account lookup

    /// `TrackedAccount`'s Core Data primary key, resolved by DID. SwiftData does not
    /// expose `Z_PK` on the model, and the SQL aggregates below key everything off it —
    /// so views must go through this rather than guessing or hardcoding the PK.
    func accountPK(did: String) throws -> Int64? {
        try conn.query(
            "SELECT Z_PK FROM ZTRACKEDACCOUNT WHERE ZDID = ?", [.text(did)]
        ) { try $0.int(0) }.first
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
    /// reply-count range and/or a text search. Both filters happen in SQL — the reply
    /// count via `HAVING`, the text search via `WHERE ... LIKE` — never in memory: doing
    /// either in memory would require loading every reply, or searching only whatever
    /// capped page happened to be in memory rather than the whole account, which is
    /// what this whole task exists to stop.
    ///
    /// `LEFT JOIN`, not an inner join: roots with zero replies must still appear when
    /// `minReplies` is nil — an inner join would silently drop them. An absent
    /// `maxReplies` means unbounded, never a silent cap.
    func rootPosts(accountPK: Int64,
                   minReplies: Int? = nil,
                   maxReplies: Int? = nil,
                   textSearch: String? = nil,
                   limit: Int) throws -> [RootPostSummary] {
        var bind: [SQLValue] = [.int(accountPK)]
        let textClause = Self.textSearchClause(textSearch, bind: &bind)
        let having = Self.havingClause(minReplies: minReplies, maxReplies: maxReplies, bind: &bind)
        bind.append(.int(Int64(limit)))

        let sql = """
        SELECT r.ZURI, r.ZTEXT, r.ZCREATEDAT, COUNT(p.ZURI) AS c, r.ZREPLYTREESTATUS
        FROM ZPOST r
        LEFT JOIN ZPOST p ON p.ZROOTURI = r.ZURI AND p.ZISROOTPOST = 0
        WHERE r.ZISROOTPOST = 1 AND r.ZACCOUNT = ? \(textClause)
        GROUP BY r.ZURI, r.ZTEXT, r.ZCREATEDAT, r.ZREPLYTREESTATUS
        \(having)
        ORDER BY c DESC
        LIMIT ?
        """
        return try conn.query(sql, bind) { r in
            RootPostSummary(
                uri: try r.text(0) ?? "",
                text: try r.text(1) ?? "",
                createdAt: Self.date(fromCoreData: try r.double(2)),
                replyCount: Int(try r.int(3)),
                replyTreeStatus: try r.text(4) ?? "pending"
            )
        }
    }

    /// How many of an account's root posts match a reply-count range and/or text search —
    /// the same filters as `rootPosts(accountPK:minReplies:maxReplies:textSearch:)`, but
    /// counting the matches instead of returning a capped page of them. Lets the UI say
    /// "3,419 trees match" — against the whole account, not just the loaded page — without
    /// materialising any of them.
    func rootPostCount(accountPK: Int64,
                        minReplies: Int? = nil,
                        maxReplies: Int? = nil,
                        textSearch: String? = nil) throws -> Int {
        var bind: [SQLValue] = [.int(accountPK)]
        let textClause = Self.textSearchClause(textSearch, bind: &bind)
        let having = Self.havingClause(minReplies: minReplies, maxReplies: maxReplies, bind: &bind)

        let sql = """
        SELECT COUNT(*) FROM (
            SELECT r.ZURI, COUNT(p.ZURI) AS c
            FROM ZPOST r
            LEFT JOIN ZPOST p ON p.ZROOTURI = r.ZURI AND p.ZISROOTPOST = 0
            WHERE r.ZISROOTPOST = 1 AND r.ZACCOUNT = ? \(textClause)
            GROUP BY r.ZURI
            \(having)
        )
        """
        return try conn.query(sql, bind) { try Int($0.int(0)) }.first ?? 0
    }

    /// Shared `HAVING` fragment for the reply-count range filter. An absent `maxReplies`
    /// must mean unbounded — never a silent cap — so it is simply omitted from the clause.
    private static func havingClause(minReplies: Int?, maxReplies: Int?,
                                      bind: inout [SQLValue]) -> String {
        var having: [String] = []
        if let minReplies {
            having.append("c >= ?")
            bind.append(.int(Int64(minReplies)))
        }
        if let maxReplies {
            having.append("c <= ?")
            bind.append(.int(Int64(maxReplies)))
        }
        return having.isEmpty ? "" : "HAVING \(having.joined(separator: " AND "))"
    }

    /// Shared `WHERE` fragment for the text-search filter. Matches root post text OR
    /// author handle — the same scope the old in-memory `AccountViewModel.filteredPosts`
    /// covered before this task moved the search into SQL.
    ///
    /// The pattern is always bound as a parameter, never interpolated into the SQL
    /// string, and `%`/`_` (SQL `LIKE` wildcards) are escaped in the user's input first —
    /// so a literal `%` typed by the user is matched literally, not treated as a wildcard.
    private static func textSearchClause(_ textSearch: String?, bind: inout [SQLValue]) -> String {
        guard let textSearch, !textSearch.isEmpty else { return "" }
        let pattern = "%\(likeEscaped(textSearch))%"
        bind.append(.text(pattern))
        bind.append(.text(pattern))
        return "AND (r.ZTEXT LIKE ? ESCAPE '\\' OR r.ZAUTHORHANDLE LIKE ? ESCAPE '\\')"
    }

    /// Escapes `\`, `%`, and `_` so `textSearchClause`'s `LIKE ... ESCAPE '\'` treats
    /// every character of the input literally rather than as a wildcard.
    private static func likeEscaped(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\", with: "\\\\")
           .replacingOccurrences(of: "%", with: "\\%")
           .replacingOccurrences(of: "_", with: "\\_")
    }

    // MARK: - Labelling pool

    /// The shared `SELECT ... FROM ZPOST p WHERE ...` shape behind both
    /// `labellingPoolCount` and `labellingPoolURIs`. Both call this with a different
    /// `select` clause (`COUNT(*)` vs. `p.ZURI`) but otherwise the exact same predicate —
    /// deliberately, so the two can never quietly disagree about which replies are in
    /// the pool. A `SamplingFrame` recorded against a batch of labels and a frame used
    /// to draw more from the same pool later must always describe the same set of URIs.
    ///
    /// Pool = replies (`ZISROOTPOST = 0`). `.uniformRandom` adds no further predicate.
    /// `.filtered` adds, independently: a date range on the reply's own `ZCREATEDAT`,
    /// and — only when an outlet filter or thread-size filter is actually set — a
    /// `p.ZROOTURI IN (...)` restriction to roots matching those. That inner subquery
    /// mirrors `rootPosts`'s own `LEFT JOIN` + `GROUP BY` + `HAVING` shape for the
    /// reply-count range, rather than inventing a new pattern for the same idea.
    private static func labellingPoolSQL(frame: SamplingFrame, select: String,
                                          bind: inout [SQLValue]) -> String {
        var conditions = ["p.ZISROOTPOST = 0"]

        if frame.kind == .filtered {
            if let dateFrom = frame.dateFrom {
                conditions.append("p.ZCREATEDAT >= ?")
                bind.append(.double(coreData(from: dateFrom)))
            }
            if let dateTo = frame.dateTo {
                conditions.append("p.ZCREATEDAT <= ?")
                bind.append(.double(coreData(from: dateTo)))
            }

            let needsRootFilter = frame.outletPK != nil
                || frame.minThreadReplies != nil || frame.maxThreadReplies != nil
            if needsRootFilter {
                var rootConditions = ["r.ZISROOTPOST = 1"]
                var rootBind: [SQLValue] = []
                if let outletPK = frame.outletPK {
                    rootConditions.append("r.ZACCOUNT = ?")
                    rootBind.append(.int(outletPK))
                }
                var having: [String] = []
                if let minThreadReplies = frame.minThreadReplies {
                    having.append("COUNT(t.ZURI) >= ?")
                    rootBind.append(.int(Int64(minThreadReplies)))
                }
                if let maxThreadReplies = frame.maxThreadReplies {
                    having.append("COUNT(t.ZURI) <= ?")
                    rootBind.append(.int(Int64(maxThreadReplies)))
                }
                let havingClause = having.isEmpty ? "" : "HAVING \(having.joined(separator: " AND "))"
                conditions.append("""
                p.ZROOTURI IN (
                    SELECT r.ZURI FROM ZPOST r
                    LEFT JOIN ZPOST t ON t.ZROOTURI = r.ZURI AND t.ZISROOTPOST = 0
                    WHERE \(rootConditions.joined(separator: " AND "))
                    GROUP BY r.ZURI
                    \(havingClause)
                )
                """)
                bind.append(contentsOf: rootBind)
            }
        }

        return """
        SELECT \(select) FROM ZPOST p
        WHERE \(conditions.joined(separator: " AND "))
        """
    }

    /// How many replies match `frame` — the "N in this pool" figure a labeller sees
    /// before drawing a batch. Uses the exact same predicate as `labellingPoolURIs`
    /// (see `labellingPoolSQL`), so the two can never disagree about the pool's size.
    func labellingPoolCount(frame: SamplingFrame) throws -> Int {
        var bind: [SQLValue] = []
        let sql = Self.labellingPoolSQL(frame: frame, select: "COUNT(*)", bind: &bind)
        return try conn.query(sql, bind) { try Int($0.int(0)) }.first ?? 0
    }

    /// The URIs of every reply matching `frame` — the pool a batch is drawn from.
    /// Ordered by URI purely for determinism between runs, not a ranking of any kind.
    func labellingPoolURIs(frame: SamplingFrame) throws -> [String] {
        var bind: [SQLValue] = []
        let sql = Self.labellingPoolSQL(frame: frame, select: "p.ZURI", bind: &bind)
            + " ORDER BY p.ZURI"
        return try conn.query(sql, bind) { try $0.text(0) ?? "" }
    }

    /// Everything a human labeller is shown for one reply: its own text plus enough
    /// thread context (root, and immediate parent when it differs from the root) to
    /// judge it — and, deliberately, nothing else. **This struct contains no score, no
    /// label, no class, no model field of any kind.** Human labels are this project's
    /// held-out gold set; a labeller who can see a model's output on the post they are
    /// labelling is no longer producing an independent measurement. That guarantee is
    /// structural here, not a UI convention — see `AggregateReaderLabellingTests`'s
    /// Mirror-based test, which fails loudly the moment a future edit adds such a field.
    struct LabellingContext: Equatable {
        let uri: String
        let text: String
        let createdAt: Date
        let authorHandle: String
        let rootURI: String
        let rootText: String
        let rootHandle: String
        let parentURI: String?
        let parentText: String?
        let parentHandle: String?
    }

    /// Batch context fetch for exactly the given URIs — an unknown URI is simply absent
    /// from the result, never a thrown error, since the caller (drawing a batch from a
    /// pool that may have shifted since it was sampled) has no way to distinguish
    /// "already labelled and pruned" from "never existed" and shouldn't have to.
    ///
    /// Parent fields are nil whenever `ZPARENTURI` is null or equals `ZROOTURI` — depth-1
    /// replies, measured at ~78% of the population — so a labeller sees a real
    /// intermediate reply only when one exists, never the root repeated under a
    /// different name.
    func labellingContext(uris: [String]) throws -> [LabellingContext] {
        guard !uris.isEmpty else { return [] }
        let placeholders = uris.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT p.ZURI, p.ZTEXT, p.ZCREATEDAT, p.ZAUTHORHANDLE,
               r.ZURI, r.ZTEXT, r.ZAUTHORHANDLE,
               CASE WHEN p.ZPARENTURI IS NULL OR p.ZPARENTURI = p.ZROOTURI
                    THEN NULL ELSE par.ZURI END,
               CASE WHEN p.ZPARENTURI IS NULL OR p.ZPARENTURI = p.ZROOTURI
                    THEN NULL ELSE par.ZTEXT END,
               CASE WHEN p.ZPARENTURI IS NULL OR p.ZPARENTURI = p.ZROOTURI
                    THEN NULL ELSE par.ZAUTHORHANDLE END
        FROM ZPOST p
        JOIN ZPOST r ON r.ZURI = p.ZROOTURI AND r.ZISROOTPOST = 1
        LEFT JOIN ZPOST par ON par.ZURI = p.ZPARENTURI
        WHERE p.ZURI IN (\(placeholders))
        """
        return try conn.query(sql, uris.map { .text($0) }) { r in
            LabellingContext(
                uri: try r.text(0) ?? "",
                text: try r.text(1) ?? "",
                createdAt: Self.date(fromCoreData: try r.double(2)),
                authorHandle: try r.text(3) ?? "",
                rootURI: try r.text(4) ?? "",
                rootText: try r.text(5) ?? "",
                rootHandle: try r.text(6) ?? "",
                parentURI: try r.text(7),
                parentText: try r.text(8),
                parentHandle: try r.text(9)
            )
        }
    }
}
