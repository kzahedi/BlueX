import Foundation
@testable import BlueX

/// Builds a SQLite file with the same Z-prefixed shape Core Data produces, so the
/// reader can be tested against known counts.
enum StoreFixture {
    /// Core Data stores dates as seconds since 2001-01-01.
    static let coreDataEpochOffset: TimeInterval = 978_307_200

    static func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    static func cd(_ d: Date) -> Double { d.timeIntervalSince1970 - coreDataEpochOffset }

    private static func schema(_ w: SQLiteWriteHelper) throws {
        try w.exec("""
        CREATE TABLE ZPOST (
          Z_PK INTEGER PRIMARY KEY, ZURI VARCHAR, ZTEXT VARCHAR,
          ZCREATEDAT TIMESTAMP, ZAUTHORDID VARCHAR, ZAUTHORHANDLE VARCHAR,
          ZPARENTURI VARCHAR, ZROOTURI VARCHAR, ZISROOTPOST INTEGER,
          ZDEPTH INTEGER, ZACCOUNT INTEGER,
          ZREPLYTREESTATUS VARCHAR DEFAULT 'complete'
        )
        """)
        try w.exec("""
        CREATE TABLE ZTRACKEDACCOUNT (
          Z_PK INTEGER PRIMARY KEY, ZDID VARCHAR, ZHANDLE VARCHAR,
          ZDISPLAYNAME VARCHAR, ZAVATARURL VARCHAR, ZISACTIVE INTEGER, ZSTARTAT TIMESTAMP
        )
        """)
        try w.exec("""
        CREATE TABLE ZREPLYAUTHOR (
          Z_PK INTEGER PRIMARY KEY, ZDID VARCHAR, ZFIRSTSEENAT TIMESTAMP,
          ZLASTSEENAT TIMESTAMP, ZCURRENTHANDLE VARCHAR,
          ZCURRENTSTATUS VARCHAR, ZLASTPROBEDAT TIMESTAMP
        )
        """)
    }

    private static func post(_ pk: Int, _ uri: String, _ did: String, _ handle: String,
                              _ iso: String, root: String, isRoot: Bool, account: Int?,
                              parent: String? = nil) -> String {
        postWithText(pk, uri, did, handle, "text", iso, root: root, isRoot: isRoot,
                     account: account, parent: parent)
    }

    /// Same shape as `post`, but with the text column set explicitly — `post` hardcodes
    /// it to the literal string `'text'`, which is fine for fixtures that only need
    /// distinct URIs, but useless for anything exercising a text-search filter.
    ///
    /// `parent`, when supplied, overrides the default "parent == root" shape (depth 1)
    /// with an explicit `ZPARENTURI` — used to build a depth-2 reply (parent is another
    /// reply, not the root itself).
    private static func postWithText(_ pk: Int, _ uri: String, _ did: String, _ handle: String,
                                      _ text: String, _ iso: String, root: String, isRoot: Bool,
                                      account: Int?, parent: String? = nil) -> String {
        let acct = account.map(String.init) ?? "NULL"
        let escapedText = text.replacingOccurrences(of: "'", with: "''")
        let parentURI = isRoot ? "NULL" : "'\(parent ?? root)'"
        // Depth follows the parent: 0 for a root, 2 when an explicit parent differs
        // from the root (a depth-2 reply), 1 otherwise (the default "parent == root"
        // shape). Unused by any query today — see the depth-2 fixture comment below —
        // but kept honest rather than left hardcoded at 1 for every reply.
        let depth = isRoot ? 0 : (parent != nil && parent != root ? 2 : 1)
        return "(\(pk),'\(uri)','\(escapedText)',\(cd(date(iso))),'\(did)','\(handle)'," +
               "\(parentURI),'\(root)',\(isRoot ? 1 : 0)," +
               "\(depth),\(acct))"
    }

    /// Two outlets, seven reply authors, plus the outlets' own root-post author
    /// (`did:root`, which must never appear as a reply author):
    ///
    ///   did:a    —  1 reply,  outlet 2 only         (2024-02-10)
    ///   did:b    —  2 replies, one to EACH outlet   (2024-01-15, 2024-01-20) — cross-outlet
    ///   did:c    —  3 replies, outlet 1 only, spanning 2024-01-01 … 2024-03-01
    ///   did:n9   —  9 replies, outlet 1 only          — sits on the "2–9" bin's upper edge
    ///   did:n10  — 10 replies, outlet 1 only          — sits on the "10–99" bin's lower edge
    ///   did:n99  — 99 replies, outlet 1 only          — sits on the "10–99" bin's upper edge
    ///   did:n100 — 100 replies, outlet 1 only         — sits on the "100–999" bin's lower edge
    ///
    /// Rank by reply count (highest first): n100(100), n99(99), n10(10), n9(9), c(3), b(2), a(1).
    ///
    /// **Adversarial ordering, deliberate — do not "tidy" this up.** did:a is both
    /// alphabetically first AND physically inserted first, yet holds the LOWEST reply
    /// count (1). did:n100 holds the HIGHEST reply count (100) and is physically
    /// inserted LAST. A query that caps its result set against encounter order instead
    /// of ranking the whole population first (e.g. a LIMIT applied inside a subquery
    /// before the outer ORDER BY) would surface did:a — not the true top, did:n100 — and
    /// a test built against this fixture would catch it. If did:a and did:n100 traded
    /// places (alphabetically or physically), that discriminating power would be lost
    /// silently: see `testLimitCapsResultsButNotSelection` in AggregateReaderAuthorTests.
    ///
    /// **Boundary values, deliberate.** n9/n10 and n99/n100 straddle the "2–9" / "10–99"
    /// and "10–99" / "100–999" histogram edges specifically so an off-by-one in the bin
    /// boundary comparison (e.g. treating a bound as exclusive) changes a bin's count
    /// without changing the total — see `testHistogramBoundariesNoOffByOne` in
    /// AggregateReaderPopulationTests. The 999/1000 boundary is deliberately NOT covered
    /// here: reaching it would require an author with 999 or 1000 replies, i.e. ~1000
    /// more rows in this fixture, which was judged not worth the bulk for one more edge.
    static func make() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fixture.sqlite")
        let w = try SQLiteWriteHelper(at: url)
        try schema(w)

        try w.exec("""
        INSERT INTO ZTRACKEDACCOUNT (Z_PK, ZDID, ZHANDLE, ZDISPLAYNAME, ZISACTIVE)
        VALUES (1,'did:o1','outlet-one.com','Outlet One',1),
               (2,'did:o2','outlet-two.com','Outlet Two',1)
        """)

        var pk = 1
        func nextPK() -> Int { let p = pk; pk += 1; return p }

        /// `count` replies from `did`, all on the same timestamp, all to `root`. The exact
        /// timestamp doesn't matter for the boundary-value authors — only the count does.
        func repeated(did: String, handle: String, count: Int, iso: String, root: String) -> [String] {
            (0..<count).map { i in
                post(nextPK(), "at://\(did)-\(i)", did, handle, iso, root: root, isRoot: false, account: nil)
            }
        }

        var rows: [String] = [
            post(nextPK(), "at://r1", "did:root", "outlet-one.com", "2024-01-01T00:00:00Z",
                 root: "at://r1", isRoot: true, account: 1),
            post(nextPK(), "at://r2", "did:root", "outlet-two.com", "2024-01-01T00:00:00Z",
                 root: "at://r2", isRoot: true, account: 2),
            // did:a — inserted first, alphabetically first, lowest count. See the
            // adversarial-ordering note above.
            post(nextPK(), "at://a1", "did:a", "alice.test", "2024-02-10T00:00:00Z",
                 root: "at://r2", isRoot: false, account: nil),
            post(nextPK(), "at://b1", "did:b", "bob.test", "2024-01-15T00:00:00Z",
                 root: "at://r1", isRoot: false, account: nil),
            post(nextPK(), "at://b2", "did:b", "bob.test", "2024-01-20T00:00:00Z",
                 root: "at://r2", isRoot: false, account: nil),
        ]
        rows += repeated(did: "did:n9", handle: "n9.test", count: 9,
                         iso: "2024-01-05T00:00:00Z", root: "at://r1")
        rows += repeated(did: "did:n10", handle: "n10.test", count: 10,
                         iso: "2024-01-06T00:00:00Z", root: "at://r1")
        rows += repeated(did: "did:n99", handle: "n99.test", count: 99,
                         iso: "2024-01-07T00:00:00Z", root: "at://r1")
        rows += [
            post(nextPK(), "at://c1", "did:c", "carol.test", "2024-01-01T00:00:00Z",
                 root: "at://r1", isRoot: false, account: nil),
            post(nextPK(), "at://c2", "did:c", "carol.test", "2024-02-01T00:00:00Z",
                 root: "at://r1", isRoot: false, account: nil),
            // Depth-2, deliberately: at://c3's parent is at://c2 (another reply), not
            // the root. Every other reply in this fixture has ZPARENTURI == ZROOTURI
            // (depth 1, ~78% of replies on the live store); this is the sole depth-2
            // case, added for the labelling-context tests
            // (AggregateReaderLabellingTests) that must resolve a real intermediate
            // parent post rather than nil. Changing only ZPARENTURI here — not the
            // count, date, or text of any row — leaves every total this fixture pins
            // elsewhere (totalAuthors, totalReplies, bin counts, per-outlet counts,
            // did:c's own replyCount/firstSeen/lastSeen) untouched.
            post(nextPK(), "at://c3", "did:c", "carol.test", "2024-03-01T00:00:00Z",
                 root: "at://r1", isRoot: false, account: nil, parent: "at://c2"),
        ]
        // did:n100 — inserted LAST, deliberately, and holds the highest reply count
        // (100) of the whole population. See the adversarial-ordering note above.
        rows += repeated(did: "did:n100", handle: "n100.test", count: 100,
                         iso: "2024-01-08T00:00:00Z", root: "at://r1")

        try w.exec("""
        INSERT INTO ZPOST (Z_PK, ZURI, ZTEXT, ZCREATEDAT, ZAUTHORDID, ZAUTHORHANDLE,
                           ZPARENTURI, ZROOTURI, ZISROOTPOST, ZDEPTH, ZACCOUNT)
        VALUES \(rows.joined(separator: ","))
        """)
        try w.close()
        return url
    }

    /// Four reply authors with distinct, deliberately-even-count reply totals: 1, 2, 3, 4.
    /// Exists solely to pin down the median convention for an even-sized population in
    /// isolation from `make()`'s larger fixture: sorted counts are [1,2,3,4], and the
    /// reader's convention takes the upper-middle element (index n/2 = 2), so the median
    /// here is 3 — not 2.5 and not 2. All replies go to the one outlet/root; the outlet
    /// split is irrelevant to this fixture's purpose.
    static func makeMedianEven() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fixture.sqlite")
        let w = try SQLiteWriteHelper(at: url)
        try schema(w)

        try w.exec("""
        INSERT INTO ZTRACKEDACCOUNT (Z_PK, ZDID, ZHANDLE, ZDISPLAYNAME, ZISACTIVE)
        VALUES (1,'did:o1','outlet-one.com','Outlet One',1)
        """)

        var pk = 1
        func nextPK() -> Int { let p = pk; pk += 1; return p }

        var rows: [String] = [
            post(nextPK(), "at://r1", "did:root", "outlet-one.com", "2024-01-01T00:00:00Z",
                 root: "at://r1", isRoot: true, account: 1),
        ]
        for (did, count) in [("did:one", 1), ("did:two", 2), ("did:three", 3), ("did:four", 4)] {
            for i in 0..<count {
                rows.append(post(nextPK(), "at://\(did)-\(i)", did, "\(did).test",
                                  "2024-01-02T00:00:00Z", root: "at://r1", isRoot: false, account: nil))
            }
        }

        try w.exec("""
        INSERT INTO ZPOST (Z_PK, ZURI, ZTEXT, ZCREATEDAT, ZAUTHORDID, ZAUTHORHANDLE,
                           ZPARENTURI, ZROOTURI, ZISROOTPOST, ZDEPTH, ZACCOUNT)
        VALUES \(rows.joined(separator: ","))
        """)
        try w.close()
        return url
    }

    /// One account, five root posts with reply counts 0, 3, 50, 75, 120 — chosen to
    /// straddle the `HAVING` boundaries a reply-count range filter needs to get right:
    /// a root with **zero** replies (must survive a `LEFT JOIN`, not an inner join),
    /// one exactly at a `minReplies` boundary (50), one exactly at a `maxReplies`
    /// boundary (75 sits inside 50–100; 120 sits outside it), and one with the highest
    /// count so `ORDER BY ... DESC` + `LIMIT` has something to discriminate against.
    static func makeRootPostCounts() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fixture.sqlite")
        let w = try SQLiteWriteHelper(at: url)
        try schema(w)

        try w.exec("""
        INSERT INTO ZTRACKEDACCOUNT (Z_PK, ZDID, ZHANDLE, ZDISPLAYNAME, ZISACTIVE)
        VALUES (1,'did:o1','outlet-one.com','Outlet One',1)
        """)

        var pk = 1
        func nextPK() -> Int { let p = pk; pk += 1; return p }

        let roots: [(uri: String, iso: String, replies: Int)] = [
            ("at://z0", "2024-01-01T00:00:00Z", 0),
            ("at://z1", "2024-01-02T00:00:00Z", 3),
            ("at://z2", "2024-01-03T00:00:00Z", 50),
            ("at://z3", "2024-01-04T00:00:00Z", 75),
            ("at://z4", "2024-01-05T00:00:00Z", 120),
        ]

        var rows: [String] = []
        for root in roots {
            rows.append(post(nextPK(), root.uri, "did:root", "outlet-one.com", root.iso,
                              root: root.uri, isRoot: true, account: 1))
            for i in 0..<root.replies {
                rows.append(post(nextPK(), "\(root.uri)-reply\(i)", "did:reply\(i % 5)",
                                  "replier\(i % 5).test", root.iso, root: root.uri,
                                  isRoot: false, account: nil))
            }
        }

        try w.exec("""
        INSERT INTO ZPOST (Z_PK, ZURI, ZTEXT, ZCREATEDAT, ZAUTHORDID, ZAUTHORHANDLE,
                           ZPARENTURI, ZROOTURI, ZISROOTPOST, ZDEPTH, ZACCOUNT)
        VALUES \(rows.joined(separator: ","))
        """)
        try w.close()
        return url
    }

    /// One account, four root posts with distinct text and reply counts, chosen to pin
    /// down the text-search filter independently of the reply-count filter:
    ///
    ///   at://t-weather — "Breaking news about the weather today" — 5 replies
    ///   at://t-percent — "Special offer: 50% off everything this week" — 3 replies —
    ///       the literal `%` this tree exists to protect: searching for `%` must match
    ///       only this root (its text contains a literal percent sign), not every row,
    ///       which is what would happen if the wildcard were not escaped.
    ///   at://t-needle  — "A quiet little needle post" — 0 replies — the LOWEST reply
    ///       count of the four, so `ORDER BY c DESC` ranks it last. A `limit` small
    ///       enough to exclude it from an unfiltered page must still surface it when
    ///       searching for "needle" — proving the search runs in SQL against the whole
    ///       account, not against whatever page happened to already be loaded.
    ///   at://t-highest — "Nothing special here" — 100 replies — highest count, gives an
    ///       unfiltered `ORDER BY c DESC` something to rank first, and a search with no
    ///       matches ("giraffe") something to correctly find nothing among.
    static func makeRootPostsWithText() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fixture.sqlite")
        let w = try SQLiteWriteHelper(at: url)
        try schema(w)

        try w.exec("""
        INSERT INTO ZTRACKEDACCOUNT (Z_PK, ZDID, ZHANDLE, ZDISPLAYNAME, ZISACTIVE)
        VALUES (1,'did:o1','outlet-one.com','Outlet One',1)
        """)

        var pk = 1
        func nextPK() -> Int { let p = pk; pk += 1; return p }

        let roots: [(uri: String, text: String, iso: String, replies: Int)] = [
            ("at://t-weather", "Breaking news about the weather today",
             "2024-01-01T00:00:00Z", 5),
            ("at://t-percent", "Special offer: 50% off everything this week",
             "2024-01-02T00:00:00Z", 3),
            ("at://t-needle", "A quiet little needle post",
             "2024-01-03T00:00:00Z", 0),
            ("at://t-highest", "Nothing special here",
             "2024-01-04T00:00:00Z", 100),
        ]

        var rows: [String] = []
        for root in roots {
            rows.append(postWithText(nextPK(), root.uri, "did:root", "outlet-one.com",
                                      root.text, root.iso, root: root.uri, isRoot: true,
                                      account: 1))
            for i in 0..<root.replies {
                rows.append(post(nextPK(), "\(root.uri)-reply\(i)", "did:reply\(i % 5)",
                                  "replier\(i % 5).test", root.iso, root: root.uri,
                                  isRoot: false, account: nil))
            }
        }

        try w.exec("""
        INSERT INTO ZPOST (Z_PK, ZURI, ZTEXT, ZCREATEDAT, ZAUTHORDID, ZAUTHORHANDLE,
                           ZPARENTURI, ZROOTURI, ZISROOTPOST, ZDEPTH, ZACCOUNT)
        VALUES \(rows.joined(separator: ","))
        """)
        try w.close()
        return url
    }

    /// The full Z-schema with zero rows in every table — no accounts, no posts, no reply
    /// authors. Exists to pin down `populationStats` on an empty store: no crash, and a
    /// median of 0 rather than a divide-by-zero or out-of-range index.
    static func makeEmpty() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fixture.sqlite")
        let w = try SQLiteWriteHelper(at: url)
        try schema(w)
        try w.close()
        return url
    }

    /// One outlet, one root, one ordinary author (2 replies to that root), and one author
    /// whose single reply points at a root URI (`at://missing-root`) that does not exist
    /// anywhere in `ZPOST` — an orphaned reply, as if its root was never scraped or was
    /// later pruned.
    ///
    /// Exists to pin down `AggregateReader.authors`/`authorCount`'s deliberate join/no-join
    /// disagreement: joining every reply to its root (`p.ZROOTURI = r.ZURI AND
    /// r.ZISROOTPOST = 1`) drops a reply whose root isn't in the store, so a query that
    /// joins purely to support the optional outlet filter silently undercounts by however
    /// many orphaned replies exist. The unjoined path counts every row the author actually
    /// wrote, orphaned or not — see `AggregateReaderAuthorTests
    /// .testUnjoinedCountIncludesOrphanedReplyAuthorsThatTheJoinedOutletFilterExcludes`.
    static func makeWithOrphanedReply() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fixture.sqlite")
        let w = try SQLiteWriteHelper(at: url)
        try schema(w)

        try w.exec("""
        INSERT INTO ZTRACKEDACCOUNT (Z_PK, ZDID, ZHANDLE, ZDISPLAYNAME, ZISACTIVE)
        VALUES (1,'did:o1','outlet-one.com','Outlet One',1)
        """)

        var pk = 1
        func nextPK() -> Int { let p = pk; pk += 1; return p }

        let rows: [String] = [
            post(nextPK(), "at://r1", "did:root", "outlet-one.com", "2024-01-01T00:00:00Z",
                 root: "at://r1", isRoot: true, account: 1),
            post(nextPK(), "at://n1", "did:normal", "normal.test", "2024-01-02T00:00:00Z",
                 root: "at://r1", isRoot: false, account: nil),
            post(nextPK(), "at://n2", "did:normal", "normal.test", "2024-01-03T00:00:00Z",
                 root: "at://r1", isRoot: false, account: nil),
            // did:orphan's reply names a root URI that never appears anywhere in ZPOST —
            // no row has ZURI = 'at://missing-root'. A join to the root drops this row
            // entirely; a query straight off ZPOST still counts it.
            post(nextPK(), "at://orphan1", "did:orphan", "orphan.test", "2024-01-04T00:00:00Z",
                 root: "at://missing-root", isRoot: false, account: nil),
        ]

        try w.exec("""
        INSERT INTO ZPOST (Z_PK, ZURI, ZTEXT, ZCREATEDAT, ZAUTHORDID, ZAUTHORHANDLE,
                           ZPARENTURI, ZROOTURI, ZISROOTPOST, ZDEPTH, ZACCOUNT)
        VALUES \(rows.joined(separator: ","))
        """)
        try w.close()
        return url
    }

    /// One outlet, one author with `slowAuthorReplyCount` replies spread across distinct
    /// days (so `repliesPerWeek`'s per-row `Calendar` bucketing has real work to do, not
    /// 100 rows landing in one week), and one author ("did:fast") with a single reply.
    ///
    /// Exists solely so a per-author detail query can be made measurably slow in a test —
    /// `AuthorStatsViewModelTests.testRapidSelectionSettlesOnTheLastRequest` needs the
    /// *first* of two rapid selections to still be genuinely in flight when the *second*
    /// finishes, so that only the cancellation check (not incidental ordering) determines
    /// which one's data survives. `StoreFixture.make()`'s existing did:n100 (100 replies)
    /// is not remotely slow enough for that on real hardware.
    static func makeAuthorRace(slowAuthorReplyCount: Int = 20_000) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fixture.sqlite")
        let w = try SQLiteWriteHelper(at: url)
        try schema(w)

        try w.exec("""
        INSERT INTO ZTRACKEDACCOUNT (Z_PK, ZDID, ZHANDLE, ZDISPLAYNAME, ZISACTIVE)
        VALUES (1,'did:o1','outlet-one.com','Outlet One',1)
        """)

        var pk = 1
        func nextPK() -> Int { let p = pk; pk += 1; return p }

        var rows: [String] = [
            post(nextPK(), "at://r1", "did:root", "outlet-one.com", "2018-01-01T00:00:00Z",
                 root: "at://r1", isRoot: true, account: 1),
            post(nextPK(), "at://fast1", "did:fast", "fast.test", "2024-06-01T00:00:00Z",
                 root: "at://r1", isRoot: false, account: nil),
        ]
        // Spread across ~8 years, one reply per day, so every reply lands in its own
        // ISO week rather than collapsing into a handful of buckets.
        for i in 0..<slowAuthorReplyCount {
            let day = 60 * 60 * 24 * i
            let iso = ISO8601DateFormatter().string(
                from: date("2018-01-01T00:00:00Z").addingTimeInterval(TimeInterval(day)))
            rows.append(post(nextPK(), "at://slow\(i)", "did:slow", "slow.test", iso,
                              root: "at://r1", isRoot: false, account: nil))
        }

        // Batch the insert in chunks — a single multi-tens-of-thousands-row VALUES clause
        // is unnecessarily slow to build and execute.
        for chunk in rows.chunked(into: 2000) {
            try w.exec("""
            INSERT INTO ZPOST (Z_PK, ZURI, ZTEXT, ZCREATEDAT, ZAUTHORDID, ZAUTHORHANDLE,
                               ZPARENTURI, ZROOTURI, ZISROOTPOST, ZDEPTH, ZACCOUNT)
            VALUES \(chunk.joined(separator: ","))
            """)
        }
        try w.close()
        return url
    }

    /// Three reply authors, purpose-built for `mostRecentHandle`/`distinctHandles`:
    ///
    ///   did:multi     — two replies, two DIFFERENT handles: "old.test" (2024-01-01, the
    ///                   earlier reply) then "new.test" (2024-02-01, the most recent) —
    ///                   `mostRecentHandle` must return "new.test", not "old.test", and
    ///                   `distinctHandles` must return both, sorted.
    ///   did:single    — two replies, the SAME handle both times ("solo.test") — pins
    ///                   down that an author who never changed handles reports exactly
    ///                   one distinct handle, not two identical entries.
    ///   did:nohandle  — one reply with a NULL `ZAUTHORHANDLE` — pins down that a
    ///                   missing handle reports as `nil`/empty, never as the literal
    ///                   string "NULL" or a crash.
    static func makeAuthorHandleHistory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fixture.sqlite")
        let w = try SQLiteWriteHelper(at: url)
        try schema(w)

        try w.exec("""
        INSERT INTO ZTRACKEDACCOUNT (Z_PK, ZDID, ZHANDLE, ZDISPLAYNAME, ZISACTIVE)
        VALUES (1,'did:o1','outlet-one.com','Outlet One',1)
        """)

        var pk = 1
        func nextPK() -> Int { let p = pk; pk += 1; return p }

        var rows: [String] = [
            post(nextPK(), "at://r1", "did:root", "outlet-one.com", "2024-01-01T00:00:00Z",
                 root: "at://r1", isRoot: true, account: 1),
            post(nextPK(), "at://multi-old", "did:multi", "old.test", "2024-01-01T00:00:00Z",
                 root: "at://r1", isRoot: false, account: nil),
            post(nextPK(), "at://multi-new", "did:multi", "new.test", "2024-02-01T00:00:00Z",
                 root: "at://r1", isRoot: false, account: nil),
            post(nextPK(), "at://single-1", "did:single", "solo.test", "2024-01-05T00:00:00Z",
                 root: "at://r1", isRoot: false, account: nil),
            post(nextPK(), "at://single-2", "did:single", "solo.test", "2024-01-10T00:00:00Z",
                 root: "at://r1", isRoot: false, account: nil),
        ]
        // Written directly (not via `post`, which always quotes a handle) so
        // ZAUTHORHANDLE is a genuine SQL NULL rather than the literal string "NULL".
        let nohandlePK = nextPK()
        rows.append("""
            (\(nohandlePK),'at://nohandle-1','text',\(cd(date("2024-01-15T00:00:00Z"))),\
            'did:nohandle',NULL,'at://r1','at://r1',0,1,NULL)
            """)

        try w.exec("""
        INSERT INTO ZPOST (Z_PK, ZURI, ZTEXT, ZCREATEDAT, ZAUTHORDID, ZAUTHORHANDLE,
                           ZPARENTURI, ZROOTURI, ZISROOTPOST, ZDEPTH, ZACCOUNT)
        VALUES \(rows.joined(separator: ","))
        """)
        try w.close()
        return url
    }

    /// One author, `did:probed`, whose most recent reply carries `ZPOST.ZAUTHORHANDLE =
    /// "old.test"` but who also has a `ZREPLYAUTHOR` row (i.e. the profile probe has run
    /// for them) with `ZCURRENTHANDLE = "current.test"` — a deliberate disagreement
    /// between the two sources. Exists to pin down that `AggregateReader.authors(...)`
    /// prefers the probed `ZREPLYAUTHOR` value over the `ZPOST` fallback whenever both are
    /// present, not just whichever query plan happens to run first.
    static func makeWithProbedAuthor() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fixture.sqlite")
        let w = try SQLiteWriteHelper(at: url)
        try schema(w)

        try w.exec("""
        INSERT INTO ZTRACKEDACCOUNT (Z_PK, ZDID, ZHANDLE, ZDISPLAYNAME, ZISACTIVE)
        VALUES (1,'did:o1','outlet-one.com','Outlet One',1)
        """)

        var pk = 1
        func nextPK() -> Int { let p = pk; pk += 1; return p }

        let rows: [String] = [
            post(nextPK(), "at://r1", "did:root", "outlet-one.com", "2024-01-01T00:00:00Z",
                 root: "at://r1", isRoot: true, account: 1),
            post(nextPK(), "at://probed-1", "did:probed", "old.test", "2024-01-01T00:00:00Z",
                 root: "at://r1", isRoot: false, account: nil),
            post(nextPK(), "at://probed-2", "did:probed", "old.test", "2024-02-01T00:00:00Z",
                 root: "at://r1", isRoot: false, account: nil),
        ]

        try w.exec("""
        INSERT INTO ZPOST (Z_PK, ZURI, ZTEXT, ZCREATEDAT, ZAUTHORDID, ZAUTHORHANDLE,
                           ZPARENTURI, ZROOTURI, ZISROOTPOST, ZDEPTH, ZACCOUNT)
        VALUES \(rows.joined(separator: ","))
        """)

        try w.exec("""
        INSERT INTO ZREPLYAUTHOR (Z_PK, ZDID, ZFIRSTSEENAT, ZLASTSEENAT, ZCURRENTHANDLE,
                                   ZCURRENTSTATUS, ZLASTPROBEDAT)
        VALUES (1,'did:probed',\(cd(date("2024-01-01T00:00:00Z"))),\
        \(cd(date("2024-02-01T00:00:00Z"))),'current.test','active',\
        \(cd(date("2024-02-02T00:00:00Z"))))
        """)

        try w.close()
        return url
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
