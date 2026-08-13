// BlueX/Data/IndexReasserter.swift
import Foundation
import SQLite3

/// Re-asserts every index in `StoreIndexPlan.all` on the store at `storeURL`, from a
/// short-lived write connection opened and closed within this one call.
///
/// **Why this exists.** A lightweight SwiftData migration was measured to drop every
/// hand-made index while leaving `PRAGMA quick_check` reporting `ok` — silently, with
/// nothing else to report it. `CREATE INDEX IF NOT EXISTS` against an already-indexed
/// table is a `sqlite_master` lookup, not a rebuild, so calling this on every store
/// open costs nothing in the normal case and self-heals exactly when a migration has
/// dropped them. See the *Indexes* section of
/// `docs/superpowers/specs/2026-08-07-bluex-authors-dashboard-design.md`.
///
/// **Must never fail the caller.** `BlueXStore.openContainer()` calls this after the
/// `ModelContainer` is open, and every process that touches the store — the app and
/// all three CLIs — goes through `openContainer()`. A corpus scrape or the label
/// harvester frequently holds the store open at the same time. If the write
/// connection cannot be acquired at all (the volume went read-only, another process
/// holds an incompatible lock) or an individual `CREATE INDEX` hits `SQLITE_BUSY`
/// even after a busy-timeout wait, this logs and moves on — it never throws, so a
/// concurrent writer holding the store can never prevent the app or a CLI from
/// starting.
enum IndexReasserter {
    enum Outcome: Equatable {
        /// The write connection was acquired. `created` lists indexes from
        /// `StoreIndexPlan.all` that did not already exist in `sqlite_master` before
        /// this call — a non-empty list means a migration (or a fresh store) had
        /// dropped or never had them, and this call just repaired it. That event is
        /// also logged, since it's exactly what a human needs to see.
        case reasserted(created: [String])
        /// The write connection could not be acquired, or every `CREATE INDEX`
        /// attempt failed. `reason` is the sqlite error message, already logged.
        case unavailable(reason: String)
    }

    @discardableResult
    static func reassert(storeURL: URL) -> Outcome {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(storeURL.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let db = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) }
                ?? "sqlite3_open_v2 returned code \(rc)"
            if let handle { sqlite3_close(handle) }
            log("could not open a write connection to \(storeURL.path): \(message) " +
                "— continuing without re-asserting indexes")
            return .unavailable(reason: message)
        }
        defer { sqlite3_close(db) }

        // A concurrent writer (a corpus scrape, the label harvester) may hold the
        // store open. Give SQLite a few seconds to acquire the lock rather than
        // failing immediately on SQLITE_BUSY.
        sqlite3_busy_timeout(db, 5_000)

        let existing = existingIndexNames(db)
        var created: [String] = []
        // Each statement is independent: one failing (e.g. a transient SQLITE_BUSY
        // that outlasts the busy-timeout) must not stop the rest from being tried.
        for index in StoreIndexPlan.all {
            var errMsg: UnsafeMutablePointer<CChar>?
            let execRC = sqlite3_exec(db, index.createSQL, nil, nil, &errMsg)
            if execRC != SQLITE_OK {
                let message = errMsg.map { String(cString: $0) } ?? "code \(execRC)"
                if let errMsg { sqlite3_free(errMsg) }
                log("failed to assert \(index.name): \(message) — continuing")
                continue
            }
            if !existing.contains(index.name) {
                created.append(index.name)
            }
        }

        if !created.isEmpty {
            // The event a human needs to see: something dropped (or this store never
            // had) these indexes, and re-assertion just repaired it.
            log("created \(created.count) index(es) that were missing: " +
                created.joined(separator: ", "))
        }

        return .reasserted(created: created)
    }

    private static func existingIndexNames(_ db: OpaquePointer) -> Set<String> {
        var stmt: OpaquePointer?
        let sql = "SELECT name FROM sqlite_master WHERE type='index'"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return []
        }
        defer { sqlite3_finalize(stmt) }
        var names: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) {
                names.insert(String(cString: c))
            }
        }
        return names
    }

    private static func log(_ message: String) {
        print("IndexReasserter: \(message)")
    }
}
