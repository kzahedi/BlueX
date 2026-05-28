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
    // One service for the app's lifetime so the Queue view can observe live progress.
    let annotationService: AnnotationService

    // Rate limiting: Bluesky public API ≈ 3,000 requests/hour
    private var requestCount = 0
    private var windowStart = Date()
    private let maxRequestsPerWindow = 2800  // conservative buffer

    // Cancellation flag — checked between accounts
    private var isCancelled = false

    init(api: BlueskyAPIClient, modelContainer: ModelContainer) {
        self.api = api
        self.modelContainer = modelContainer
        self.annotationService = AnnotationService(modelContainer: modelContainer)
    }

    // Internal for testing — runNLTaggerAnnotation doesn't need the api client
    init(modelContainer: ModelContainer) {
        self.api = BlueskyAPIClient()
        self.modelContainer = modelContainer
        self.annotationService = AnnotationService(modelContainer: modelContainer)
    }

    // MARK: - Public interface (called from UI)

    /// Starts a scrape of every active tracked account (feed + reply trees).
    func startScrape() {
        // Why: Task { } creates a new async task that runs concurrently.
        // We can't make this method async because SwiftUI buttons call it synchronously.
        Task { await runScrape() }
    }

    /// Starts a scrape limited to a single account, identified by DID.
    /// Same flow as startScrape() but with the account list restricted.
    func startScrape(accountDID: String) {
        Task { await runScrape(restrictTo: [accountDID]) }
    }

    /// Cancels the current scrape after the current account finishes.
    func cancel() {
        isCancelled = true
    }

    // MARK: - State machine

    // Why: NOT @MainActor — the heavy work (network, DB) runs on a background thread.
    // All mutations to @Observable properties are dispatched explicitly via MainActor.run { }
    // so SwiftUI can re-render freely between awaits without the main thread being blocked.
    /// Runs the scrape pipeline. If `restrictTo` is non-nil, only accounts with those
    /// DIDs are scraped; otherwise all active accounts are scraped.
    private func runScrape(restrictTo: [String]? = nil) async {
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
            let allActive = try context.fetch(FetchDescriptor<TrackedAccount>(
                predicate: #Predicate { $0.isActive == true }
            ))
            if let restrictTo {
                let keep = Set(restrictTo)
                accounts = allActive.filter { keep.contains($0.did) }
            } else {
                accounts = allActive
            }
        } catch {
            await MainActor.run {
                lastError = .networkError(underlying: error.localizedDescription)
                phase = .idle
            }
            return
        }

        // --- Phase: depth-first scraping ---
        // Depth-first per post: for each account we first refresh the reply trees of
        // previously-stored posts still inside the rescrape window, then feed-scrape new
        // posts — scraping each new post's full reply tree before moving to the next post.
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
                // Refresh reply trees of already-stored posts that are still due. These are
                // disjoint from the new posts the feed scrape finds below, so no post's tree
                // is scraped twice in one run.
                let refreshed = try await threadScraper.scrapeAllThreads(for: account, token: token, window: rescrapeWindow)

                // Feed scrape new posts; depth-first — each new post's full reply tree is
                // scraped in the callback before the next post is fetched.
                let newPosts = try await feedScraper.scrape(account: account, token: token) { [self] post in
                    let replies = try await threadScraper.scrapeThreadIfDue(post, token: token, window: rescrapeWindow)
                    if replies > 0 {
                        await MainActor.run { totalPostsThisRun += replies }
                    }
                }
                await MainActor.run {
                    totalPostsThisRun += newPosts + refreshed
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

        // Annotation (Apple sentiment / LLM) is a separate step, triggered independently
        // from the Annotation Queue — scraping no longer runs it automatically.

        // Persist final state
        persistPhase(.idle, context: context)
        await MainActor.run {
            phase = .idle
            currentAccountHandle = ""
            progress = 1.0
        }
    }

    // MARK: - Annotation

    /// Runs Apple's NLTagger sentiment pass on all posts lacking one. Triggered
    /// independently from the Annotation Queue (not as part of scraping). Heavy work
    /// runs on a background ModelContext with batched saves; progress is observable
    /// on `annotationService`.
    func runNLTaggerAnnotation() async throws {
        phase = .annotating
        defer { phase = .idle }
        try await annotationService.runNLTaggerPass()
    }

    /// Runs LLM annotation on demand from the UI. Continuous — keeps classifying
    /// until the queue is empty or `cancelAnnotation()` is called. `saveEvery` is
    /// the transactional batch size, not a hard limit.
    func runLLMAnnotation(using client: any LocalModelClient, saveEvery: Int = 20) async {
        phase = .annotating
        annotationService.setActiveClient(client)
        do {
            try await annotationService.runLLMPass(saveEvery: saveEvery)
        } catch {
            lastError = .networkError(underlying: error.localizedDescription)
        }
        phase = .idle
    }

    /// Cancels an in-flight LLM (or sentiment) annotation pass.
    func cancelAnnotation() {
        annotationService.cancel()
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
