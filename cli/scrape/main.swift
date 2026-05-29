// cli/scrape/main.swift — blueX-scrape
//
// Standalone CLI that runs the same depth-first scrape as the GUI, against the
// same SwiftData store. Shares BlueskyAPIClient, FeedScraper, ThreadScraper,
// RescrapingPolicy and the @Model schema with the app target via shared source
// files in project.yml — no logic is duplicated.
//
//   blueX-scrape                          — scrape every active account
//   blueX-scrape --handle nytimes.com     — scrape only one account
//   blueX-scrape --pace gentle            — burst | steady | gentle
//   blueX-scrape --limit 200              — max NEW posts per account this run
//   blueX-scrape --max-window-days 30     — reply-tree refresh window (default 14)
//   blueX-scrape --list-accounts          — print active accounts + exit
//   blueX-scrape --help

import Foundation
import SwiftData

// MARK: - Arguments

struct CLIArgs {
    var handle: String?
    var pace: LLMPace = .steady             // reuse the same pace enum the LLM CLI uses
    var limit: Int?
    var maxWindowDays: Int = 14
    var listAccounts = false
    var help = false

    static func parse(_ argv: [String]) -> CLIArgs {
        var a = CLIArgs()
        var i = 1
        while i < argv.count {
            let arg = argv[i]
            switch arg {
            case "-h", "--help":          a.help = true
            case "--list-accounts":       a.listAccounts = true
            case "--handle":
                i += 1; if i < argv.count { a.handle = argv[i] }
            case "--pace":
                i += 1
                if i < argv.count, let p = LLMPace(rawValue: argv[i]) { a.pace = p }
                else if i < argv.count { fail("invalid --pace value '\(argv[i])'. Valid: burst, steady, gentle") }
            case "--limit":
                i += 1
                if i < argv.count, let n = Int(argv[i]), n > 0 { a.limit = n }
                else if i < argv.count { fail("invalid --limit value '\(argv[i])'") }
            case "--max-window-days":
                i += 1
                if i < argv.count, let n = Int(argv[i]), n > 0 { a.maxWindowDays = n }
                else if i < argv.count { fail("invalid --max-window-days value '\(argv[i])'") }
            default:
                fail("unknown argument: \(arg). Run --help for usage.")
            }
            i += 1
        }
        return a
    }
}

let usage = """
usage: blueX-scrape [options]

  --handle <h>           Scrape only one account (its handle, e.g. nytimes.com).
                         Without this flag, every active account is scraped.
  --pace <p>             burst   — no pause between thread requests
                         steady  — 0.5 s pause (default)
                         gentle  — 2 s pause; recommended for unattended runs
  --limit <n>            Stop after N NEW posts per account (default: no limit).
                         Useful for testing — full history is huge.
  --max-window-days <n>  Reply-tree refresh window (default 14 days). A post's
                         reply tree is kept up to date while the previous scrape
                         was within this window of the post's createdAt; after,
                         the tree is frozen.
  --list-accounts        Print active accounts and exit.
  --help, -h             This help.

Reads + writes the BlueX SwiftData store at
  ~/Library/Application Support/BlueX/default.store

Credentials come from the macOS Keychain item written by the GUI's
Settings → Credentials. If none are present, run the GUI once to save them.

Ctrl-C stops at the next post boundary; the partial batch is already saved
(the depth-first scraper persists each new post + its thread tree immediately).
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("blueX-scrape: \(message)\n".utf8))
    exit(2)
}

// MARK: - Store

func openStore() throws -> ModelContainer {
    let url = URL.applicationSupportDirectory
        .appendingPathComponent("BlueX", isDirectory: true)
        .appendingPathComponent("default.store", isDirectory: false)
    let schema = Schema([
        TrackedAccount.self,
        AccountGroup.self,
        Post.self,
        Annotation.self,
        AccountSnapshot.self,
        ScrapeLog.self,
        ModelConfig.self,
        CoordinatorState.self,
    ])
    let config = ModelConfiguration(schema: schema, url: url)
    return try ModelContainer(for: schema, configurations: config)
}

// MARK: - Cancel

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return v }
    func set() { lock.lock(); v = true; lock.unlock() }
}

/// Thrown by the feed-scraper callback to break out cleanly when --limit is hit.
struct LimitReached: Error {}

// MARK: - Progress bar (single updating line)

func writeProgress(_ line: String) {
    let out = "\r\u{1B}[K" + line
    FileHandle.standardOutput.write(Data(out.utf8))
}

func writeFinalLine(_ line: String) {
    let out = "\r\u{1B}[K" + line + "\n"
    FileHandle.standardOutput.write(Data(out.utf8))
}

func formatDuration(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds.rounded()))
    if s >= 3600 { return "\(s/3600)h \((s % 3600)/60)m" }
    if s >= 60   { return "\(s/60)m \(s % 60)s" }
    return "\(s)s"
}

// MARK: - Main

func runCLI() async {
    let args = CLIArgs.parse(CommandLine.arguments)
    if args.help { print(usage); return }

    let container: ModelContainer
    do { container = try openStore() }
    catch { fail("failed to open store: \(error)") }
    let context = ModelContext(container)

    // ---- list-accounts mode
    if args.listAccounts {
        let active = try? context.fetch(FetchDescriptor<TrackedAccount>(
            predicate: #Predicate { $0.isActive == true },
            sortBy: [SortDescriptor(\.handle)]
        ))
        for a in active ?? [] {
            print("  \(a.handle.padding(toLength: 30, withPad: " ", startingAt: 0))  \(a.did)")
        }
        return
    }

    // ---- credentials
    guard let creds = KeychainCredentials.load() else {
        fail("no Bluesky credentials in the Keychain. Open BlueX → Settings → Credentials, save an app password, then re-run.")
    }
    let api = BlueskyAPIClient()
    FileHandle.standardOutput.write(Data("authenticating as @\(creds.handle)…\n".utf8))
    let authResult = await api.createSession(handle: creds.handle, password: creds.password)
    guard case .success(let session) = authResult else {
        if case .failure(let err) = authResult { fail("authentication failed: \(err)") }
        fail("authentication failed")
    }
    let token = session.accessJwt

    // ---- accounts
    let allActive: [TrackedAccount]
    do {
        allActive = try context.fetch(FetchDescriptor<TrackedAccount>(
            predicate: #Predicate { $0.isActive == true },
            sortBy: [SortDescriptor(\.handle)]
        ))
    } catch { fail("failed to fetch accounts: \(error)") }

    let accounts: [TrackedAccount]
    if let h = args.handle {
        let matched = allActive.filter { $0.handle == h || $0.did == h }
        if matched.isEmpty { fail("no active account matches handle/DID '\(h)'. Run --list-accounts.") }
        accounts = matched
    } else {
        accounts = allActive
    }
    if accounts.isEmpty { fail("no active accounts to scrape.") }

    // ---- cancel handler
    let cancel = CancelFlag()
    let sigSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigSrc.setEventHandler {
        cancel.set()
        FileHandle.standardError.write(Data("\n\nstopping after current post — please wait…\n".utf8))
    }
    sigSrc.resume()
    signal(SIGINT, SIG_IGN)

    let feedScraper = FeedScraper(api: api, context: context)
    let threadScraper = ThreadScraper(api: api, context: context)
    let window = TimeInterval(args.maxWindowDays) * 86400

    print("Scraping \(accounts.count) account\(accounts.count == 1 ? "" : "s") · pace \(args.pace.rawValue) · \(args.maxWindowDays)-day reply window\n")

    let runStart = Date()
    var grandNewPosts = 0
    var grandNewReplies = 0
    var grandRefreshed = 0

    for (idx, account) in accounts.enumerated() {
        if cancel.isSet { break }

        let accountStart = Date()
        var accountNewPosts = 0
        var accountNewReplies = 0
        var accountRefreshed = 0
        let banner = "\(account.handle) (\(idx + 1)/\(accounts.count))"

        writeProgress("\(banner) · refreshing existing reply trees…")

        // ---- Phase 1: refresh reply trees of already-stored posts still within the window.
        do {
            accountRefreshed = try await threadScraper.scrapeAllThreads(
                for: account, token: token, window: window
            )
        } catch {
            writeFinalLine("⚠ \(account.handle)  refresh failed: \(error.localizedDescription)")
        }

        // ---- Phase 2: feed scrape, depth-first per post.
        do {
            let pace = args.pace
            let limit = args.limit
            _ = try await feedScraper.scrape(account: account, token: token) { post in
                if cancel.isSet { throw CancellationError() }
                let replies = try await threadScraper.scrapeThreadIfDue(
                    post, token: token, window: window
                )
                accountNewReplies += replies
                accountNewPosts += 1

                let elapsed = Date().timeIntervalSince(accountStart)
                writeProgress(
                    "\(banner) · \(accountNewPosts) new posts · \(accountNewReplies + accountRefreshed) replies · \(formatDuration(elapsed))"
                )

                if let lim = limit, accountNewPosts >= lim {
                    throw LimitReached()
                }
                if pace.baseDelayNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: pace.baseDelayNanoseconds)
                }
            }
        } catch is LimitReached {
            // expected — --limit hit
        } catch is CancellationError {
            // user pressed Ctrl-C
        } catch {
            writeFinalLine("⚠ \(account.handle)  scrape error: \(error.localizedDescription)")
            continue
        }

        let elapsed = Date().timeIntervalSince(accountStart)
        writeFinalLine(
            "✓ \(account.handle.padding(toLength: 24, withPad: " ", startingAt: 0)) "
          + "\(accountNewPosts) new posts · "
          + "\(accountNewReplies + accountRefreshed) replies"
          + (accountRefreshed > 0 ? " (\(accountRefreshed) refreshed)" : "")
          + " · \(formatDuration(elapsed))"
        )

        grandNewPosts += accountNewPosts
        grandNewReplies += accountNewReplies
        grandRefreshed += accountRefreshed
    }

    let elapsed = Date().timeIntervalSince(runStart)
    let interrupted = cancel.isSet ? "  (interrupted)" : ""
    print("\nDone · \(grandNewPosts) new posts · \(grandNewReplies + grandRefreshed) replies (\(grandRefreshed) refreshed) · \(formatDuration(elapsed))\(interrupted)")
}

await runCLI()
