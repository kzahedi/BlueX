import Foundation

/// Decides whether a root post's reply tree should be (re-)scraped on a given run.
///
/// The policy has two axes — completeness, and age relative to the rescrape window:
///
///   replyTreeStatus != .complete           → ALWAYS scrape (regardless of age)
///   replyTreeStatus == .complete           → scrape ONLY while inside the window
///
/// "Complete" means we successfully called `getPostThread` and persisted the result,
/// OR we hit a terminal API failure (.notFound / .badRequest) and marked the post
/// complete to stop retrying a dead URI. "Inside the window" means the previous
/// successful scrape happened on or before `createdAt + window`. That gives one
/// catch-up scrape just after the window closes, then the tree is frozen.
///
/// This pair of rules guarantees the "every post is scraped completely at least
/// once" invariant: any post that hasn't reached `.complete` will be retried on
/// every future run, regardless of how old the post is. Spreading the catch-up
/// across multiple runs (because of rate limits, network drops, Ctrl-C) is fine.
///
/// Conversely, once a post IS complete, the window stops us from re-querying
/// trees that have already gone cold — reply velocity drops to near-zero days
/// after a post is published.
struct RescrapingPolicy {
    /// Default reply-tree refresh window. Overridable via the
    /// "scraping.maxRescrapeWindowDays" setting.
    static let defaultWindow: TimeInterval = 14 * 86400  // 14 days

    func needsRescrape(_ post: Post, window: TimeInterval = defaultWindow) -> Bool {
        guard post.isRootPost else { return false }

        // Incomplete trees (.pending / .inProgress) are ALWAYS due, regardless of age.
        // Successful scrapes set .complete + lastChecked; terminal failures also set
        // .complete (with lastChecked = Date()) so they don't loop here either.
        guard post.replyTreeStatus == .complete else { return true }

        // Complete and never checked is a degenerate state — surface it as due so the
        // next pass repairs the inconsistency.
        guard let lastChecked = post.replyTreeLastChecked else { return true }

        // Complete + checked: rescrape only while we're still inside the window.
        return lastChecked <= post.createdAt.addingTimeInterval(window)
    }
}
