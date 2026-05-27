import Foundation
import SwiftData

// Why: FeedScraper is a class (not struct) because it holds a ModelContext reference,
// which is a reference type. Copying a struct would not copy the context correctly.
final class FeedScraper {
    private let api: BlueskyAPIClient
    private let context: ModelContext

    init(api: BlueskyAPIClient, context: ModelContext) {
        self.api = api
        self.context = context
    }

    /// Scrapes root posts for one account.
    /// - Parameter onNewRootPost: called for each newly-stored root post, right after it
    ///   is saved. Used for depth-first scraping — the coordinator scrapes the post's full
    ///   reply tree here, before the next post is fetched.
    /// - Returns: number of new posts stored
    /// - Throws: BlueskyError on API failure
    func scrape(account: TrackedAccount, token: String,
                onNewRootPost: ((Post) async throws -> Void)? = nil) async throws -> Int {
        var newPostCount = 0
        var cursor: String? = nil

        // Resume from a previous incomplete scrape if one exists
        if let existingLog = try fetchIncompleteLog(for: account) {
            cursor = existingLog.resumeCursor
        }

        // Create a new log entry (status starts as "failed"; set to "complete" only if we finish)
        let log = ScrapeLog(date: Date(), type: "feed", status: "failed", postCount: 0)
        log.account = account
        context.insert(log)

        scrapeLoop: while true {
            let result = await api.getAuthorFeed(did: account.did, token: token, cursor: cursor)

            switch result {
            case .success(let response):
                for feedPost in response.feed {
                    // Only store posts authored by the tracked account (skip reblogs/reposts)
                    guard feedPost.post.author.did == account.did else { continue }
                    // Only store posts within our date range
                    guard let postDate = ATProtoDate.parse(feedPost.post.record.createdAt),
                          postDate >= account.startAt else { continue }

                    if !isDuplicate(uri: feedPost.post.uri) {
                        let post = mapToPost(feedPost.post, account: account)
                        context.insert(post)
                        newPostCount += 1
                        // Save immediately so the post (and the replies the callback is
                        // about to attach) persist and show up in the UI right away.
                        try context.save()
                        try await onNewRootPost?(post)
                    }
                }

                // Persist cursor after each page — enables mid-scrape resume
                log.resumeCursor = response.cursor
                try context.save()

                guard let nextCursor = response.cursor, !response.feed.isEmpty else {
                    break scrapeLoop
                }
                cursor = nextCursor

            case .failure(let error):
                throw error
            }
        }

        log.status = "complete"
        log.postCount = newPostCount
        log.resumeCursor = nil  // clear on successful completion
        try context.save()

        return newPostCount
    }

    // MARK: - Private helpers

    private func fetchIncompleteLog(for account: TrackedAccount) throws -> ScrapeLog? {
        // Why: FetchDescriptor with #Predicate is SwiftData's type-safe query builder.
        // The predicate macro generates the underlying NSPredicate at compile time.
        let did = account.did
        var descriptor = FetchDescriptor<ScrapeLog>(
            predicate: #Predicate<ScrapeLog> { log in
                log.account?.did == did &&
                log.type == "feed" &&
                log.status == "failed" &&
                log.resumeCursor != nil
            },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func isDuplicate(uri: String) -> Bool {
        var descriptor = FetchDescriptor<Post>(
            predicate: #Predicate<Post> { $0.uri == uri }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor).first) != nil
    }

    private func mapToPost(_ apiPost: ATProtoPost, account: TrackedAccount) -> Post {
        let createdAt = ATProtoDate.parse(apiPost.record.createdAt) ?? Date()

        let post = Post(
            uri: apiPost.uri,
            text: apiPost.record.text,
            createdAt: createdAt,
            authorDID: apiPost.author.did,
            authorHandle: apiPost.author.handle,
            parentURI: apiPost.record.reply?.parent.uri,
            rootURI: apiPost.record.reply?.root.uri ?? apiPost.uri,
            isRootPost: apiPost.record.reply == nil,
            depth: apiPost.record.reply == nil ? 0 : 1
        )
        post.likeCount = apiPost.likeCount ?? 0
        post.replyCount = apiPost.replyCount ?? 0
        post.quoteCount = apiPost.quoteCount ?? 0
        post.repostCount = apiPost.repostCount ?? 0
        post.account = account
        return post
    }
}
