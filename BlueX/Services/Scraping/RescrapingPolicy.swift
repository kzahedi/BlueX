import Foundation

// Decides whether a root post's reply tree should be (re-)scraped on a given run.
//
// Model: most replies arrive in the first days after a post, so we only keep refreshing
// a reply tree for a bounded window after the post was created. A newly-discovered post
// is always scraped at least once (regardless of age); after that, a re-scrape is allowed
// only while the *previous* scrape happened within `createdAt + window`. That yields one
// final catch-up scrape just after the window closes, then the tree is frozen.
struct RescrapingPolicy {
    /// Default reply-tree refresh window. Overridable via the "scraping.maxRescrapeWindowDays" setting.
    static let defaultWindow: TimeInterval = 14 * 86400  // 14 days

    func needsRescrape(_ post: Post, window: TimeInterval = defaultWindow) -> Bool {
        guard post.isRootPost else { return false }
        // Never scraped → always scrape once, no matter how old the post is.
        guard let lastChecked = post.replyTreeLastChecked else { return true }
        // Otherwise re-scrape only while the previous scrape was inside the window.
        return lastChecked <= post.createdAt.addingTimeInterval(window)
    }
}
