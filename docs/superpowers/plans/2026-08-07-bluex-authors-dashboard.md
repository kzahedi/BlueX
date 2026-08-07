# Authors Dashboard and Shared Aggregation Layer — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace object-materialising aggregation with read-only SQL, then build a reply-author dashboard on top of it.

**Architecture:** A single `AggregateReader` owns a read-only SQLite connection to the SwiftData store and answers every counting question with `GROUP BY`. SwiftData keeps sole ownership of writes. The existing account and group charts, the author backfill, and the new dashboard all consume that one reader.

**Tech Stack:** Swift 5.9, SwiftUI, Swift Charts, SwiftData, SQLite3 (system library), XCTest, XcodeGen.

## Global Constraints

- Deployment target **macOS 14.0**; `SWIFT_VERSION: "5.9"`.
- The store lives at `/Volumes/Eregion/bluex-data/default.store`, overridable by `BLUEX_STORE_DIR`. Never hardcode `/Volumes` anywhere except through `BlueXStore.directory`.
- Open read-only connections with `?mode=ro`. **Never `?immutable=1`** — it is WAL-blind and has already reported 0 rows on a populated store.
- `AggregateReader` **never writes**. No `INSERT`, `UPDATE`, `DELETE`, or `CREATE` from the read-only connection.
- **All SQL in the app lives in `BlueX/Services/Stats/`.** No SQL statements anywhere else.
- Core Data stores dates as seconds since 2001-01-01. Convert with `+ 978307200` to Unix epoch.
- Aggregation never runs on the MainActor.
- Run `xcodegen generate` after any `project.yml` change.
- Do not modify the scrape or annotate write paths.

## Reference: measured facts (2026-08-07, live store)

| Fact | Value |
|---|---|
| Posts / roots / replies | 892,855 / 48,353 / 844,502 |
| Distinct reply-author DIDs | 146,541 |
| `ZREPLYAUTHOR`, `ZAUTHOROBSERVATION`, `ZANNOTATION` | all empty |
| Corpus span | 2018-01-01 → 2026-08-06 |
| Only existing index | `ZPOST_ZACCOUNT_INDEX` on `ZPOST(ZACCOUNT)` |
| `GROUP BY ZAUTHORDID` | 0.50s |
| `ORDER BY ZURI LIMIT 500 OFFSET n` | 1.9–4.8s **per page** |
| Outlet join, unindexed | 6.35s |
| Authors per outlet | 136,593 / 10,182 / 4,151 / 2,758 / 1,171 (sums > 146,541 — authors span outlets) |

## Reference: schema

```
ZPOST(Z_PK, ZURI, ZTEXT, ZCREATEDAT, ZAUTHORDID, ZAUTHORHANDLE,
      ZPARENTURI, ZROOTURI, ZISROOTPOST, ZDEPTH, ZACCOUNT, ZLIKECOUNT,
      ZREPLYCOUNT, ZQUOTECOUNT, ZREPOSTCOUNT)
ZREPLYAUTHOR(Z_PK, ZDID, ZFIRSTSEENAT, ZLASTSEENAT, ZCURRENTHANDLE,
             ZCURRENTSTATUS, ZLASTPROBEDAT)
ZTRACKEDACCOUNT(Z_PK, ZDID, ZHANDLE, ZDISPLAYNAME, ZAVATARURL, ZISACTIVE, ZSTARTAT)
```

`ZISROOTPOST` is 1/0. Replies carry `ZACCOUNT = NULL`; outlet attribution requires joining
`p.ZROOTURI = r.ZURI AND r.ZISROOTPOST = 1`.

## File Structure

| File | Responsibility |
|---|---|
| `BlueX/Services/Stats/SQLiteConnection.swift` (new) | Thin read-only sqlite3 wrapper: open, prepare, step, typed column access. No domain knowledge. |
| `BlueX/Services/Stats/AggregateReader.swift` (new) | Every SQL statement in the app. Returns plain structs. |
| `BlueX/Services/Stats/StatsModels.swift` (new) | `AuthorSummary`, `PopulationStats`, `WeekCount`, `OutletCount`, `HistogramBin`, `AuthorSort` |
| `BlueX/Services/Stats/Decimator.swift` (new) | Downsampling for large series |
| `BlueX/Services/Authors/AuthorBackfill.swift` (rewrite) | SQL fold, batched SwiftData insert, progress output |
| `BlueX/ViewModels/AuthorStatsViewModel.swift` (new) | Drives the dashboard off the reader |
| `BlueX/Views/Authors/AuthorsOverviewView.swift` (new) | Population charts |
| `BlueX/Views/Authors/AuthorListView.swift` (new) | Capped, sortable, filterable list |
| `BlueX/Views/Authors/AuthorDetailView.swift` (new) | Per-author stats + replies |
| `BlueX/ViewModels/ChartsViewModel.swift` (modify) | Buckets from the reader, not from `[Post]` |
| `BlueX/Views/Account/AccountChartsView.swift` (modify) | Delete `recompute()` and the `contains` scan |
| `BlueX/Views/Group/GroupChartsView.swift` (modify) | Same retrofit |
| `BlueX/Views/RootView.swift` (modify) | `SidebarItem.authors` routing |
| `BlueX/Views/Sidebar/SidebarView.swift` (modify) | Authors entry |

---

### Task 1: Read-only SQLite connection

**Files:**
- Create: `BlueX/Services/Stats/SQLiteConnection.swift`
- Test: `BlueXTests/Services/Stats/SQLiteConnectionTests.swift`
- Modify: `project.yml` — add `BlueX/Services/Stats` to the `BlueXTests` and `BlueX` target sources

**Interfaces:**
- Consumes: nothing
- Produces:
  - `final class SQLiteConnection` with `init(readOnlyAt url: URL) throws`
  - `func query<T>(_ sql: String, _ bind: [SQLValue] = [], row: (SQLRow) throws -> T) throws -> [T]`
  - `enum SQLValue { case text(String); case int(Int64); case double(Double) }`
  - `struct SQLRow { func int(_ i: Int32) -> Int64; func double(_ i: Int32) -> Double; func text(_ i: Int32) -> String?; func isNull(_ i: Int32) -> Bool }`
  - `enum SQLiteError: Error { case cannotOpen(String); case prepareFailed(String); case stepFailed(String) }`

- [ ] **Step 1: Write the failing test**

```swift
// BlueXTests/Services/Stats/SQLiteConnectionTests.swift
import XCTest
@testable import BlueX

final class SQLiteConnectionTests: XCTestCase {
    /// Builds a throwaway SQLite file so the tests never touch the real store.
    private func makeFixture() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fixture.sqlite")
        let write = try SQLiteWriteHelper(at: url)
        try write.exec("CREATE TABLE T (name TEXT, n INTEGER, x REAL, maybe TEXT)")
        try write.exec("INSERT INTO T VALUES ('a', 1, 1.5, NULL), ('b', 2, 2.5, 'set')")
        try write.close()
        return url
    }

    func testReadsTypedColumns() throws {
        let url = try makeFixture()
        let conn = try SQLiteConnection(readOnlyAt: url)
        let rows = try conn.query("SELECT name, n, x, maybe FROM T ORDER BY n") { r in
            (r.text(0), r.int(1), r.double(2), r.isNull(3))
        }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].0, "a")
        XCTAssertEqual(rows[0].1, 1)
        XCTAssertEqual(rows[0].2, 1.5, accuracy: 0.0001)
        XCTAssertTrue(rows[0].3)
        XCTAssertFalse(rows[1].3)
    }

    func testBindsParameters() throws {
        let url = try makeFixture()
        let conn = try SQLiteConnection(readOnlyAt: url)
        let names = try conn.query("SELECT name FROM T WHERE n > ?", [.int(1)]) { $0.text(0) }
        XCTAssertEqual(names, ["b"])
    }

    func testRejectsWrites() throws {
        let url = try makeFixture()
        let conn = try SQLiteConnection(readOnlyAt: url)
        // A read-only connection must refuse to mutate, so a bug elsewhere can never
        // corrupt the store SwiftData owns.
        XCTAssertThrowsError(try conn.query("DELETE FROM T") { _ in 0 })
    }

    func testMissingFileThrows() {
        let missing = URL(fileURLWithPath: "/nonexistent/definitely-not-here.sqlite")
        XCTAssertThrowsError(try SQLiteConnection(readOnlyAt: missing)) { error in
            guard case SQLiteError.cannotOpen = error else {
                return XCTFail("expected cannotOpen, got \(error)")
            }
        }
    }
}
```

Also create the tiny write helper the fixture needs (test-target only):

```swift
// BlueXTests/Services/Stats/SQLiteWriteHelper.swift
import Foundation
import SQLite3

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
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /Volumes/Eregion/projects/bluex-v2 && xcodegen generate
xcodebuild test -project BlueX.xcodeproj -scheme BlueXTests \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:BlueXTests/SQLiteConnectionTests -quiet 2>&1 | tail -20
```
Expected: FAIL — `cannot find 'SQLiteConnection' in scope`.

- [ ] **Step 3: Implement**

```swift
// BlueX/Services/Stats/SQLiteConnection.swift
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
        // FULLMUTEX puts THIS connection in serialized mode, which is what lets
        // AggregateReader be @unchecked Sendable. macOS system libsqlite3 reports
        // threadsafe == 2 (Multi-thread), so serialized is not the default here and
        // must be requested per connection.
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(uri, &handle, flags, nil) == SQLITE_OK, let handle else {
            throw SQLiteError.cannotOpen(url.path)
        }
        // FULLMUTEX cannot deliver serialization if the library was compiled with no
        // mutexes at all, so guard the precondition that actually matters.
        guard sqlite3_threadsafe() != 0 else {
            sqlite3_close(handle)
            throw SQLiteError.cannotOpen("sqlite compiled without mutexes")
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
```

Add `BlueX/Services/Stats` to the `BlueX` and `BlueXTests` target `sources` in `project.yml`.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd /Volumes/Eregion/projects/bluex-v2 && xcodegen generate
xcodebuild test -project BlueX.xcodeproj -scheme BlueXTests \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:BlueXTests/SQLiteConnectionTests -quiet 2>&1 | tail -20
```
Expected: 4 tests, all pass.

- [ ] **Step 5: Commit**

```bash
git add BlueX/Services/Stats/SQLiteConnection.swift \
        BlueXTests/Services/Stats/ project.yml BlueX.xcodeproj
git commit -m "feat(stats): read-only SQLite connection for aggregation

Aggregating by materialising SwiftData objects was measured at 2h44m for a
fold the equivalent GROUP BY does in 0.50s. This is the read path; SwiftData
stays the only writer."
```

---

### Task 2: Stats models and the schema guard

**Files:**
- Create: `BlueX/Services/Stats/StatsModels.swift`
- Create: `BlueX/Services/Stats/AggregateReader.swift`
- Test: `BlueXTests/Services/Stats/AggregateReaderSchemaTests.swift`
- Test: `BlueXTests/Services/Stats/StoreFixture.swift`

**Interfaces:**
- Consumes: `SQLiteConnection`, `SQLValue`, `SQLRow`, `SQLiteError` (Task 1)
- Produces:
  - `struct AuthorSummary { let did: String; let handle: String?; let replyCount: Int; let firstSeen: Date; let lastSeen: Date; let outletCount: Int }`
  - `struct WeekCount { let weekStart: Date; let count: Int }`
  - `struct OutletCount { let accountPK: Int64; let handle: String; let authors: Int; let replies: Int }`
  - `struct HistogramBin { let label: String; let lowerBound: Int; let upperBound: Int?; let authors: Int }`
  - `struct PopulationStats { let totalAuthors: Int; let totalReplies: Int; let medianRepliesPerAuthor: Int; let activeLast30Days: Int; let bins: [HistogramBin]; let outlets: [OutletCount]; let statusCounts: [String: Int] }`
  - `enum AuthorSort: String, CaseIterable { case replyCount, firstSeen, lastSeen, spanDays, did }`
  - `final class AggregateReader` with `init(storeURL: URL) throws` and `func verifySchema() throws`
  - `enum AggregateError: Error { case schemaMismatch(String) }`

- [ ] **Step 1: Write the fixture builder**

The fixture reproduces the real store's shape so every later query can be tested without
touching 892,855 live rows.

```swift
// BlueXTests/Services/Stats/StoreFixture.swift
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
```

- [ ] **Step 2: Write the failing schema-guard test**

```swift
// BlueXTests/Services/Stats/AggregateReaderSchemaTests.swift
import XCTest
@testable import BlueX

final class AggregateReaderSchemaTests: XCTestCase {
    func testAcceptsExpectedSchema() throws {
        let url = try StoreFixture.make()
        let reader = try AggregateReader(storeURL: url)
        XCTAssertNoThrow(try reader.verifySchema())
    }

    /// The reader queries Core Data's private Z-schema, which Apple does not promise to
    /// keep stable. A model change must fail loudly here rather than silently returning
    /// wrong numbers on a dashboard.
    func testRejectsMissingColumn() throws {
        let url = try StoreFixture.make()
        let w = try SQLiteWriteHelper(at: url)
        try w.exec("ALTER TABLE ZPOST DROP COLUMN ZAUTHORDID")
        try w.close()

        let reader = try AggregateReader(storeURL: url)
        XCTAssertThrowsError(try reader.verifySchema()) { error in
            guard case AggregateError.schemaMismatch(let detail) = error else {
                return XCTFail("expected schemaMismatch, got \(error)")
            }
            XCTAssertTrue(detail.contains("ZAUTHORDID"),
                          "the message must name the missing column, got: \(detail)")
        }
    }

    func testRejectsMissingTable() throws {
        let url = try StoreFixture.make()
        let w = try SQLiteWriteHelper(at: url)
        try w.exec("DROP TABLE ZREPLYAUTHOR")
        try w.close()

        let reader = try AggregateReader(storeURL: url)
        XCTAssertThrowsError(try reader.verifySchema()) { error in
            guard case AggregateError.schemaMismatch(let detail) = error else {
                return XCTFail("expected schemaMismatch, got \(error)")
            }
            XCTAssertTrue(detail.contains("ZREPLYAUTHOR"))
        }
    }
}
```

- [ ] **Step 3: Run to verify it fails**

```bash
cd /Volumes/Eregion/projects/bluex-v2 && xcodegen generate
xcodebuild test -project BlueX.xcodeproj -scheme BlueXTests \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:BlueXTests/AggregateReaderSchemaTests -quiet 2>&1 | tail -20
```
Expected: FAIL — `cannot find 'AggregateReader' in scope`.

- [ ] **Step 4: Implement the models**

```swift
// BlueX/Services/Stats/StatsModels.swift
import Foundation

struct AuthorSummary: Identifiable, Hashable {
    var id: String { did }
    let did: String
    /// nil until the account probe runs — the backfill records identity, not profile.
    let handle: String?
    let replyCount: Int
    let firstSeen: Date
    let lastSeen: Date
    let outletCount: Int

    var spanDays: Int {
        max(0, Calendar(identifier: .iso8601)
            .dateComponents([.day], from: firstSeen, to: lastSeen).day ?? 0)
    }
}

struct WeekCount: Identifiable, Hashable {
    var id: Date { weekStart }
    let weekStart: Date
    let count: Int
}

struct OutletCount: Identifiable, Hashable {
    var id: Int64 { accountPK }
    let accountPK: Int64
    let handle: String
    let authors: Int
    let replies: Int
}

struct HistogramBin: Identifiable, Hashable {
    var id: String { label }
    let label: String
    let lowerBound: Int
    /// nil means unbounded — the top bin.
    let upperBound: Int?
    let authors: Int
}

struct PopulationStats {
    let totalAuthors: Int
    let totalReplies: Int
    let medianRepliesPerAuthor: Int
    let activeLast30Days: Int
    let bins: [HistogramBin]
    let outlets: [OutletCount]
    /// Reads entirely "unknown" until the probe subsystem ships.
    let statusCounts: [String: Int]

    static let empty = PopulationStats(
        totalAuthors: 0, totalReplies: 0, medianRepliesPerAuthor: 0,
        activeLast30Days: 0, bins: [], outlets: [], statusCounts: [:]
    )
}

enum AuthorSort: String, CaseIterable, Identifiable {
    case replyCount, firstSeen, lastSeen, spanDays, did
    var id: String { rawValue }

    var label: String {
        switch self {
        case .replyCount: return "Replies"
        case .firstSeen:  return "First seen"
        case .lastSeen:   return "Last seen"
        case .spanDays:   return "Span"
        case .did:        return "DID"
        }
    }

    /// The ORDER BY fragment. Kept beside the enum so a new case cannot be added
    /// without deciding how it sorts.
    var orderBy: String {
        switch self {
        case .replyCount: return "reply_count DESC"
        case .firstSeen:  return "first_seen ASC"
        case .lastSeen:   return "last_seen DESC"
        case .spanDays:   return "(last_seen - first_seen) DESC"
        case .did:        return "did ASC"
        }
    }
}
```

- [ ] **Step 5: Implement the reader skeleton and schema guard**

```swift
// BlueX/Services/Stats/AggregateReader.swift
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
        try self.init(storeURL: BlueXStore.directory.appendingPathComponent("default.store"))
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
            ) { $0.text(0) }
            guard !present.isEmpty else {
                throw AggregateError.schemaMismatch("missing table \(table)")
            }
            let actual = Set(try conn.query("PRAGMA table_info(\(table))") { $0.text(1) }
                .compactMap { $0 })
            for column in columns where !actual.contains(column) {
                throw AggregateError.schemaMismatch("missing column \(table).\(column)")
            }
        }
    }

    // MARK: - Date helpers

    static func date(fromCoreData seconds: Double) -> Date {
        Date(timeIntervalSince1970: seconds + coreDataEpochOffset)
    }

    static func coreData(from date: Date) -> Double {
        date.timeIntervalSince1970 - coreDataEpochOffset
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
cd /Volumes/Eregion/projects/bluex-v2 && xcodegen generate
xcodebuild test -project BlueX.xcodeproj -scheme BlueXTests \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:BlueXTests/AggregateReaderSchemaTests -quiet 2>&1 | tail -20
```
Expected: 3 tests pass.

If `ALTER TABLE ... DROP COLUMN` is unsupported by the linked SQLite version, rebuild the
fixture table without that column instead of altering it — do not weaken the assertion.

- [ ] **Step 7: Commit**

```bash
git add BlueX/Services/Stats/ BlueXTests/Services/Stats/ project.yml BlueX.xcodeproj
git commit -m "feat(stats): stats models and schema guard

The reader depends on Core Data's private Z-schema. verifySchema() turns a
model change into a failing test rather than silently wrong dashboard numbers."
```

---

### Task 3: Settle the index route by measurement

**Files:**
- Modify: `BlueX/Data/Post.swift` — possibly add `@Attribute(.indexed)`
- Create: `docs/superpowers/notes/2026-08-07-index-route-measurement.md`
- Test: `BlueXTests/Services/Stats/IndexPlanTests.swift`

**Interfaces:**
- Consumes: `AggregateReader`, `SQLiteConnection` (Tasks 1–2)
- Produces: `func explainQueryPlan(_ sql: String) throws -> [String]` on `AggregateReader`

**This task answers an open question rather than assuming an answer.** The spec deliberately
leaves the route unsettled. Do not skip the measurement and pick one.

- [ ] **Step 1: Add `explainQueryPlan` and a test that it reports a scan**

```swift
// append to BlueX/Services/Stats/AggregateReader.swift, inside the class
    /// Returns SQLite's plan for a statement. Used to prove an index is actually used
    /// rather than assumed.
    func explainQueryPlan(_ sql: String) throws -> [String] {
        try conn.query("EXPLAIN QUERY PLAN \(sql)") { $0.text(3) ?? "" }
    }
```

```swift
// BlueXTests/Services/Stats/IndexPlanTests.swift
import XCTest
@testable import BlueX

final class IndexPlanTests: XCTestCase {
    private let outletJoin = """
    SELECT r.ZACCOUNT, COUNT(DISTINCT p.ZAUTHORDID)
    FROM ZPOST p JOIN ZPOST r ON p.ZROOTURI = r.ZURI AND r.ZISROOTPOST = 1
    WHERE p.ZISROOTPOST = 0 GROUP BY r.ZACCOUNT
    """

    func testUnindexedFixtureScans() throws {
        let url = try StoreFixture.make()
        let reader = try AggregateReader(storeURL: url)
        let plan = try reader.explainQueryPlan(outletJoin).joined(separator: " | ")
        XCTAssertTrue(plan.contains("SCAN"), "expected a scan without indexes, got: \(plan)")
    }

    func testIndexOnRootURIIsUsed() throws {
        let url = try StoreFixture.make()
        let w = try SQLiteWriteHelper(at: url)
        try w.exec("CREATE INDEX IF NOT EXISTS IDX_ZPOST_ZURI ON ZPOST(ZURI)")
        try w.exec("CREATE INDEX IF NOT EXISTS IDX_ZPOST_ZROOTURI ON ZPOST(ZROOTURI)")
        try w.exec("CREATE INDEX IF NOT EXISTS IDX_ZPOST_ZAUTHORDID ON ZPOST(ZAUTHORDID)")
        try w.close()

        let reader = try AggregateReader(storeURL: url)
        let plan = try reader.explainQueryPlan(outletJoin).joined(separator: " | ")
        XCTAssertTrue(plan.contains("USING INDEX") || plan.contains("SEARCH"),
                      "expected the join to use an index, got: \(plan)")
    }
}
```

- [ ] **Step 2: Run to verify the plan test fails, then passes**

```bash
cd /Volumes/Eregion/projects/bluex-v2 && xcodegen generate
xcodebuild test -project BlueX.xcodeproj -scheme BlueXTests \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:BlueXTests/IndexPlanTests -quiet 2>&1 | tail -20
```
Expected: FAIL first (`explainQueryPlan` missing), then both tests pass.

- [ ] **Step 3: Measure route 1 — does `@Attribute(.indexed)` emit an index on macOS 14?**

Add the attribute:

```swift
// BlueX/Data/Post.swift — change these two lines
    @Attribute(.indexed) var authorDID: String
    @Attribute(.indexed) var rootURI: String
```

Then build a **throwaway** SwiftData store and inspect it. Never point this at the real store:

```bash
cd /Volumes/Eregion/projects/bluex-v2 && xcodegen generate
xcodebuild build -project BlueX.xcodeproj -scheme BlueXTests \
  -destination 'platform=macOS,arch=arm64' -quiet 2>&1 | tail -5

export BLUEX_STORE_DIR="$(mktemp -d)/probe"
mkdir -p "$BLUEX_STORE_DIR"
~/.local/bin/blueX-authors --stats
sqlite3 "file:$BLUEX_STORE_DIR/default.store?mode=ro" \
  "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='ZPOST';"
```

Record the exact output. If index names appear for `ZAUTHORDID` and `ZROOTURI`, route 1
works. If only `ZPOST_ZACCOUNT_INDEX` appears, the attribute was ignored on this
deployment target and route 1 is dead.

- [ ] **Step 4: If route 1 failed, measure route 2 — survival across migration**

Revert the `@Attribute(.indexed)` change, then on a **throwaway** store: create the indexes
by hand, force a lightweight migration by adding a scratch property to a model, reopen, and
re-inspect `sqlite_master`. Record whether the hand-made indexes survived.

```bash
sqlite3 "$BLUEX_STORE_DIR/default.store" \
  "CREATE INDEX IF NOT EXISTS IDX_ZPOST_ZAUTHORDID ON ZPOST(ZAUTHORDID);
   CREATE INDEX IF NOT EXISTS IDX_ZPOST_ZROOTURI ON ZPOST(ZROOTURI);
   CREATE INDEX IF NOT EXISTS IDX_ZPOST_ZURI ON ZPOST(ZURI);"
```

- [ ] **Step 5: Write up the measurement**

Create `docs/superpowers/notes/2026-08-07-index-route-measurement.md` recording: the exact
commands, the exact `sqlite_master` output for each route, which route was chosen, and why.
This is the evidence for a decision the spec left open — a later reader must be able to
check it rather than trust it.

- [ ] **Step 6: Apply the chosen route to the real store and prove the gain**

Before:
```bash
cd /Volumes/Eregion/bluex-data && time sqlite3 "file:default.store?mode=ro" \
  "SELECT r.ZACCOUNT, COUNT(DISTINCT p.ZAUTHORDID) FROM ZPOST p
   JOIN ZPOST r ON p.ZROOTURI = r.ZURI AND r.ZISROOTPOST=1
   WHERE p.ZISROOTPOST=0 GROUP BY r.ZACCOUNT;"
```
Expected baseline: ~6.35s (measured 2026-08-07).

Apply the route, then re-run the same command and record the new time. **Stop and report if
the store's `PRAGMA quick_check` is anything other than `ok` afterwards.**

- [ ] **Step 7: Commit**

```bash
git add BlueX/Data/Post.swift BlueX/Services/Stats/AggregateReader.swift \
        BlueXTests/Services/Stats/IndexPlanTests.swift \
        docs/superpowers/notes/2026-08-07-index-route-measurement.md \
        project.yml BlueX.xcodeproj
git commit -m "perf(stats): index authorDID/rootURI, route settled by measurement

The store had exactly one index (on ZACCOUNT), so the outlet join was a full
scan at 6.35s. EXPLAIN QUERY PLAN now proves an index is used rather than
assumed. Measurement written up in docs/superpowers/notes/."
```

---

### Task 4: Per-author aggregate queries

**Files:**
- Modify: `BlueX/Services/Stats/AggregateReader.swift`
- Test: `BlueXTests/Services/Stats/AggregateReaderAuthorTests.swift`

**Interfaces:**
- Consumes: `AuthorSummary`, `AuthorSort`, `AggregateReader` (Tasks 2–3)
- Produces on `AggregateReader`:
  - `func authorCount() throws -> Int`
  - `func authors(sort: AuthorSort, limit: Int, minReplies: Int = 1, outletPK: Int64? = nil) throws -> [AuthorSummary]`
  - `func authorDetail(did: String) throws -> AuthorSummary?`
  - `func repliesPerWeek(did: String) throws -> [WeekCount]`
  - `func outletBreakdown(did: String) throws -> [OutletCount]`

- [ ] **Step 1: Write the failing tests**

```swift
// BlueXTests/Services/Stats/AggregateReaderAuthorTests.swift
import XCTest
@testable import BlueX

final class AggregateReaderAuthorTests: XCTestCase {
    private var reader: AggregateReader!

    override func setUpWithError() throws {
        reader = try AggregateReader(storeURL: try StoreFixture.make())
    }

    /// The fixture has 4 distinct DIDs but one of them only ever authors root posts.
    /// Root authors are the tracked outlets, not the public — counting them would
    /// inflate the population.
    func testAuthorCountExcludesRootAuthors() throws {
        XCTAssertEqual(try reader.authorCount(), 3)
    }

    func testAuthorsSortedByReplyCount() throws {
        let authors = try reader.authors(sort: .replyCount, limit: 10)
        XCTAssertEqual(authors.map(\.did), ["did:a", "did:b", "did:c"])
        XCTAssertEqual(authors.map(\.replyCount), [3, 2, 1])
    }

    func testLimitCapsResultsButNotSelection() throws {
        let top = try reader.authors(sort: .replyCount, limit: 1)
        XCTAssertEqual(top.count, 1)
        // The cap must select the top of the whole population, not the first row found.
        XCTAssertEqual(top.first?.did, "did:a")
    }

    func testFirstAndLastSeenSpanTheAuthorsReplies() throws {
        let a = try XCTUnwrap(try reader.authorDetail(did: "did:a"))
        XCTAssertEqual(a.firstSeen, StoreFixture.date("2024-01-01T00:00:00Z"))
        XCTAssertEqual(a.lastSeen, StoreFixture.date("2024-03-01T00:00:00Z"))
        XCTAssertEqual(a.replyCount, 3)
    }

    func testOutletCountDetectsCrossOutletAuthor() throws {
        let b = try XCTUnwrap(try reader.authorDetail(did: "did:b"))
        XCTAssertEqual(b.outletCount, 2, "did:b replies to both outlets")
        let a = try XCTUnwrap(try reader.authorDetail(did: "did:a"))
        XCTAssertEqual(a.outletCount, 1)
    }

    func testMinRepliesFilter() throws {
        let heavy = try reader.authors(sort: .replyCount, limit: 10, minReplies: 2)
        XCTAssertEqual(heavy.map(\.did), ["did:a", "did:b"])
    }

    func testOutletFilter() throws {
        let outletTwo = try reader.authors(sort: .replyCount, limit: 10, outletPK: 2)
        XCTAssertEqual(Set(outletTwo.map(\.did)), ["did:b", "did:c"])
    }

    func testRepliesPerWeekBucketsByISOWeek() throws {
        let weeks = try reader.repliesPerWeek(did: "did:a")
        XCTAssertEqual(weeks.map(\.count).reduce(0, +), 3)
        XCTAssertEqual(weeks.count, 3, "three replies a month apart fall in three weeks")
        XCTAssertEqual(weeks, weeks.sorted { $0.weekStart < $1.weekStart },
                       "weeks must come back in chronological order")
    }

    func testUnknownAuthorReturnsNil() throws {
        XCTAssertNil(try reader.authorDetail(did: "did:nobody"))
    }

    func testHandleIsNilWhenNotProbed() throws {
        // ZREPLYAUTHOR is empty in the fixture, mirroring the real store before probing.
        let a = try XCTUnwrap(try reader.authorDetail(did: "did:a"))
        XCTAssertNil(a.handle)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
cd /Volumes/Eregion/projects/bluex-v2 && xcodegen generate
xcodebuild test -project BlueX.xcodeproj -scheme BlueXTests \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:BlueXTests/AggregateReaderAuthorTests -quiet 2>&1 | tail -20
```
Expected: FAIL — `authorCount` and friends do not exist.

- [ ] **Step 3: Implement**

```swift
// append to BlueX/Services/Stats/AggregateReader.swift, inside the class

    // MARK: - Authors

    /// Distinct reply authors. Root posts are excluded: their authors are the tracked
    /// outlets, not members of the public.
    func authorCount() throws -> Int {
        let rows = try conn.query(
            "SELECT COUNT(DISTINCT ZAUTHORDID) FROM ZPOST WHERE ZISROOTPOST = 0"
        ) { Int($0.int(0)) }
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
                did: r.text(0) ?? "",
                handle: r.text(5),
                replyCount: Int(r.int(1)),
                firstSeen: Self.date(fromCoreData: r.double(2)),
                lastSeen: Self.date(fromCoreData: r.double(3)),
                outletCount: Int(r.int(4))
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
                did: r.text(0) ?? "",
                handle: r.text(5),
                replyCount: Int(r.int(1)),
                firstSeen: Self.date(fromCoreData: r.double(2)),
                lastSeen: Self.date(fromCoreData: r.double(3)),
                outletCount: Int(r.int(4))
            )
        }.first
    }

    /// Weekly buckets, aligned to ISO Monday. SQLite has no ISO-week function, so the
    /// alignment happens in Swift against the raw timestamps.
    func repliesPerWeek(did: String) throws -> [WeekCount] {
        let stamps = try conn.query(
            "SELECT ZCREATEDAT FROM ZPOST WHERE ZISROOTPOST = 0 AND ZAUTHORDID = ?",
            [.text(did)]
        ) { Self.date(fromCoreData: $0.double(0)) }

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
            OutletCount(accountPK: r.int(0),
                        handle: r.text(1) ?? "unknown",
                        authors: 1,
                        replies: Int(r.int(2)))
        }
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd /Volumes/Eregion/projects/bluex-v2 && xcodegen generate
xcodebuild test -project BlueX.xcodeproj -scheme BlueXTests \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:BlueXTests/AggregateReaderAuthorTests -quiet 2>&1 | tail -20
```
Expected: 10 tests pass.

- [ ] **Step 5: Sanity-check against the real store**

```bash
cd /Volumes/Eregion/bluex-data && time sqlite3 "file:default.store?mode=ro" \
  "SELECT COUNT(DISTINCT ZAUTHORDID) FROM ZPOST WHERE ZISROOTPOST = 0;"
```
Expected: `146541`. If it differs, the corpus grew — record the new figure in the report
rather than editing the test.

- [ ] **Step 6: Commit**

```bash
git add BlueX/Services/Stats/AggregateReader.swift \
        BlueXTests/Services/Stats/AggregateReaderAuthorTests.swift
git commit -m "feat(stats): per-author aggregate queries

Sorting and filtering happen in SQL across the whole population, so the
display cap selects the true top-N rather than the first N rows found."
```

---

### Task 5: Population aggregate queries

**Files:**
- Modify: `BlueX/Services/Stats/AggregateReader.swift`
- Test: `BlueXTests/Services/Stats/AggregateReaderPopulationTests.swift`

**Interfaces:**
- Consumes: `PopulationStats`, `HistogramBin`, `OutletCount`, `WeekCount`
- Produces on `AggregateReader`:
  - `func populationStats(now: Date) throws -> PopulationStats`
  - `func newAuthorsPerWeek() throws -> [WeekCount]`

- [ ] **Step 1: Write the failing tests**

```swift
// BlueXTests/Services/Stats/AggregateReaderPopulationTests.swift
import XCTest
@testable import BlueX

final class AggregateReaderPopulationTests: XCTestCase {
    private var reader: AggregateReader!

    override func setUpWithError() throws {
        reader = try AggregateReader(storeURL: try StoreFixture.make())
    }

    func testTotals() throws {
        let s = try reader.populationStats(now: StoreFixture.date("2024-04-01T00:00:00Z"))
        XCTAssertEqual(s.totalAuthors, 3)
        XCTAssertEqual(s.totalReplies, 6)
    }

    func testMedianRepliesPerAuthor() throws {
        // Reply counts are 3, 2, 1 — median 2.
        let s = try reader.populationStats(now: StoreFixture.date("2024-04-01T00:00:00Z"))
        XCTAssertEqual(s.medianRepliesPerAuthor, 2)
    }

    func testBinsCoverEveryAuthorExactlyOnce() throws {
        let s = try reader.populationStats(now: StoreFixture.date("2024-04-01T00:00:00Z"))
        XCTAssertEqual(s.bins.map(\.authors).reduce(0, +), s.totalAuthors,
                       "every author must land in exactly one bin")
        let singles = try XCTUnwrap(s.bins.first { $0.lowerBound == 1 && $0.upperBound == 1 })
        XCTAssertEqual(singles.authors, 1, "did:c has one reply")
    }

    func testActiveLast30Days() throws {
        // Latest reply overall is 2024-03-01 (did:a).
        let recent = try reader.populationStats(now: StoreFixture.date("2024-03-15T00:00:00Z"))
        XCTAssertEqual(recent.activeLast30Days, 1)
        let stale = try reader.populationStats(now: StoreFixture.date("2025-01-01T00:00:00Z"))
        XCTAssertEqual(stale.activeLast30Days, 0)
    }

    func testOutletCountsSumAboveTotalBecauseAuthorsSpanOutlets() throws {
        let s = try reader.populationStats(now: StoreFixture.date("2024-04-01T00:00:00Z"))
        let summed = s.outlets.map(\.authors).reduce(0, +)
        XCTAssertEqual(summed, 4, "did:b counted under both outlets")
        XCTAssertGreaterThan(summed, s.totalAuthors)
    }

    func testStatusCountsEmptyBeforeBackfill() throws {
        let s = try reader.populationStats(now: StoreFixture.date("2024-04-01T00:00:00Z"))
        XCTAssertTrue(s.statusCounts.isEmpty,
                      "ZREPLYAUTHOR is empty until the backfill runs")
    }

    func testNewAuthorsPerWeekCountsFirstAppearanceOnly() throws {
        let weeks = try reader.newAuthorsPerWeek()
        XCTAssertEqual(weeks.map(\.count).reduce(0, +), 3,
                       "each author is new exactly once")
        XCTAssertEqual(weeks, weeks.sorted { $0.weekStart < $1.weekStart })
    }
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
cd /Volumes/Eregion/projects/bluex-v2 && xcodegen generate
xcodebuild test -project BlueX.xcodeproj -scheme BlueXTests \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:BlueXTests/AggregateReaderPopulationTests -quiet 2>&1 | tail -20
```
Expected: FAIL — `populationStats` does not exist.

- [ ] **Step 3: Implement**

```swift
// append to BlueX/Services/Stats/AggregateReader.swift, inside the class

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
            """) { (Int($0.int(0)), Self.date(fromCoreData: $0.double(1))) }

        let totalAuthors = counts.count
        let totalReplies = counts.map(\.0).reduce(0, +)

        let sortedCounts = counts.map(\.0).sorted()
        let median = sortedCounts.isEmpty ? 0 : sortedCounts[sortedCounts.count / 2]

        let cutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
        let active = counts.filter { $0.1 >= cutoff && $0.1 <= now }.count

        let bins = Self.binEdges.map { edge in
            HistogramBin(
                label: edge.label,
                lowerBound: edge.lower,
                upperBound: edge.upper,
                authors: counts.filter {
                    $0.0 >= edge.lower && (edge.upper.map { u in $0.0 <= u } ?? true)
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
            OutletCount(accountPK: r.int(0),
                        handle: r.text(1) ?? "unknown",
                        authors: Int(r.int(2)),
                        replies: Int(r.int(3)))
        }

        var statusCounts: [String: Int] = [:]
        for row in try conn.query(
            "SELECT ZCURRENTSTATUS, COUNT(*) FROM ZREPLYAUTHOR GROUP BY ZCURRENTSTATUS"
        ) { (r: SQLRow) in (r.text(0) ?? "unknown", Int(r.int(1))) } {
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

    /// An author is "new" in the week of their first reply, and never again.
    func newAuthorsPerWeek() throws -> [WeekCount] {
        let firsts = try conn.query("""
            SELECT MIN(ZCREATEDAT) FROM ZPOST WHERE ZISROOTPOST = 0 GROUP BY ZAUTHORDID
            """) { Self.date(fromCoreData: $0.double(0)) }

        let calendar = Calendar(identifier: .iso8601)
        var counts: [Date: Int] = [:]
        for stamp in firsts {
            let start = calendar.dateInterval(of: .weekOfYear, for: stamp)?.start ?? stamp
            counts[start, default: 0] += 1
        }
        return counts.map { WeekCount(weekStart: $0.key, count: $0.value) }
            .sorted { $0.weekStart < $1.weekStart }
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd /Volumes/Eregion/projects/bluex-v2 && xcodegen generate
xcodebuild test -project BlueX.xcodeproj -scheme BlueXTests \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:BlueXTests/AggregateReaderPopulationTests -quiet 2>&1 | tail -20
```
Expected: 7 tests pass.

- [ ] **Step 5: Time it against the real store**

```bash
cd /Volumes/Eregion/projects/bluex-v2 && cat > /tmp/pop.sql <<'SQL'
.timer on
SELECT COUNT(*) FROM (SELECT COUNT(*) FROM ZPOST WHERE ZISROOTPOST=0 GROUP BY ZAUTHORDID);
SQL
sqlite3 "file:/Volumes/Eregion/bluex-data/default.store?mode=ro" < /tmp/pop.sql
```
Record the timing in the task report. If the per-author fold exceeds ~3s, say so — the
view will need a loading state rather than a synchronous call.

- [ ] **Step 6: Commit**

```bash
git add BlueX/Services/Stats/AggregateReader.swift \
        BlueXTests/Services/Stats/AggregateReaderPopulationTests.swift
git commit -m "feat(stats): population aggregates

Outlet author counts deliberately sum above the population total — authors
reply across outlets, and that overlap is the cross-outlet signal."
```

---

### Task 6: Rewrite AuthorBackfill on SQL, and run it

**Files:**
- Modify: `BlueX/Services/Authors/AuthorBackfill.swift` (full rewrite)
- Modify: `cli/authors/main.swift` — progress output
- Test: `BlueXTests/Services/Authors/AuthorBackfillTests.swift` (existing — keep passing)

**Interfaces:**
- Consumes: `AggregateReader` (Tasks 2–5), `BlueXStore.openContainer()`
- Produces: `AuthorBackfill(container:reader:)` with
  `func run(batchSize: Int = 5_000, progress: ((Int, Int) -> Void)? = nil) throws -> (created: Int, updated: Int)`

**Why this is a rewrite, not a tune.** The current implementation pages with
`sortBy: [SortDescriptor(\Post.uri)]` (`AuthorBackfill.swift:27`), which re-sorts 892,855
unindexed strings on **every** page. Measured: 1.9–4.8s per page × ~1,786 pages ≈ 75
minutes of sorting alone, before any object materialisation. The live run reached 2h44m
without writing a row and was killed.

- [ ] **Step 1: Extend the existing tests**

Keep the three existing tests (per-DID range, root exclusion, idempotency) passing
unchanged — they define the contract. Add:

```swift
    func testReportsProgress() throws {
        let container = try makeInMemoryContainer()   // existing helper in this file
        try seedPosts(in: container)                  // existing helper
        let reader = try AggregateReader(storeURL: try StoreFixture.make())

        var updates: [(Int, Int)] = []
        _ = try AuthorBackfill(container: container, reader: reader)
            .run(batchSize: 1) { done, total in updates.append((done, total)) }

        XCTAssertFalse(updates.isEmpty, "a multi-hour job must not be silent")
        XCTAssertEqual(updates.last?.0, updates.last?.1,
                       "the final callback must report completion")
        XCTAssertEqual(updates.map(\.0), updates.map(\.0).sorted(),
                       "progress must be monotonic")
    }
```

If the helpers named above do not exist under those names in the current test file, use
whatever the file already defines — do not rename existing helpers.

- [ ] **Step 2: Run to verify the new test fails**

```bash
cd /Volumes/Eregion/projects/bluex-v2 && xcodegen generate
xcodebuild test -project BlueX.xcodeproj -scheme BlueXTests \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:BlueXTests/AuthorBackfillTests -quiet 2>&1 | tail -20
```
Expected: the three existing tests pass; `testReportsProgress` fails to compile because
the initialiser takes no `reader` and `run` takes no `progress`.

- [ ] **Step 3: Rewrite**

```swift
// BlueX/Services/Authors/AuthorBackfill.swift
import Foundation
import SwiftData

/// Creates one `ReplyAuthor` per distinct reply-author DID, and keeps `firstSeenAt` /
/// `lastSeenAt` current as the corpus grows.
///
/// The fold is done in SQL. The previous implementation paged `Post` through SwiftData
/// with `sortBy: [SortDescriptor(\Post.uri)]`, which re-sorted ~892k unindexed strings
/// on every page: measured 1.9–4.8s per page across ~1,786 pages, and a live run reached
/// 2h44m without writing a row. The equivalent GROUP BY takes 0.50s.
///
/// Writes still go through SwiftData, because that is what the app reads.
struct AuthorBackfill {
    private let container: ModelContainer
    private let reader: AggregateReader

    init(container: ModelContainer, reader: AggregateReader) {
        self.container = container
        self.reader = reader
    }

    /// - Parameter progress: called as `(authorsWritten, authorsTotal)`. A job that can
    ///   run for minutes must report, so it is never mistaken for a hang.
    @discardableResult
    func run(batchSize: Int = 5_000,
             progress: ((Int, Int) -> Void)? = nil) throws -> (created: Int, updated: Int) {
        let ranges = try reader.authorSeenRanges()
        let total = ranges.count

        let write = ModelContext(container)
        let existing = try write.fetch(FetchDescriptor<ReplyAuthor>())
        var byDID = Dictionary(uniqueKeysWithValues: existing.map { ($0.did, $0) })

        var created = 0, updated = 0, done = 0
        for (did, range) in ranges {
            if let a = byDID[did] {
                let newFirst = min(a.firstSeenAt, range.first)
                let newLast = max(a.lastSeenAt, range.last)
                if newFirst != a.firstSeenAt || newLast != a.lastSeenAt {
                    a.firstSeenAt = newFirst
                    a.lastSeenAt = newLast
                    updated += 1
                }
            } else {
                let a = ReplyAuthor(did: did, firstSeenAt: range.first, lastSeenAt: range.last)
                write.insert(a)
                byDID[did] = a
                created += 1
            }
            done += 1
            // Save in batches so the transaction never grows to 146k pending inserts.
            if done % batchSize == 0 {
                try write.save()
                progress?(done, total)
            }
        }
        try write.save()
        progress?(done, total)
        return (created, updated)
    }
}
```

Add the supporting query to the reader:

```swift
// append to BlueX/Services/Stats/AggregateReader.swift, inside the class

    /// One first/last-reply range per distinct author DID. The whole fold, in one query.
    func authorSeenRanges() throws -> [(did: String, first: Date, last: Date)] {
        try conn.query("""
            SELECT ZAUTHORDID, MIN(ZCREATEDAT), MAX(ZCREATEDAT)
            FROM ZPOST WHERE ZISROOTPOST = 0 GROUP BY ZAUTHORDID
            """) { r in
            (did: r.text(0) ?? "",
             first: Self.date(fromCoreData: r.double(1)),
             last: Self.date(fromCoreData: r.double(2)))
        }
    }
```

Wire progress into the CLI:

```swift
// cli/authors/main.swift — replace the backfill branch body
    if args.backfill {
        let start = Date()
        do {
            let reader = try AggregateReader()
            try reader.verifySchema()
            let r = try AuthorBackfill(container: container, reader: reader)
                .run { done, total in
                    writeFinalLine("backfill — \(done)/\(total) authors")
                }
            writeFinalLine("backfill — \(r.created) created, \(r.updated) updated in \(formatDuration(Date().timeIntervalSince(start)))")
        } catch { fail("blueX-authors", "backfill failed: \(error)") }
    }
```

- [ ] **Step 4: Run the tests**

```bash
cd /Volumes/Eregion/projects/bluex-v2 && xcodegen generate
xcodebuild test -project BlueX.xcodeproj -scheme BlueXTests \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:BlueXTests/AuthorBackfillTests -quiet 2>&1 | tail -20
```
Expected: 4 tests pass.

- [ ] **Step 5: Full suite, then rebuild the CLIs**

```bash
cd /Volumes/Eregion/projects/bluex-v2
xcodebuild test -project BlueX.xcodeproj -scheme BlueXTests \
  -destination 'platform=macOS,arch=arm64' -quiet 2>&1 | tail -20
tools/install-cli.sh
~/.local/bin/blueX-scrape --list-accounts | head -3
```
Expected: full suite green; the scrape CLI still lists the six accounts. `install-cli.sh`
builds three schemes — breaking it would take down the nightly job.

- [ ] **Step 6: STOP. Do not run `--backfill` against the real store.**

The controller runs it with the human, capturing before/after counts. Report DONE and hand
back. The expected result, for the controller's reference:

```bash
sqlite3 "file:/Volumes/Eregion/bluex-data/default.store?mode=ro" \
  "SELECT COUNT(*) FROM ZREPLYAUTHOR;"            # expect 0 before
~/.local/bin/blueX-authors --backfill             # expect 146541 created
~/.local/bin/blueX-authors --stats                # expect authors: 146541, all unknown
```

- [ ] **Step 7: Commit**

```bash
git add BlueX/Services/Authors/AuthorBackfill.swift \
        BlueX/Services/Stats/AggregateReader.swift \
        BlueXTests/Services/Authors/AuthorBackfillTests.swift \
        cli/authors/main.swift
git commit -m "perf(authors): fold the backfill in SQL instead of paging SwiftData

The old paging re-sorted ~892k unindexed strings per page (1.9-4.8s x ~1786
pages). A live run hit 2h44m without writing a row. The GROUP BY it replaces
takes 0.50s. Writes still go through SwiftData; now batched, with progress."
```

---

### Task 7: Retrofit the account and group charts

**Files:**
- Modify: `BlueX/ViewModels/ChartsViewModel.swift`
- Modify: `BlueX/Views/Account/AccountChartsView.swift:12-46`
- Modify: `BlueX/Views/Group/GroupChartsView.swift`
- Test: `BlueXTests/ViewModels/ChartsViewModelTests.swift`

**Interfaces:**
- Consumes: `AggregateReader`, `WeekCount`
- Produces on `AggregateReader`: `func repliesPerWeek(accountPKs: [Int64]) throws -> [WeekCount]` and `func rootPostsPerWeek(accountPKs: [Int64]) throws -> [WeekCount]`
- Produces on `ChartsViewModel`: `func load(accountPKs: [Int64], reader: AggregateReader) async`

**This is the task that fixes the freezing.** `AccountChartsView.recompute()` currently
fetches replies with `rootURIs.contains($0.rootURI)` — a 29,710-element `Set` predicate
against 844,502 rows — then builds a ~874,000-element `[Post]` and runs eight `.filter`
passes per bucket, all on the MainActor, to produce twelve numbers.

- [ ] **Step 1: Write the failing test**

```swift
// BlueXTests/ViewModels/ChartsViewModelTests.swift
import XCTest
@testable import BlueX

final class ChartsViewModelTests: XCTestCase {
    func testWeeklyRepliesComeFromTheReader() async throws {
        let reader = try AggregateReader(storeURL: try StoreFixture.make())
        let vm = ChartsViewModel()
        await vm.load(accountPKs: [1], reader: reader)

        // Outlet 1 has 4 replies in the fixture: did:a x3, did:b x1.
        XCTAssertEqual(vm.weekBuckets.map(\.replyTotal).reduce(0, +), 4)
        // Compare weekStarts, not buckets: WeekBucket is Identifiable but not Equatable.
        let starts = vm.weekBuckets.map(\.weekStart)
        XCTAssertEqual(starts, starts.sorted())
    }

    func testEmptyAccountYieldsNoBuckets() async throws {
        let reader = try AggregateReader(storeURL: try StoreFixture.make())
        let vm = ChartsViewModel()
        await vm.load(accountPKs: [999], reader: reader)
        XCTAssertTrue(vm.weekBuckets.isEmpty)
    }

    func testWindowSelectsTheMostRecentBuckets() async throws {
        let reader = try AggregateReader(storeURL: try StoreFixture.make())
        let vm = ChartsViewModel()
        await vm.load(accountPKs: [1], reader: reader)
        vm.windowWeeks = 1
        XCTAssertEqual(vm.visibleBuckets.count, min(1, vm.weekBuckets.count))
        XCTAssertEqual(vm.visibleBuckets.last?.weekStart, vm.weekBuckets.last?.weekStart)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd /Volumes/Eregion/projects/bluex-v2 && xcodegen generate
xcodebuild test -project BlueX.xcodeproj -scheme BlueXTests \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:BlueXTests/ChartsViewModelTests -quiet 2>&1 | tail -20
```
Expected: FAIL — `load(accountPKs:reader:)` does not exist.

- [ ] **Step 3: Add the reader queries**

```swift
// append to BlueX/Services/Stats/AggregateReader.swift, inside the class

    /// Replies to any root post owned by the given accounts, bucketed by ISO week.
    /// Replaces a `Set.contains` predicate over 844k rows.
    func repliesPerWeek(accountPKs: [Int64]) throws -> [WeekCount] {
        guard !accountPKs.isEmpty else { return [] }
        let placeholders = accountPKs.map { _ in "?" }.joined(separator: ",")
        let stamps = try conn.query("""
            SELECT p.ZCREATEDAT
            FROM ZPOST p
            JOIN ZPOST r ON p.ZROOTURI = r.ZURI AND r.ZISROOTPOST = 1
            WHERE p.ZISROOTPOST = 0 AND r.ZACCOUNT IN (\(placeholders))
            """, accountPKs.map { .int($0) }) { Self.date(fromCoreData: $0.double(0)) }
        return Self.weekly(stamps)
    }

    func rootPostsPerWeek(accountPKs: [Int64]) throws -> [WeekCount] {
        guard !accountPKs.isEmpty else { return [] }
        let placeholders = accountPKs.map { _ in "?" }.joined(separator: ",")
        let stamps = try conn.query("""
            SELECT ZCREATEDAT FROM ZPOST
            WHERE ZISROOTPOST = 1 AND ZACCOUNT IN (\(placeholders))
            """, accountPKs.map { .int($0) }) { Self.date(fromCoreData: $0.double(0)) }
        return Self.weekly(stamps)
    }

    /// ISO-week bucketing, Monday-aligned. SQLite has no ISO-week function.
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
```

- [ ] **Step 4: Replace the aggregation in `ChartsViewModel`**

Delete `computeBuckets(from posts: [Post])` and add:

```swift
    /// Loads weekly buckets from the aggregate reader, off the main actor.
    ///
    /// Replaces `computeBuckets(from:)`, which materialised ~874k Post objects and ran
    /// eight filter passes per bucket on the MainActor to produce twelve numbers.
    @MainActor
    func load(accountPKs: [Int64], reader: AggregateReader) async {
        let buckets: [WeekBucket] = await Task.detached(priority: .userInitiated) {
            let roots = (try? reader.rootPostsPerWeek(accountPKs: accountPKs)) ?? []
            let replies = (try? reader.repliesPerWeek(accountPKs: accountPKs)) ?? []

            var byWeek: [Date: (root: Int, reply: Int)] = [:]
            for w in roots { byWeek[w.weekStart, default: (0, 0)].root += w.count }
            for w in replies { byWeek[w.weekStart, default: (0, 0)].reply += w.count }

            return byWeek.map { week, counts in
                // Speech-class and sentiment fields stay zero: ZANNOTATION is empty,
                // so there is nothing to classify by yet.
                WeekBucket(
                    id: week, weekStart: week,
                    hateCount: 0, counterCount: 0, neutralCount: 0,
                    pendingCount: counts.root,
                    replyHateCount: 0, replyCounterCount: 0, replyNeutralCount: 0,
                    replyPendingCount: counts.reply,
                    avgSentiment: 0, sentimentSampleCount: 0
                )
            }.sorted { $0.weekStart < $1.weekStart }
        }.value
        self.weekBuckets = buckets
    }
```

In `AccountChartsView`, delete the `@Query private var posts`, the `init(account:)` query
construction, `recompute()`, and `scheduleRecompute()` (`:12-46`). Replace with a `.task`
that resolves the account's `Z_PK` and calls `viewModel.load`. Apply the same change to
`GroupChartsView`, passing every member account's `Z_PK`.

- [ ] **Step 5: Run the tests**

```bash
cd /Volumes/Eregion/projects/bluex-v2 && xcodegen generate
xcodebuild test -project BlueX.xcodeproj -scheme BlueXTests \
  -destination 'platform=macOS,arch=arm64' -quiet 2>&1 | tail -20
```
Expected: full suite green.

- [ ] **Step 6: Verify the freeze is gone, by hand**

Launch the app, select the account holding 29,710 roots and 844,502 replies, and confirm
the charts appear without the UI locking. Record roughly how long they take. **If it still
stalls, report that rather than declaring the task done** — the whole point of this task is
that specific symptom.

- [ ] **Step 7: Commit**

```bash
git add BlueX/ViewModels/ChartsViewModel.swift BlueX/Views/Account/AccountChartsView.swift \
        BlueX/Views/Group/GroupChartsView.swift BlueX/Services/Stats/AggregateReader.swift \
        BlueXTests/ViewModels/ChartsViewModelTests.swift
git commit -m "perf(charts): aggregate weekly buckets in SQL, off the main actor

recompute() fetched replies with a 29,710-element Set predicate against
844,502 unindexed rows, built a ~874k-element array, and ran eight filter
passes per bucket on the MainActor — to produce twelve numbers."
```

---

### Task 8: Decimation

**Files:**
- Create: `BlueX/Services/Stats/Decimator.swift`
- Test: `BlueXTests/Services/Stats/DecimatorTests.swift`

**Interfaces:**
- Consumes: `WeekCount`
- Produces: `enum Decimator { static func downsample<T>(_ items: [T], to maxPoints: Int) -> [T] }`

- [ ] **Step 1: Write the failing tests**

```swift
// BlueXTests/Services/Stats/DecimatorTests.swift
import XCTest
@testable import BlueX

final class DecimatorTests: XCTestCase {
    func testShortSeriesIsUntouched() {
        let xs = Array(0..<10)
        XCTAssertEqual(Decimator.downsample(xs, to: 100), xs)
    }

    func testLongSeriesIsCapped() {
        let xs = Array(0..<1000)
        XCTAssertLessThanOrEqual(Decimator.downsample(xs, to: 50).count, 50)
    }

    /// Dropping either end would move the chart's date range, which is a lie about the
    /// data rather than a rendering shortcut.
    func testEndpointsArePreserved() {
        let xs = Array(0..<1000)
        let out = Decimator.downsample(xs, to: 50)
        XCTAssertEqual(out.first, 0)
        XCTAssertEqual(out.last, 999)
    }

    func testOrderIsPreserved() {
        let xs = Array(0..<1000)
        let out = Decimator.downsample(xs, to: 37)
        XCTAssertEqual(out, out.sorted())
    }

    func testDegenerateInputs() {
        XCTAssertTrue(Decimator.downsample([Int](), to: 10).isEmpty)
        XCTAssertEqual(Decimator.downsample([5], to: 10), [5])
        XCTAssertEqual(Decimator.downsample([1, 2, 3], to: 1), [1, 2, 3],
                       "a cap below 2 cannot preserve both endpoints, so pass through")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
cd /Volumes/Eregion/projects/bluex-v2 && xcodegen generate
xcodebuild test -project BlueX.xcodeproj -scheme BlueXTests \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:BlueXTests/DecimatorTests -quiet 2>&1 | tail -20
```
Expected: FAIL — `cannot find 'Decimator' in scope`.

- [ ] **Step 3: Implement**

```swift
// BlueX/Services/Stats/Decimator.swift
import Foundation

/// Caps how many points a chart draws.
///
/// This is *not* what fixed the chart freezing — that was upstream aggregation. Weekly
/// account buckets are 12–450 points and are left alone. Decimation is for the series
/// that genuinely get large: per-author timelines across 2018→2026 and population
/// distributions.
enum Decimator {
    /// Evenly samples `items` down to at most `maxPoints`, always keeping the first and
    /// last elements so the visible range still matches the data's true range.
    static func downsample<T>(_ items: [T], to maxPoints: Int) -> [T] {
        guard maxPoints >= 2, items.count > maxPoints else { return items }

        var out: [T] = [items[0]]
        // Distribute the interior samples across the gap between the fixed endpoints.
        let interior = maxPoints - 2
        if interior > 0 {
            let step = Double(items.count - 2) / Double(interior + 1)
            for i in 1...interior {
                let index = Int((Double(i) * step).rounded()) 
                out.append(items[min(max(index, 1), items.count - 2)])
            }
        }
        out.append(items[items.count - 1])
        return out
    }
}
```

- [ ] **Step 4: Run the tests**

```bash
cd /Volumes/Eregion/projects/bluex-v2 && xcodegen generate
xcodebuild test -project BlueX.xcodeproj -scheme BlueXTests \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:BlueXTests/DecimatorTests -quiet 2>&1 | tail -20
```
Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add BlueX/Services/Stats/Decimator.swift BlueXTests/Services/Stats/DecimatorTests.swift
git commit -m "feat(stats): endpoint-preserving series decimation

Endpoints are always kept: dropping either end would silently move the
chart's date range."
```

---

### Task 9: Authors view model

**Files:**
- Create: `BlueX/ViewModels/AuthorStatsViewModel.swift`
- Test: `BlueXTests/ViewModels/AuthorStatsViewModelTests.swift`

**Interfaces:**
- Consumes: `AggregateReader`, `AuthorSummary`, `PopulationStats`, `AuthorSort`, `WeekCount`, `OutletCount`, `Decimator`
- Produces: `@Observable final class AuthorStatsViewModel` with
  - `var population: PopulationStats`, `var authors: [AuthorSummary]`, `var totalMatching: Int`
  - `var sort: AuthorSort`, `var displayCap: Int`, `var minReplies: Int`, `var outletFilter: Int64?`
  - `var selected: AuthorSummary?`, `var selectedWeeks: [WeekCount]`, `var selectedOutlets: [OutletCount]`
  - `var loadState: LoadState` where `enum LoadState { case idle, loading, loaded, failed(String) }`
  - `func loadPopulation(reader:) async`, `func loadAuthors(reader:) async`, `func select(_ did: String?, reader:) async`

- [ ] **Step 1: Write the failing tests**

```swift
// BlueXTests/ViewModels/AuthorStatsViewModelTests.swift
import XCTest
@testable import BlueX

final class AuthorStatsViewModelTests: XCTestCase {
    private func makeReader() throws -> AggregateReader {
        try AggregateReader(storeURL: try StoreFixture.make())
    }

    func testLoadsPopulation() async throws {
        let vm = AuthorStatsViewModel()
        await vm.loadPopulation(reader: try makeReader())
        XCTAssertEqual(vm.population.totalAuthors, 3)
        if case .loaded = vm.loadState {} else { XCTFail("expected .loaded") }
    }

    func testLoadsAuthorsRespectingSortAndCap() async throws {
        let vm = AuthorStatsViewModel()
        vm.sort = .replyCount
        vm.displayCap = 2
        await vm.loadAuthors(reader: try makeReader())
        XCTAssertEqual(vm.authors.map(\.did), ["did:a", "did:b"])
    }

    /// A cap that hides how much it hides would misrepresent coverage.
    func testTotalMatchingReportsBeyondTheCap() async throws {
        let vm = AuthorStatsViewModel()
        vm.displayCap = 1
        await vm.loadAuthors(reader: try makeReader())
        XCTAssertEqual(vm.authors.count, 1)
        XCTAssertEqual(vm.totalMatching, 3)
    }

    func testMinRepliesFilterNarrowsBothListAndTotal() async throws {
        let vm = AuthorStatsViewModel()
        vm.minReplies = 2
        await vm.loadAuthors(reader: try makeReader())
        XCTAssertEqual(vm.totalMatching, 2)
    }

    func testSelectLoadsPerAuthorDetail() async throws {
        let vm = AuthorStatsViewModel()
        await vm.select("did:a", reader: try makeReader())
        XCTAssertEqual(vm.selected?.replyCount, 3)
        XCTAssertEqual(vm.selectedWeeks.map(\.count).reduce(0, +), 3)
        XCTAssertEqual(vm.selectedOutlets.count, 1)
    }

    func testDeselectClearsDetail() async throws {
        let vm = AuthorStatsViewModel()
        let reader = try makeReader()
        await vm.select("did:a", reader: reader)
        await vm.select(nil, reader: reader)
        XCTAssertNil(vm.selected)
        XCTAssertTrue(vm.selectedWeeks.isEmpty)
    }

    /// Rapid selection must not leave a slower earlier load overwriting a newer one.
    /// Without cancellation, clicking through a list races detail loads against each
    /// other and the pane can settle on the wrong author.
    func testRapidSelectionSettlesOnTheLastRequest() async throws {
        let vm = AuthorStatsViewModel()
        let reader = try makeReader()
        async let first: Void = vm.select("did:a", reader: reader)
        async let second: Void = vm.select("did:c", reader: reader)
        _ = await (first, second)
        XCTAssertEqual(vm.selected?.did, "did:c")
        XCTAssertEqual(vm.selectedWeeks.map(\.count).reduce(0, +), 1,
                       "detail must belong to did:c, which has one reply")
    }

    /// An unreadable store must not look like an empty one — "no store" and "no authors"
    /// are different facts, and conflating them hides an unmounted Eregion volume.
    func testUnreadableStoreSurfacesFailure() async throws {
        let vm = AuthorStatsViewModel()
        let missing = URL(fileURLWithPath: "/nonexistent/none.store")
        await vm.loadPopulation(readerFactory: { try AggregateReader(storeURL: missing) })
        if case .failed = vm.loadState {} else {
            XCTFail("expected .failed, got \(vm.loadState)")
        }
        XCTAssertEqual(vm.population.totalAuthors, 0)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
cd /Volumes/Eregion/projects/bluex-v2 && xcodegen generate
xcodebuild test -project BlueX.xcodeproj -scheme BlueXTests \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:BlueXTests/AuthorStatsViewModelTests -quiet 2>&1 | tail -20
```
Expected: FAIL — `cannot find 'AuthorStatsViewModel' in scope`.

- [ ] **Step 3: Implement**

```swift
// BlueX/ViewModels/AuthorStatsViewModel.swift
import Foundation
import Observation

@Observable
final class AuthorStatsViewModel {
    enum LoadState {
        case idle, loading, loaded
        case failed(String)
    }

    var population: PopulationStats = .empty
    var authors: [AuthorSummary] = []
    /// How many authors match the current filters, regardless of `displayCap`.
    var totalMatching: Int = 0

    var sort: AuthorSort = .replyCount
    var displayCap: Int = 500
    var minReplies: Int = 1
    var outletFilter: Int64? = nil

    var selected: AuthorSummary? = nil
    var selectedWeeks: [WeekCount] = []
    var selectedOutlets: [OutletCount] = []

    var loadState: LoadState = .idle

    func loadPopulation(reader: AggregateReader) async {
        await loadPopulation(readerFactory: { reader })
    }

    /// The factory form exists so a failure to *open* the store is testable, not just a
    /// failure to query it.
    func loadPopulation(readerFactory: @escaping () throws -> AggregateReader) async {
        loadState = .loading
        do {
            let stats = try await Task.detached(priority: .userInitiated) {
                let reader = try readerFactory()
                try reader.verifySchema()
                return try reader.populationStats()
            }.value
            population = stats
            loadState = .loaded
        } catch {
            population = .empty
            loadState = .failed(String(describing: error))
        }
    }

    func loadAuthors(reader: AggregateReader) async {
        let sort = self.sort, cap = self.displayCap
        let minReplies = self.minReplies, outlet = self.outletFilter
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let rows = try reader.authors(sort: sort, limit: cap,
                                              minReplies: minReplies, outletPK: outlet)
                let total = try reader.authorCount(minReplies: minReplies, outletPK: outlet)
                return (rows, total)
            }.value
            authors = result.0
            totalMatching = result.1
            loadState = .loaded
        } catch {
            authors = []
            totalMatching = 0
            loadState = .failed(String(describing: error))
        }
    }

    /// In-flight detail load, cancelled when a new selection arrives so a slow earlier
    /// query cannot land after a newer one and leave the pane showing the wrong author.
    @ObservationIgnored private var detailTask: Task<Void, Never>?

    func select(_ did: String?, reader: AggregateReader) async {
        detailTask?.cancel()
        guard let did else {
            selected = nil; selectedWeeks = []; selectedOutlets = []
            return
        }
        let task = Task { @MainActor in
            do {
                let detail = try await Task.detached(priority: .userInitiated) {
                    (try reader.authorDetail(did: did),
                     try reader.repliesPerWeek(did: did),
                     try reader.outletBreakdown(did: did))
                }.value
                // A cancelled load must publish nothing — the newer selection owns state.
                guard !Task.isCancelled else { return }
                selected = detail.0
                selectedWeeks = Decimator.downsample(detail.1, to: 400)
                selectedOutlets = detail.2
            } catch {
                guard !Task.isCancelled else { return }
                loadState = .failed(String(describing: error))
            }
        }
        detailTask = task
        await task.value
    }
}
```

This needs one more reader method — a filtered count, so `totalMatching` reflects the same
filters as the list:

```swift
// append to BlueX/Services/Stats/AggregateReader.swift, inside the class

    /// Authors matching the same filters the list uses, ignoring any display cap.
    func authorCount(minReplies: Int, outletPK: Int64?) throws -> Int {
        var bind: [SQLValue] = []
        var outletFilter = ""
        if let outletPK {
            outletFilter = "AND r.ZACCOUNT = ?"
            bind.append(.int(outletPK))
        }
        bind.append(.int(Int64(minReplies)))
        let sql = """
        SELECT COUNT(*) FROM (
          SELECT p.ZAUTHORDID
          FROM ZPOST p
          JOIN ZPOST r ON p.ZROOTURI = r.ZURI AND r.ZISROOTPOST = 1
          WHERE p.ZISROOTPOST = 0 \(outletFilter)
          GROUP BY p.ZAUTHORDID
          HAVING COUNT(*) >= ?
        )
        """
        return try conn.query(sql, bind) { Int($0.int(0)) }.first ?? 0
    }
```

- [ ] **Step 4: Run the tests**

```bash
cd /Volumes/Eregion/projects/bluex-v2 && xcodegen generate
xcodebuild test -project BlueX.xcodeproj -scheme BlueXTests \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:BlueXTests/AuthorStatsViewModelTests -quiet 2>&1 | tail -20
```
Expected: 8 tests pass.

- [ ] **Step 5: Commit**

```bash
git add BlueX/ViewModels/AuthorStatsViewModel.swift \
        BlueX/Services/Stats/AggregateReader.swift \
        BlueXTests/ViewModels/AuthorStatsViewModelTests.swift
git commit -m "feat(authors): stats view model

totalMatching is tracked separately from the display cap so the UI can state
what it is not showing. A failure to open the store surfaces as .failed, never
as an empty population."
```

---

### Task 10: Authors views and navigation

**Files:**
- Create: `BlueX/Views/Authors/AuthorsOverviewView.swift`
- Create: `BlueX/Views/Authors/AuthorListView.swift`
- Create: `BlueX/Views/Authors/AuthorDetailView.swift`
- Modify: `BlueX/Views/RootView.swift:6-12` (`SidebarItem`), `:67-107` (both columns)
- Modify: `BlueX/Views/Sidebar/SidebarView.swift:41-49`

**Interfaces:**
- Consumes: `AuthorStatsViewModel`, `AuthorSummary`, `PopulationStats`, `HistogramBin`, `OutletCount`, `AuthorSort`, `Color.appBackground` and siblings from `BlueX/Views/BlueXColors.swift`
- Produces: `SidebarItem.authors` case

- [ ] **Step 1: Add the sidebar case and route it**

In `RootView.swift`, extend the enum:

```swift
enum SidebarItem: Hashable {
    case group(AccountGroup)
    case account(TrackedAccount)
    case post(Post)
    case authors
    case queue
    case settings
}
```

In `contentColumn`, add `case .authors: AuthorListView(viewModel: authorsVM)` and move
`.authors` out of the `case .queue, .settings, nil:` group. In `detailColumn`, add
`case .authors: AuthorsOverviewView(viewModel: authorsVM)`. Hold the view model as
`@State private var authorsVM = AuthorStatsViewModel()` beside `sidebarVM`.

In `SidebarView.swift`, add above the queue link:

```swift
                NavigationLink(value: SidebarItem.authors) {
                    Label("Reply Authors", systemImage: "person.3")
                        .foregroundStyle(Color.primaryText)
                }
```

- [ ] **Step 2: Build the population overview**

`AuthorsOverviewView` shows, in a `ScrollView`: summary chips (total authors, total
replies, median replies per author, active in last 30 days); a `BarMark` histogram over
`population.bins`; a bar chart of `population.outlets` by author count; and the status
breakdown.

Three things it must state plainly rather than imply:

```swift
// Cross-outlet figures are confounded while one outlet dominates the corpus.
Text("Outlet comparison is confounded: the corpus is dominated by a single outlet "
     + "until the remaining accounts are fully scraped.")
    .font(.caption)
    .foregroundStyle(Color.mutedText)

// Author counts per outlet sum above the population, and that is the point.
Text("Authors are counted once per outlet they reply to, so these sum above "
     + "\(population.totalAuthors).")
    .font(.caption)
    .foregroundStyle(Color.mutedText)

// The moderation panel is absent, not broken.
Text("Account status requires the profile probe, which has not run yet.")
    .font(.caption)
    .foregroundStyle(Color.mutedText)
```

When `loadState` is `.failed`, show the message — never an empty chart. An unmounted
Eregion volume must not read as "no authors".

- [ ] **Step 3: Build the capped author list**

`AuthorListView` shows a `Table` over `viewModel.authors` with columns: DID (or handle when
non-nil), replies, first seen, last seen, span days, outlets. A toolbar carries the sort
picker (`AuthorSort.allCases`), a minimum-replies stepper, an outlet picker, and a cap
picker (100 / 500 / 2000).

The cap must be visible:

```swift
Text("Showing \(viewModel.authors.count) of \(viewModel.totalMatching) matching authors")
    .font(.caption)
    .foregroundStyle(Color.mutedText)
```

Selecting a row calls `await viewModel.select(row.did, reader: reader)`.

- [ ] **Step 4: Build the author detail**

`AuthorDetailView` shows the DID, handle when known, status; chips for replies, first
seen, last seen, span, outlets; a `LineMark` chart over `viewModel.selectedWeeks`; and the
outlet breakdown. Where handle is nil, show the DID and a note that the handle needs the
probe — do not render an empty field.

- [ ] **Step 5: Build and run the full suite**

```bash
cd /Volumes/Eregion/projects/bluex-v2 && xcodegen generate
xcodebuild build -project BlueX.xcodeproj -scheme BlueX \
  -destination 'platform=macOS,arch=arm64' -quiet 2>&1 | tail -10
xcodebuild test -project BlueX.xcodeproj -scheme BlueXTests \
  -destination 'platform=macOS,arch=arm64' -quiet 2>&1 | tail -20
```
Expected: BUILD SUCCEEDED, full suite green.

- [ ] **Step 6: Verify by hand against the real store**

Launch the app, open "Reply Authors", and confirm: the population loads without freezing;
the histogram's bins sum to the total; the list respects sort, filters and cap, and states
what it is not showing; selecting an author loads their timeline. Record load times.

Before the backfill has run, `statusCounts` is empty and the view must say so rather than
showing a zeroed chart.

- [ ] **Step 7: Commit**

```bash
git add BlueX/Views/Authors/ BlueX/Views/RootView.swift \
        BlueX/Views/Sidebar/SidebarView.swift project.yml BlueX.xcodeproj
git commit -m "feat(authors): reply-author dashboard

Population overview, capped sortable list, per-author detail. The list states
how many authors it is not showing; confounded and not-yet-collected figures
are labelled rather than presented as findings."
```

---

## Execution order

1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10.

Tasks 4 and 5 both extend `AggregateReader` and must not run concurrently. Task 6 unblocks
the backfill the human has been waiting on; Task 7 fixes the freezing. Tasks 8–10 are the
new dashboard and depend on everything before them.
