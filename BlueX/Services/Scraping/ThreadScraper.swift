import Foundation
import SwiftData

final class ThreadScraper {
    private let api: BlueskyAPIClient
    private let context: ModelContext
    private let rescrapingPolicy = RescrapingPolicy()

    init(api: BlueskyAPIClient, context: ModelContext) {
        self.api = api
        self.context = context
    }

    /// Depth-first: scrapes the full reply tree for every of `account`'s root posts that
    /// the rescraping policy still wants refreshed (within `window` of the post's creation,
    /// or never scraped yet). Used by the coordinator so each account is fully scraped
    /// (posts + complete reply trees) in a single pass before moving on.
    /// - Returns: total number of reply posts stored
    func scrapeAllThreads(for account: TrackedAccount, token: String,
                          window: TimeInterval = RescrapingPolicy.defaultWindow) async throws -> Int {
        var totalReplies = 0
        for post in try fetchRescrapableRootPosts(for: account, window: window) {
            totalReplies += try await scrapeThread(rootPost: post, token: token)
        }
        return totalReplies
    }

    /// Scrapes one post's full reply tree if the rescraping policy says it's due.
    /// - Returns: number of reply posts stored (0 if not due).
    func scrapeThreadIfDue(_ post: Post, token: String,
                           window: TimeInterval = RescrapingPolicy.defaultWindow) async throws -> Int {
        guard rescrapingPolicy.needsRescrape(post, window: window) else { return 0 }
        return try await scrapeThread(rootPost: post, token: token)
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
            // Leave as .inProgress so the coordinator can retry next batch
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
