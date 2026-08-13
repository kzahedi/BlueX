// BlueX/Data/StoreIndexPlan.swift
import Foundation

/// The hand-built SQLite indexes this app depends on for performance, on top of
/// `ZPOST_ZACCOUNT_INDEX`, which Core Data creates and maintains itself and is
/// therefore not listed here.
///
/// **Single source of truth — do not duplicate this list anywhere.** `IndexReasserter`
/// (the writer, which creates these on every store open) and `AggregateReader` (the
/// read-only checker, which reports whether they're present) both read `all` from
/// here. Two divergent lists would let the checker report healthy while the reader it
/// is checking runs unindexed — exactly the failure this whole mechanism exists to
/// prevent.
///
/// See the *Indexes* section of
/// `docs/superpowers/specs/2026-08-07-bluex-authors-dashboard-design.md` for why these
/// exist and why a lightweight SwiftData migration was measured to drop all of them
/// silently while `PRAGMA quick_check` still reported `ok`.
enum StoreIndexPlan {
    struct Index: Equatable {
        let name: String
        let table: String
        let columns: [String]

        /// `CREATE INDEX IF NOT EXISTS` against an already-indexed table is a
        /// `sqlite_master` lookup, not a rebuild — free in the normal case, and
        /// exactly what self-heals a migration that dropped the index.
        var createSQL: String {
            "CREATE INDEX IF NOT EXISTS \(name) ON \(table)(\(columns.joined(separator: ", ")))"
        }
    }

    /// Order is for log/diagnostic readability only — each statement is independent
    /// and idempotent.
    static let all: [Index] = [
        // Thread open: full scan -> 0.009s (measured 2026-08-07).
        Index(name: "IDX_ZPOST_ZROOTURI", table: "ZPOST", columns: ["ZROOTURI"]),
        // Outlet join: 6.35s -> 1.38s.
        Index(name: "IDX_ZPOST_ZURI", table: "ZPOST", columns: ["ZURI"]),
        // Author grouping.
        Index(name: "IDX_ZPOST_ZAUTHORDID", table: "ZPOST", columns: ["ZAUTHORDID"]),
        // Authors list: 27.8s -> 0.16s.
        Index(name: "IDX_ZPOST_AUTHOR_COVERING", table: "ZPOST",
              columns: ["ZAUTHORDID", "ZISROOTPOST", "ZCREATEDAT"]),
    ]

    static var names: [String] { all.map(\.name) }
}
