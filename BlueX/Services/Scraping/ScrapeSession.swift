import Foundation

/// Thrown by a long-running operation to ask `ScrapeSession` for a *proactive*
/// re-auth at a safe boundary, before the token has actually expired.
///
/// The scrapers take a plain `String` token, so a feed scrape that runs for hours
/// keeps using the token it was handed. Rather than thread a token provider
/// through FeedScraper/ThreadScraper (and every caller and test of them), the CLI
/// throws this from the per-post callback when the session is old enough. The
/// operation is then restarted with a fresh token — cheap, because `resumeCursor`
/// makes a restarted feed scrape resume at the last page boundary instead of
/// starting over, and posts already stored are skipped as duplicates.
struct TokenRefreshDue: Error {}

/// `createSession` itself failed. This is NOT an expired token — it means the
/// credentials are refused, so no later account can succeed either. The CLI turns
/// this into `authDead` and stops the whole run.
struct ReauthenticationFailed: Error, LocalizedError {
    let underlying: BlueskyError?
    var errorDescription: String? {
        underlying?.localizedDescription ?? "Bluesky re-authentication failed."
    }
}

/// The per-phase re-auth budget ran out. Distinct from `ReauthenticationFailed`:
/// here `createSession` keeps succeeding but the API keeps rejecting the token we
/// get back, so retrying is pointless. Fails this account, not the run.
struct AuthRetryBudgetExhausted: Error, LocalizedError {
    let limit: Int
    var errorDescription: String? {
        "gave up after \(limit) re-authentications in one phase — the API kept rejecting freshly issued tokens."
    }
}

/// Owns the Bluesky access token for the lifetime of a scrape run and keeps it
/// valid across an arbitrarily long run.
///
/// Bluesky access tokens last ~2 h. A single NYT-class account backfills for
/// hours, so a run crosses the expiry boundary *several times per account*. The
/// previous `for attempt in 0...1` loop in the CLI allowed exactly one re-auth per
/// account phase: the first expiry was handled, the second fell through to the
/// generic error path and abandoned the account mid-feed. That cost the
/// 2026-08-04 run ~40 % of its corpus.
///
/// Two independent mechanisms, deliberately kept both:
///
/// * **Proactive** — `withToken` re-auths at the top if the session is older than
///   `refreshAfter`, and an operation may signal `TokenRefreshDue` mid-flight.
///   This avoids paying a failed request plus a restart every two hours.
/// * **Reactive** — any `.authFailed` out of the operation triggers a re-auth and
///   a retry. This stays as the safety net: the token lifetime is the server's to
///   decide, and it can be shortened or revoked at any moment.
///
/// Not thread-safe by design — the CLI drives one account at a time.
final class ScrapeSession {
    /// Refresh once the session is this old. Tokens last ~2 h; 75 min leaves a
    /// wide margin for a slow account phase to finish its current operation
    /// without ever presenting an expired token, while still refreshing rarely
    /// enough that createSession traffic stays negligible (~1/h).
    static let defaultRefreshAfter: TimeInterval = 75 * 60

    /// Hard ceiling on re-auths that indicate *trouble* — a spurious
    /// `TokenRefreshDue` signal, or a genuine `.authFailed` — within a single
    /// `withToken` call, i.e. per account phase. Scheduled refreshes (the session
    /// legitimately crossing `refreshAfter`) do not draw on this budget at all: see
    /// `withToken`.
    ///
    /// Why a flat cap rather than a progress requirement: "progress" during a feed
    /// scrape is not observable from here (a page of already-stored posts yields
    /// nothing new yet is legitimate work), so a progress rule would either be
    /// wrong or need plumbing through the scrapers. A cap is honest and provably
    /// finite: a server answering `.authFailed` to everything terminates after 16
    /// createSession round-trips instead of spinning forever.
    ///
    /// This used to be justified as "~20 h of continuous work at the 75-minute
    /// cadence", on the theory that no phase runs longer. That reasoning is what
    /// caused the 2026-08-07 bug: it is not a duration budget, and treating it as
    /// one truncated spiegel.de at 20h41m and tagesschau at 21h15m — both cut off
    /// mid-scrape, with zero actual auth failures, just healthy scheduled refreshes
    /// rationed as if they were trouble.
    static let defaultMaxReauths = 16

    enum RefreshReason: Equatable {
        /// Scheduled — the session is older than `refreshAfter`; nothing failed.
        case scheduled
        /// A call came back `.authFailed`; the token died earlier than expected.
        case expired
    }

    /// The token as currently held. Callers that do best-effort work (the daily
    /// profile snapshot) may read it directly; anything that must not be
    /// abandoned should go through `withToken`.
    private(set) var token: String
    private var issuedAt: Date

    private let refreshAfter: TimeInterval
    private let maxReauths: Int
    private let now: () -> Date
    private let authenticate: () async -> Result<String, BlueskyError>
    private let onReauth: ((RefreshReason) -> Void)?

    /// Total successful re-auths so far, across all phases. Diagnostics only.
    private(set) var reauthCount = 0

    init(token: String,
         issuedAt: Date,
         refreshAfter: TimeInterval = ScrapeSession.defaultRefreshAfter,
         maxReauths: Int = ScrapeSession.defaultMaxReauths,
         now: @escaping () -> Date = Date.init,
         onReauth: ((RefreshReason) -> Void)? = nil,
         authenticate: @escaping () async -> Result<String, BlueskyError>) {
        self.token = token
        self.issuedAt = issuedAt
        self.refreshAfter = refreshAfter
        self.maxReauths = maxReauths
        self.now = now
        self.onReauth = onReauth
        self.authenticate = authenticate
    }

    /// True once the current session is older than `refreshAfter`. Long-running
    /// operations poll this at a safe boundary and throw `TokenRefreshDue`.
    var isRefreshDue: Bool {
        now().timeIntervalSince(issuedAt) >= refreshAfter
    }

    /// Runs `operation` with a live token, re-authenticating and retrying as often
    /// as needed up to `maxReauths`.
    ///
    /// Errors that are none of our business — `LimitReached`, `CancellationError`,
    /// a genuine network failure — propagate untouched, so the caller's existing
    /// clean-exit paths keep working.
    func withToken<T>(_ operation: (String) async throws -> T) async throws -> T {
        // Budget covers only re-auths that indicate trouble. Scheduled refreshes are
        // uncapped: they are driven by wall-clock time, each one resets `issuedAt` so
        // `isRefreshDue` goes false immediately, and they signal progress rather than
        // failure. Rationing them killed spiegel.de at 20h41m and tagesschau at 21h15m
        // on 2026-08-07 while both were scraping successfully.
        var failureReauths = 0

        func spendFailure(_ reason: RefreshReason) async throws {
            guard failureReauths < maxReauths else {
                throw AuthRetryBudgetExhausted(limit: maxReauths)
            }
            failureReauths += 1
            try await reauthenticate(reason: reason)
        }

        while true {
            if isRefreshDue { try await reauthenticate(reason: .scheduled) }
            do {
                return try await operation(token)
            } catch is TokenRefreshDue {
                if isRefreshDue {
                    // Legitimate: the operation noticed the horizon before we did.
                    try await reauthenticate(reason: .scheduled)
                } else {
                    // Spurious — an operation signalling when nothing is due could
                    // restart forever, so this draws on the budget.
                    try await spendFailure(.scheduled)
                }
            } catch let error where ScrapeSession.isAuthFailure(error) {
                try await spendFailure(.expired)
            }
        }
    }

    /// - Throws: `ReauthenticationFailed` when createSession is refused — bad
    ///   credentials, which no amount of retrying fixes.
    private func reauthenticate(reason: RefreshReason) async throws {
        onReauth?(reason)
        switch await authenticate() {
        case .success(let newToken):
            token = newToken
            issuedAt = now()
            reauthCount += 1
        case .failure(let error):
            throw ReauthenticationFailed(underlying: error)
        }
    }

    /// An expired/invalid token, as opposed to any other failure. `perform` maps
    /// both 401 and a 400 `ExpiredToken`/`InvalidToken` body onto `.authFailed`.
    static func isAuthFailure(_ error: Error) -> Bool {
        if let blueskyError = error as? BlueskyError, case .authFailed = blueskyError { return true }
        return false
    }
}
