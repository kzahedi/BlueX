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
          ZDEPTH INTEGER, ZACCOUNT INTEGER
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
                              _ iso: String, root: String, isRoot: Bool, account: Int?) -> String {
        let acct = account.map(String.init) ?? "NULL"
        return "(\(pk),'\(uri)','text',\(cd(date(iso))),'\(did)','\(handle)'," +
               "\(isRoot ? "NULL" : "'\(root)'"),'\(root)',\(isRoot ? 1 : 0)," +
               "\(isRoot ? 0 : 1),\(acct))"
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
            post(nextPK(), "at://c3", "did:c", "carol.test", "2024-03-01T00:00:00Z",
                 root: "at://r1", isRoot: false, account: nil),
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
}
