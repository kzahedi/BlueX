import Foundation
import SwiftData
import Observation

enum CoordinatorPhase: String, Equatable {
    case idle, preparing, feed, thread, annotating
}

// Per-account progress through a scrape run, surfaced as a status dot in the sidebar.
enum AccountScrapeStatus: String, Equatable {
    case queued     // selected for this run, not started
    case scraping   // feed + reply trees in progress
    case done       // finished successfully
    case failed     // errored out this run
}

// Why: @Observable is the modern replacement for ObservableObject (macOS 14+).
// It tracks exactly which properties each SwiftUI View reads and only re-renders
// those views when those specific properties change. No @Published needed.
@Observable
final class ScrapeCoordinator {
    // UI-facing state — SwiftUI views observe these directly
    var phase: CoordinatorPhase = .idle
    var currentAccountHandle: String = ""
    var progress: Double = 0.0
    var lastError: BlueskyError? = nil
    var totalPostsThisRun: Int = 0
    // Per-account status for this run, keyed by DID. Drives the sidebar status dots.
    var accountStatuses: [String: AccountScrapeStatus] = [:]

    private let api: BlueskyAPIClient
    private let modelContainer: ModelContainer

    // Rate limiting: Bluesky public API ≈ 3,000 requests/hour
    private var requestCount = 0
    private var windowStart = Date()
    private let maxRequestsPerWindow = 2800  // conservative buffer

    // Cancellation flag — checked between accounts
    private var isCancelled = false

    init(api: BlueskyAPIClient, modelContainer: ModelContainer) {
        self.api = api
        self.modelContainer = modelContainer
    }

    // Internal for testing — runNLTaggerAnnotation doesn't need the api client
    init(modelContainer: ModelContainer) {
        self.api = BlueskyAPIClient()
        self.modelContainer = modelContainer
    }

    // MARK: - Public interface (called from UI)

    /// Starts a full scrape cycle: feed → thread → NLTagger annotation.
    func startScrape() {
        // Why: Task { } creates a new async task that runs concurrently.
        // We can't make this method async because SwiftUI buttons call it synchronously.
        Task { await runScrape() }
    }

    /// Cancels the current scrape after the current account finishes.
    func cancel() {
        isCancelled = true
    }

    // MARK: - State machine

    // Why: NOT @MainActor — the heavy work (network, DB) runs on a background thread.
    // All mutations to @Observable properties are dispatched explicitly via MainActor.run { }
    // so SwiftUI can re-render freely between awaits without the main thread being blocked.
    private func runScrape() async {
        let isIdle = await MainActor.run { phase == .idle }
        guard isIdle else { return }

        await MainActor.run {
            isCancelled = false
            totalPostsThisRun = 0
            lastError = nil
            accountStatuses = [:]
            phase = .preparing
        }

        // Acquire Bluesky token (runs on background thread)
        guard let creds = KeychainCredentials.load() else {
            await MainActor.run { lastError = .authFailed; phase = .idle }
            return
        }

        let authResult = await api.createSession(handle: creds.handle, password: creds.password)
        guard case .success(let session) = authResult else {
            await MainActor.run {
                if case .failure(let error) = authResult { lastError = error }
                phase = .idle
            }
            return
        }
        let token = session.accessJwt

        // ModelContext lives on this background task for its entire lifetime
        let context = ModelContext(modelContainer)

        let accounts: [TrackedAccount]
        do {
            accounts = try context.fetch(FetchDescriptor<TrackedAccount>(
                predicate: #Predicate { $0.isActive == true }
            ))
        } catch {
            await MainActor.run {
                lastError = .networkError(underlying: error.localizedDescription)
                phase = .idle
            }
            return
        }

        // --- Phase: depth-first scraping ---
        // For each account we scrape the feed, then immediately scrape the full reply
        // tree for every one of that account's root posts, before moving to the next
        // account. So each account is fully scraped (posts + complete reply trees) in
        // one pass rather than threads being a separate, batch-limited phase.
        await MainActor.run {
            phase = .feed
            for account in accounts { accountStatuses[account.did] = .queued }
        }
        let feedScraper = FeedScraper(api: api, context: context)
        let threadScraper = ThreadScraper(api: api, context: context)

        // Reply-tree refresh window (global setting, days). Defaults to 14 days.
        let windowDays = UserDefaults.standard.object(forKey: "scraping.maxRescrapeWindowDays") as? Int ?? 14
        let rescrapeWindow = TimeInterval(windowDays) * 86400

        for (index, account) in accounts.enumerated() {
            guard !isCancelled else { break }
            await MainActor.run {
                currentAccountHandle = account.handle
                progress = Double(index) / Double(max(accounts.count, 1))
                accountStatuses[account.did] = .scraping
            }

            do {
                let newPosts = try await feedScraper.scrape(account: account, token: token)
                await MainActor.run { totalPostsThisRun += newPosts }

                // Depth-first: full reply tree for each of this account's root posts.
                let replies = try await threadScraper.scrapeAllThreads(for: account, token: token, window: rescrapeWindow)
                await MainActor.run {
                    totalPostsThisRun += replies
                    accountStatuses[account.did] = .done
                }
            } catch let error as BlueskyError {
                if case .rateLimited(let retryAfter) = error {
                    await MainActor.run { accountStatuses[account.did] = .failed }
                    try? await Task.sleep(nanoseconds: UInt64(retryAfter * 1_000_000_000))
                } else {
                    await MainActor.run { lastError = error; accountStatuses[account.did] = .failed }
                }
            } catch {
                await MainActor.run {
                    lastError = .networkError(underlying: error.localizedDescription)
                    accountStatuses[account.did] = .failed
                }
            }

            await checkAndEnforceRateLimit()
        }

        // --- Phase: annotation (NLTagger baseline pass) ---
        await MainActor.run { phase = .annotating }
        try? await runNLTaggerAnnotation()

        // Persist final state
        persistPhase(.idle, context: context)
        await MainActor.run {
            phase = .idle
            currentAccountHandle = ""
            progress = 1.0
        }
    }

    // MARK: - Annotation

    /// Runs NLTagger on all unannotated posts. Called automatically after each scrape.
    func runNLTaggerAnnotation() async throws {
        phase = .annotating
        let service = AnnotationService(modelContainer: modelContainer)
        try await service.runNLTaggerPass()
    }

    /// Runs LLM annotation on demand from the UI (e.g. QueueView's "Start" button).
    func runLLMAnnotation(using client: any LocalModelClient, batchSize: Int = 10) async {
        phase = .annotating
        let service = AnnotationService(modelContainer: modelContainer)
        service.setActiveClient(client)
        do {
            try await service.runLLMPass(batchSize: batchSize)
        } catch {
            lastError = .networkError(underlying: error.localizedDescription)
        }
        phase = .idle
    }

    // MARK: - Rate limiting

    private func checkAndEnforceRateLimit() async {
        requestCount += 1
        let elapsed = Date().timeIntervalSince(windowStart)

        if elapsed < 3600 && requestCount >= maxRequestsPerWindow {
            let waitTime = 3600 - elapsed
            try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
            requestCount = 0
            windowStart = Date()
        } else if elapsed >= 3600 {
            requestCount = 0
            windowStart = Date()
        }
    }

    // MARK: - State persistence (for resume on restart)

    private func persistPhase(_ phase: CoordinatorPhase, context: ModelContext,
                              accountDID: String? = nil, postURI: String? = nil) {
        let states = (try? context.fetch(FetchDescriptor<CoordinatorState>())) ?? []
        let state = states.first ?? CoordinatorState()
        if states.isEmpty { context.insert(state) }
        state.phase = phase.rawValue
        state.currentAccountDID = accountDID
        state.currentPostURI = postURI
        state.updatedAt = Date()
        try? context.save()
    }

    /// Returns true if the app was previously interrupted mid-scrape.
    func checkForInterruptedScrape(context: ModelContext) -> Bool {
        guard let state = (try? context.fetch(FetchDescriptor<CoordinatorState>()))?.first else {
            return false
        }
        return state.phase != CoordinatorPhase.idle.rawValue
    }
}
