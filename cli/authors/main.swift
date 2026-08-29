// cli/authors/main.swift — blueX-authors
//
// Tracks the people who reply to tracked accounts, so platform moderation becomes
// measurable: takedown rate, enforcement latency, enforcement coverage.
//
//   blueX-authors --backfill    — create a ReplyAuthor per distinct reply-author DID
//   blueX-authors --stats       — print status counts
//
// A --probe flag is coming (it needs the profile API and probe logic, not yet written).
// Needs NO credentials: the probe will use the unauthenticated public API, and the
// backfill is purely local.

import Foundation
import SwiftData

struct AuthorsArgs {
    var backfill = false
    var stats = false
    var help = false

    static func parse(_ argv: [String]) -> AuthorsArgs {
        var a = AuthorsArgs(); var i = 1
        while i < argv.count {
            switch argv[i] {
            case "--backfill":   a.backfill = true
            case "--stats":      a.stats = true
            case "-h", "--help": a.help = true
            default: fail("blueX-authors", "unknown argument: \(argv[i]). Run --help.")
            }
            i += 1
        }
        return a
    }
}

let usage = """
usage: blueX-authors [--backfill] [--stats]

  --backfill          Create a ReplyAuthor per distinct reply-author DID from the
                      posts already in the store. Idempotent; re-running extends
                      each author's first/last-seen range rather than duplicating.
  --stats             Print author counts by status and exit.
  --help, -h          This help.

Reads and writes the BlueX store at /Volumes/Eregion/bluex-data/default.store.
The backfill is local only — no network, no credentials.
"""

func runCLI() async {
    let args = AuthorsArgs.parse(CommandLine.arguments)
    if args.help || (!args.backfill && !args.stats) { print(usage); return }

    let container: ModelContainer
    do { container = try BlueXStore.openContainer() }
    catch { fail("blueX-authors", "failed to open store: \(error.localizedDescription)") }

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

    if args.stats {
        let ctx = ModelContext(container)
        do {
            let authors = try ctx.fetch(FetchDescriptor<ReplyAuthor>())
            var counts: [String: Int] = [:]
            for a in authors { counts[a.currentStatus, default: 0] += 1 }
            print("authors: \(authors.count)")
            for k in counts.keys.sorted() { print("  \(k): \(counts[k]!)") }
            let probed = authors.filter { $0.lastProbedAt != nil }.count
            print("  (probed at least once: \(probed))")
        } catch { fail("blueX-authors", "stats failed: \(error)") }
    }
}

await runCLI()
