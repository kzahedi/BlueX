import Foundation
import SwiftData
import Observation

enum CoordinatorPhase: String, Equatable {
    case idle, preparing, feed, thread, annotating
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

    private let api: BlueskyAPIClient
    private let modelContainer: ModelContainer
    private let rescrapingPolicy = RescrapingPolicy()

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

        // --- Phase: feed scraping ---
        await MainActor.run { phase = .feed }
        let feedScraper = FeedScraper(api: api, context: context)

        for (index, account) in accounts.enumerated() {
            guard !isCancelled else { break }
            await MainActor.run {
                currentAccountHandle = account.handle
                progress = Double(index) / Double(max(accounts.count, 1))
            }

            do {
                let newPosts = try await feedScraper.scrape(account: account, token: token)
                await MainActor.run { totalPostsThisRun += newPosts }
            } catch let error as BlueskyError {
                if case .rateLimited(let retryAfter) = error {
                    try? await Task.sleep(nanoseconds: UInt64(retryAfter * 1_000_000_000))
                } else {
                    await MainActor.run { lastError = error }
                }
            } catch {
                await MainActor.run { lastError = .networkError(underlying: error.localizedDescription) }
            }

            await checkAndEnforceRateLimit()
        }

        // --- Phase: thread scraping ---
        await MainActor.run { phase = .thread }
        let threadScraper = ThreadScraper(api: api, context: context)
        do {
            let replies = try await threadScraper.scrapeNextBatch(token: token, batchSize: 20)
            await MainActor.run { totalPostsThisRun += replies }
        } catch let error as BlueskyError {
            await MainActor.run { lastError = error }
        } catch {}

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
