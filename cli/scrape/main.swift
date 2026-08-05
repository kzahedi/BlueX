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
//   blueX-scrape --check-credentials      — Keychain + Bluesky login only, no store
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
    /// Preflight mode: prove the Keychain ACL and the Bluesky login work, without
    /// touching the store. See the `--check-credentials` block in `runCLI()`.
    var checkCredentials = false
    var help = false

    static func parse(_ argv: [String]) -> CLIArgs {
        var a = CLIArgs()
        var i = 1
        while i < argv.count {
            let arg = argv[i]
            switch arg {
            case "-h", "--help":          a.help = true
            case "--list-accounts":       a.listAccounts = true
            case "--check-credentials":   a.checkCredentials = true
            case "--handle":
                i += 1; if i < argv.count { a.handle = argv[i] }
            case "--pace":
                i += 1
                if i < argv.count, let p = LLMPace(rawValue: argv[i]) { a.pace = p }
                else if i < argv.count { fail("blueX-scrape", "invalid --pace value '\(argv[i])'. Valid: burst, steady, gentle") }
            case "--limit":
                i += 1
                if i < argv.count, let n = Int(argv[i]), n > 0 { a.limit = n }
                else if i < argv.count { fail("blueX-scrape", "invalid --limit value '\(argv[i])'") }
            case "--max-window-days":
                i += 1
                if i < argv.count, let n = Int(argv[i]), n > 0 { a.maxWindowDays = n }
                else if i < argv.count { fail("blueX-scrape", "invalid --max-window-days value '\(argv[i])'") }
            default:
                fail("blueX-scrape", "unknown argument: \(arg). Run --help for usage.")
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
  --check-credentials    Preflight the unattended path: read the Bluesky
                         credentials from the Keychain and open a real session
                         against bsky.social, then exit. Deliberately does NOT
                         open the SwiftData store, so it works (and stays a
                         sharp diagnostic) even with the store volume detached
                         or a scrape already running. Exits 0 only if both the
                         Keychain read and the login succeed.
  --help, -h             This help.

Reads + writes the BlueX SwiftData store at
  ~/Library/Application Support/BlueX/default.store

Credentials come from the macOS Keychain item written by the GUI's
Settings → Credentials. If none are present, run the GUI once to save them.

Ctrl-C stops at the next post boundary; the partial batch is already saved
(the depth-first scraper persists each new post + its thread tree immediately).
"""

// fail / formatDuration / writeProgress / writeFinalLine / CancelFlag /
// installSIGINTHandler now live in cli/Shared/CLISupport.swift.

/// Thrown by the feed-scraper callback to break out cleanly when --limit is hit.
struct LimitReached: Error {}

// MARK: - Main

func runCLI() async {
    // A full disk raises an NSException out of CoreData, which Swift cannot catch;
    // without this the process SIGABRTs with no exit status and no heartbeat. See
    // installUncaughtExceptionHandler.
    installUncaughtExceptionHandler(program: "blueX-scrape")

    let args = CLIArgs.parse(CommandLine.arguments)
    if args.help { print(usage); return }

    // ---- credential preflight — MUST stay above openContainer().
    //
    // The nightly job's preflight needs to know that an unattended 03:31 run can
    // actually authenticate. `--list-accounts` was previously assumed to prove
    // that; it does not — it returns before KeychainCredentials.load() is ever
    // called. The CLIs are ad-hoc signed (CODE_SIGN_IDENTITY "-"), so a rebuild
    // can change the identity a Keychain ACL was granted to, and an ACL prompt at
    // 03:31 has nobody to answer it. This flag exercises the real path: Keychain
    // read, then a live createSession.
    //
    // No store access on purpose. Keeping it independent of the external volume
    // makes it a sharper diagnostic (it separates "credentials broken" from
    // "volume missing") and avoids opening the store a second time while a long
    // scrape holds it.
    if args.checkCredentials {
        guard let creds = KeychainCredentials.load() else {
            fail("blueX-scrape", "✗ Keychain: no Bluesky credentials found. Open BlueX → Settings → Credentials, save an app password, then re-run.")
        }
        print("✓ Keychain: credentials for @\(creds.handle)")
        let api = BlueskyAPIClient()
        let result = await api.createSession(handle: creds.handle, password: creds.password)
        guard case .success = result else {
            if case .failure(let err) = result {
                fail("blueX-scrape", "✗ Bluesky: authentication failed for @\(creds.handle): \(err)")
            }
            fail("blueX-scrape", "✗ Bluesky: authentication failed for @\(creds.handle)")
        }
        print("✓ Bluesky: session created for @\(creds.handle)")
        print("✓ credentials ok (store not touched)")
        return
    }

    let container: ModelContainer
    do { container = try BlueXStore.openContainer() }
    catch { fail("blueX-scrape", "failed to open store: \(error)") }
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
        fail("blueX-scrape", "no Bluesky credentials in the Keychain. Open BlueX → Settings → Credentials, save an app password, then re-run.")
    }
    // The CLI prints a one-line notice each time the API client decides to wait out a
    // 429. Without it, the scrape would just go silent for ~60 s and look hung. The
    // observer also includes the retry-attempt number so the user can see if we're
    // hitting the budget repeatedly (a sign to slow down or split the run).
    let api = BlueskyAPIClient(
        onRateLimited: { retryAfter, attempt in
            writeProgress("⏸ rate limited — waiting \(Int(retryAfter))s (retry \(attempt))…")
        }
    )
    FileHandle.standardOutput.write(Data("authenticating as @\(creds.handle)…\n".utf8))
    let authResult = await api.createSession(handle: creds.handle, password: creds.password)
    guard case .success(let session) = authResult else {
        if case .failure(let err) = authResult { fail("blueX-scrape", "authentication failed: \(err)") }
        fail("blueX-scrape", "authentication failed")
    }
    let token = session.accessJwt

    // ---- accounts
    let allActive: [TrackedAccount]
    do {
        allActive = try context.fetch(FetchDescriptor<TrackedAccount>(
            predicate: #Predicate { $0.isActive == true },
            sortBy: [SortDescriptor(\.handle)]
        ))
    } catch { fail("blueX-scrape", "failed to fetch accounts: \(error)") }

    let accounts: [TrackedAccount]
    if let h = args.handle {
        let matched = allActive.filter { $0.handle == h || $0.did == h }
        if matched.isEmpty { fail("blueX-scrape", "no active account matches handle/DID '\(h)'. Run --list-accounts.") }
        accounts = matched
    } else {
        accounts = allActive
    }
    if accounts.isEmpty { fail("blueX-scrape", "no active accounts to scrape.") }

    // ---- cancel handler (Ctrl-C)
    let cancel = installSIGINTHandler(notice: "\n\nstopping after current post — please wait…\n")

    let feedScraper = FeedScraper(api: api, context: context)
    let threadScraper = ThreadScraper(api: api, context: context)
    let window = TimeInterval(args.maxWindowDays) * 86400

    print("Scraping \(accounts.count) account\(accounts.count == 1 ? "" : "s") · pace \(args.pace.rawValue) · \(args.maxWindowDays)-day reply window\n")

    // Bluesky session tokens last ~2 h. Long backfills on NYT-class accounts
    // routinely outlast that, after which every API call fails with
    // ExpiredToken. We hold the token in a var and refresh it via the helper
    // below whenever a call returns .authFailed.
    var currentToken = token
    func refreshToken() async -> Bool {
        writeProgress("token expired — re-authenticating as @\(creds.handle)…")
        let r = await api.createSession(handle: creds.handle, password: creds.password)
        if case .success(let s) = r {
            currentToken = s.accessJwt
            return true
        }
        if case .failure(let err) = r {
            writeFinalLine("⚠ re-auth failed: \(err.localizedDescription) — stopping.")
        }
        return false
    }

    /// Returns true if `err` was an authFailed and we successfully refreshed —
    /// caller should retry the operation. Returns false otherwise.
    func isAuthFailed(_ err: Error) -> Bool {
        if let blueskyErr = err as? BlueskyError, case .authFailed = blueskyErr {
            return true
        }
        return false
    }

    let runStart = Date()
    var grandNewPosts = 0
    var grandNewReplies = 0
    var grandRefreshed = 0
    // Anything that made this run scrape less than it was asked to. A revoked app
    // password or a total auth outage used to print a ⚠ and exit 0, which is
    // indistinguishable from "nothing new" to the nightly job and the watchdog —
    // exactly the silent-success failure class that hid the 61-day outage. Per
    // account resilience is preserved (one bad account does not abort the rest),
    // but the PROCESS exit code now reflects that something failed.
    var runFailed = false
    // Set when re-authentication fails: the token is dead, so no later account can
    // succeed either. Stops the run — but through the normal summary, not a bare
    // `return`, so the failure reaches the exit code.
    var authDead = false

    for (idx, account) in accounts.enumerated() {
        if cancel.isSet { break }

        // ---- snapshot (once per calendar day per account) --------------------
        // getProfile failure is silent — don't abort a scrape over missing stats.
        let alreadySnapshotted = account.snapshots.contains {
            Calendar.current.isDateInToday($0.timestamp)
        }
        if !alreadySnapshotted,
           case .success(let profile) = await api.getProfile(did: account.did, token: currentToken) {
            let accountDID = account.did
            let rootPosts = (try? context.fetch(FetchDescriptor<Post>(
                predicate: #Predicate<Post> { $0.account?.did == accountDID && $0.isRootPost == true }
            ))) ?? []
            let snapshot = AccountSnapshot(
                timestamp: Date(),
                followerCount: profile.followersCount ?? 0,
                followingCount: profile.followsCount  ?? 0,
                postCount:      profile.postsCount    ?? 0,
                totalLikes:   rootPosts.reduce(0) { $0 + $1.likeCount },
                totalReplies: rootPosts.reduce(0) { $0 + $1.replyCount },
                totalReposts: rootPosts.reduce(0) { $0 + $1.repostCount },
                totalQuotes:  rootPosts.reduce(0) { $0 + $1.quoteCount }
            )
            snapshot.account = account
            context.insert(snapshot)
            try? context.save()
        }
        // -----------------------------------------------------------------------

        let accountStart = Date()
        var accountNewPosts = 0
        var accountNewReplies = 0
        var accountRefreshed = 0
        let banner = "\(account.handle) (\(idx + 1)/\(accounts.count))"

        writeProgress("\(banner) · refreshing existing reply trees…")

        // ---- Phase 1: refresh reply trees of already-stored posts still within the window.
        // On authFailed we refresh the token once and retry the phase; second
        // failure surfaces normally.
        for attempt in 0...1 {
            do {
                accountRefreshed = try await threadScraper.scrapeAllThreads(
                    for: account, token: currentToken, window: window
                )
                break
            } catch let err where isAuthFailed(err) && attempt == 0 {
                if !(await refreshToken()) { runFailed = true; authDead = true; break }
                continue
            } catch {
                writeFinalLine("⚠ \(account.handle)  refresh failed: \(error.localizedDescription)")
                runFailed = true
                break
            }
        }
        if authDead { break }

        // ---- Phase 2: feed scrape, depth-first per post.
        for attempt in 0...1 {
            do {
                let pace = args.pace
                let limit = args.limit
                _ = try await feedScraper.scrape(account: account, token: currentToken) { post in
                    if cancel.isSet { throw CancellationError() }
                    let replies = try await threadScraper.scrapeThreadIfDue(
                        post, token: currentToken, window: window
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
                break
            } catch is LimitReached {
                break  // expected — --limit hit
            } catch is CancellationError {
                break  // user pressed Ctrl-C
            } catch let err where isAuthFailed(err) && attempt == 0 {
                if !(await refreshToken()) { runFailed = true; authDead = true; break }
                continue
            } catch {
                writeFinalLine("⚠ \(account.handle)  scrape error: \(error.localizedDescription)")
                runFailed = true
                break
            }
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

        if authDead { break }
    }

    let elapsed = Date().timeIntervalSince(runStart)
    let interrupted = cancel.isSet ? "  (interrupted)" : ""
    print("\nDone · \(grandNewPosts) new posts · \(grandNewReplies + grandRefreshed) replies (\(grandRefreshed) refreshed) · \(formatDuration(elapsed))\(interrupted)")

    // Ctrl-C (and --limit) remain exit-0 cases: the user asked for the stop and the
    // work is saved. Only genuine failures set runFailed.
    if runFailed {
        FileHandle.standardError.write(Data(
            (authDead
                ? "blueX-scrape: run aborted — re-authentication failed (see ⚠ above).\n"
                : "blueX-scrape: run completed with errors on one or more accounts (see ⚠ above).\n").utf8
        ))
        exit(1)
    }
}

await runCLI()
