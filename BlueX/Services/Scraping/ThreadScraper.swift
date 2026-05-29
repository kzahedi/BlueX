import Foundation
import SwiftData

final class ThreadScraper {
    private let api: BlueskyAPIClient
    private let context: ModelContext
    private let rescrapingPolicy = RescrapingPolicy()

    /// Failures the scraper reports back to the caller AFTER one whole pass over
    /// an account's posts. Per-post failures don't abort the loop — they're
    /// recorded here and surfaced as a summary, so a single dead post never blocks
    /// the rest of the account from being scraped.
    struct PassSummary {
        var repliesStored: Int = 0
        var postsScrapedOK: Int = 0
        var postsTerminalFailure: Int = 0   // .notFound / .badRequest — marked complete
        var postsTransientFailure: Int = 0  // network / 429-exhausted — left .inProgress
        var firstTransientError: BlueskyError? = nil  // for surfacing to the user
    }

    init(api: BlueskyAPIClient, context: ModelContext) {
        self.api = api
        self.context = context
    }

    /// Depth-first: scrapes the full reply tree for every of `account`'s root posts that
    /// the rescraping policy still wants refreshed. Per-post failures don't abort the
    /// loop — terminal failures (.notFound / .badRequest) mark the post complete so we
    /// don't retry a dead URI; transient failures (network, 429-exhausted) leave the
    /// post as .inProgress so it's picked up on the next run.
    /// - Returns: total number of reply posts stored
    func scrapeAllThreads(for account: TrackedAccount, token: String,
                          window: TimeInterval = RescrapingPolicy.defaultWindow) async throws -> Int {
        let summary = try await scrapeAllThreadsDetailed(for: account, token: token, window: window)
        return summary.repliesStored
    }

    /// Same as `scrapeAllThreads` but returns the full PassSummary so callers can
    /// surface counts (CLI progress line, GUI sidebar status).
    func scrapeAllThreadsDetailed(for account: TrackedAccount, token: String,
                                  window: TimeInterval = RescrapingPolicy.defaultWindow) async throws -> PassSummary {
        var summary = PassSummary()
        for post in try fetchRescrapableRootPosts(for: account, window: window) {
            switch await scrapeThreadSafely(rootPost: post, token: token) {
            case .scrapedOK(let count):
                summary.repliesStored += count
                summary.postsScrapedOK += 1
            case .terminalFailure:
                summary.postsTerminalFailure += 1
            case .transientFailure(let error):
                summary.postsTransientFailure += 1
                if summary.firstTransientError == nil { summary.firstTransientError = error }
            }
        }
        return summary
    }

    /// Scrapes one post's full reply tree if the rescraping policy says it's due.
    /// - Returns: number of reply posts stored (0 if not due, or if a transient
    ///   failure occurred — terminal failures mark the post complete and also
    ///   return 0). Throws ONLY on programmer errors in `processThreadView`;
    ///   network/API errors are absorbed here so the depth-first scrape never
    ///   loses its place on one bad post.
    func scrapeThreadIfDue(_ post: Post, token: String,
                           window: TimeInterval = RescrapingPolicy.defaultWindow) async throws -> Int {
        guard rescrapingPolicy.needsRescrape(post, window: window) else { return 0 }
        switch await scrapeThreadSafely(rootPost: post, token: token) {
        case .scrapedOK(let count):
            return count
        case .terminalFailure, .transientFailure:
            return 0
        }
    }

    // MARK: - Internals

    private enum SingleScrapeOutcome {
        case scrapedOK(replies: Int)
        case terminalFailure                  // post is gone, marked .complete
        case transientFailure(BlueskyError)   // retry next run
    }

    /// Wraps `scrapeThread` with terminal-vs-transient failure classification.
    /// Terminal failures (`.notFound` / `.badRequest`) advance `replyTreeLastChecked`
    /// and set `.complete`, ending the retry loop for that URI. Transient failures
    /// (`.networkError`, `.rateLimited`-after-retries) leave the post as `.inProgress`
    /// so the next run picks it up — that's how the "every post complete at least once"
    /// guarantee survives partial runs.
    private func scrapeThreadSafely(rootPost: Post, token: String) async -> SingleScrapeOutcome {
        do {
            let count = try await scrapeThread(rootPost: rootPost, token: token)
            return .scrapedOK(replies: count)
        } catch let error as BlueskyError {
            switch error {
            case .notFound, .badRequest:
                markTerminal(rootPost)
                return .terminalFailure
            case .authFailed:
                // Token expiry mid-run is rare but recoverable; treat as transient.
                return .transientFailure(error)
            case .rateLimited, .networkError, .decodingError:
                return .transientFailure(error)
            }
        } catch {
            return .transientFailure(.networkError(underlying: error.localizedDescription))
        }
    }

    private func markTerminal(_ post: Post) {
        // We can't fetch this post's tree (deleted, blocked, malformed URI), so
        // freeze it: status .complete + lastChecked = now → the rescraping policy
        // will not pick it up again, even on next runs. Without this we'd retry
        // dead URIs forever.
        post.replyTreeStatus = .complete
        post.replyTreeLastChecked = Date()
        try? context.save()
    }

    private func scrapeThread(rootPost: Post, token: String) async throws -> Int {
        rootPost.replyTreeStatus = .inProgress
        try context.save()

        let result = await api.getPostThread(uri: rootPost.uri, token: token)

        switch result {
        case .success(let response):
            let count = try processThreadView(
                view: response.thread,
                rootURI: rootPost.uri,
                parentURI: nil,
                depth: 0
            )
            rootPost.replyTreeStatus = .complete
            rootPost.replyTreeLastChecked = Date()
            try context.save()
            return count

        case .failure(let error):
            // Leave as .inProgress so the policy picks this post up on the next run.
            // Terminal vs transient classification happens at the caller (scrapeThreadSafely).
            rootPost.replyTreeStatus = .inProgress
            try context.save()
            throw error
        }
    }

    // Why: This is a recursive function. Each ATProtoThreadView can contain nested replies,
    // which also contain nested replies. We walk the entire tree depth-first.
    @discardableResult
    private func processThreadView(view: ATProtoThreadView, rootURI: String, parentURI: String?, depth: Int) throws -> Int {
        guard case .post(let threadPost) = view else { return 0 }

        var count = 0
        // Don't re-store the root post (already stored by FeedScraper)
        if depth > 0 {
            if isDuplicate(uri: threadPost.post.uri) {
                updateEngagement(uri: threadPost.post.uri, from: threadPost.post)
            } else {
                let post = mapToPost(threadPost.post, parentURI: parentURI, rootURI: rootURI, depth: depth)
                context.insert(post)
                count = 1
            }
        }

        for reply in threadPost.replies ?? [] {
            count += try processThreadView(
                view: reply,
                rootURI: rootURI,
                parentURI: threadPost.post.uri,
                depth: depth + 1
            )
        }
        return count
    }

    private func mapToPost(_ apiPost: ATProtoPost, parentURI: String?, rootURI: String, depth: Int) -> Post {
        let createdAt = ATProtoDate.parse(apiPost.record.createdAt) ?? Date()
        let post = Post(
            uri: apiPost.uri,
            text: apiPost.record.text,
            createdAt: createdAt,
            authorDID: apiPost.author.did,
            authorHandle: apiPost.author.handle,
            parentURI: parentURI,
            rootURI: rootURI,
            isRootPost: false,
            depth: depth
        )
        post.likeCount = apiPost.likeCount ?? 0
        post.replyCount = apiPost.replyCount ?? 0
        post.quoteCount = apiPost.quoteCount ?? 0
        post.repostCount = apiPost.repostCount ?? 0
        return post
    }

    private func updateEngagement(uri: String, from apiPost: ATProtoPost) {
        var descriptor = FetchDescriptor<Post>(predicate: #Predicate { $0.uri == uri })
        descriptor.fetchLimit = 1
        guard let post = (try? context.fetch(descriptor))?.first else { return }
        post.likeCount = apiPost.likeCount ?? post.likeCount
        post.replyCount = apiPost.replyCount ?? post.replyCount
        post.quoteCount = apiPost.quoteCount ?? post.quoteCount
        post.repostCount = apiPost.repostCount ?? post.repostCount
    }

    private func fetchRescrapableRootPosts(for account: TrackedAccount, window: TimeInterval) throws -> [Post] {
        let did = account.did
        let roots = try context.fetch(FetchDescriptor<Post>(
            predicate: #Predicate<Post> { $0.isRootPost == true && $0.account?.did == did },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        ))
        return roots.filter { rescrapingPolicy.needsRescrape($0, window: window) }
    }


    private func isDuplicate(uri: String) -> Bool {
        var descriptor = FetchDescriptor<Post>(predicate: #Predicate { $0.uri == uri })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor).first) != nil
    }
}
