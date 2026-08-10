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

    /// Two outlets, four authors:
    ///   did:a — 3 replies to outlet 1, spanning 2024-01-01 … 2024-03-01
    ///   did:b — 2 replies, one to each outlet (cross-outlet)
    ///   did:c — 1 reply to outlet 2
    ///   did:root — the outlets' own root posts, must never appear as a reply author
    static func make() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fixture.sqlite")
        let w = try SQLiteWriteHelper(at: url)

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

        try w.exec("""
        INSERT INTO ZTRACKEDACCOUNT (Z_PK, ZDID, ZHANDLE, ZDISPLAYNAME, ZISACTIVE)
        VALUES (1,'did:o1','outlet-one.com','Outlet One',1),
               (2,'did:o2','outlet-two.com','Outlet Two',1)
        """)

        func post(_ pk: Int, _ uri: String, _ did: String, _ handle: String,
                  _ iso: String, root: String, isRoot: Bool, account: Int?) -> String {
            let acct = account.map(String.init) ?? "NULL"
            return "(\(pk),'\(uri)','text',\(cd(date(iso))),'\(did)','\(handle)'," +
                   "\(isRoot ? "NULL" : "'\(root)'"),'\(root)',\(isRoot ? 1 : 0)," +
                   "\(isRoot ? 0 : 1),\(acct))"
        }

        let rows = [
            post(1, "at://r1", "did:root", "outlet-one.com", "2024-01-01T00:00:00Z",
                 root: "at://r1", isRoot: true, account: 1),
            post(2, "at://r2", "did:root", "outlet-two.com", "2024-01-01T00:00:00Z",
                 root: "at://r2", isRoot: true, account: 2),
            post(3, "at://a1", "did:a", "alice.test", "2024-01-01T00:00:00Z",
                 root: "at://r1", isRoot: false, account: nil),
            post(4, "at://a2", "did:a", "alice.test", "2024-02-01T00:00:00Z",
                 root: "at://r1", isRoot: false, account: nil),
            post(5, "at://a3", "did:a", "alice.test", "2024-03-01T00:00:00Z",
                 root: "at://r1", isRoot: false, account: nil),
            post(6, "at://b1", "did:b", "bob.test", "2024-01-15T00:00:00Z",
                 root: "at://r1", isRoot: false, account: nil),
            post(7, "at://b2", "did:b", "bob.test", "2024-01-20T00:00:00Z",
                 root: "at://r2", isRoot: false, account: nil),
            post(8, "at://c1", "did:c", "carol.test", "2024-02-10T00:00:00Z",
                 root: "at://r2", isRoot: false, account: nil),
        ]
        try w.exec("""
        INSERT INTO ZPOST (Z_PK, ZURI, ZTEXT, ZCREATEDAT, ZAUTHORDID, ZAUTHORHANDLE,
                           ZPARENTURI, ZROOTURI, ZISROOTPOST, ZDEPTH, ZACCOUNT)
        VALUES \(rows.joined(separator: ","))
        """)
        try w.close()
        return url
    }
}
