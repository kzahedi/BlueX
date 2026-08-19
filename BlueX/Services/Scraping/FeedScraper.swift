import Foundation
import SwiftData

// Why: FeedScraper is a class (not struct) because it holds a ModelContext reference,
// which is a reference type. Copying a struct would not copy the context correctly.
final class FeedScraper {
    private let api: BlueskyAPIClient
    private let context: ModelContext
    private let now: () -> Date

    init(api: BlueskyAPIClient, context: ModelContext, now: @escaping () -> Date = Date.init) {
        self.api = api
        self.context = context
        self.now = now
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

        // Why: a pass only used to clear the cursor on the log it created itself.
        // Any OLDER `failed` log with a live cursor was left untouched forever, so
        // every later pass kept re-resuming that same stale cursor. Since
        // getAuthorFeed pages newest→oldest, resuming an old cursor walks only
        // deeper into already-stored history — the top of the feed (all new
        // posts) is never revisited, and the pass "succeeds" having found zero
        // new posts. This silently blocked all new-post collection for five news
        // outlets from 2026-08-13 to 2026-08-19. Clearing every incomplete feed
        // log here makes the resume optimisation self-limiting: one pass consumes
        // a stale cursor and clears it, so the next pass starts fresh from the top.
        for staleLog in try fetchAllIncompleteLogs(for: account) {
            staleLog.resumeCursor = nil
        }
        try context.save()

        return newPostCount
    }

    // MARK: - Private helpers

    private func fetchIncompleteLog(for account: TrackedAccount) throws -> ScrapeLog? {
        // Why: FetchDescriptor with #Predicate is SwiftData's type-safe query builder.
        // The predicate macro generates the underlying NSPredicate at compile time.
        //
        // 48h staleness guard: a cursor left over from a pass more than two days
        // old resumes a walk whose skipped-top window is enormous — this is
        // exactly the shape of the 2026-08-13 – 2026-08-19 data-loss incident,
        // where stale cursors from October 2023 / January 2024 kept getting
        // resumed indefinitely. Past 48h it's cheaper and safer to start the walk
        // fresh from the top of the feed and let the duplicate check do its job
        // than to trust an ancient cursor.
        let did = account.did
        let cutoff = now().addingTimeInterval(-48 * 3600)
        var descriptor = FetchDescriptor<ScrapeLog>(
            predicate: #Predicate<ScrapeLog> { log in
                log.account?.did == did &&
                log.type == "feed" &&
                log.status == "failed" &&
                log.resumeCursor != nil &&
                log.date >= cutoff
            },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// All incomplete feed logs for this account, regardless of age — used only
    /// to clear stale cursors on successful completion (see `scrape`). Unlike
    /// `fetchIncompleteLog` this is intentionally NOT limited by the 48h cutoff:
    /// an ancient cursor should still be nil'd out once we know the account is
    /// caught up, not left dangling forever.
    private func fetchAllIncompleteLogs(for account: TrackedAccount) throws -> [ScrapeLog] {
        let did = account.did
        let descriptor = FetchDescriptor<ScrapeLog>(
            predicate: #Predicate<ScrapeLog> { log in
                log.account?.did == did &&
                log.type == "feed" &&
                log.status == "failed" &&
                log.resumeCursor != nil
            }
        )
        return try context.fetch(descriptor)
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
