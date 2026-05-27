import Foundation

// Why: A pure struct with no stored state is ideal for policy logic.
// Easy to unit test — just create an instance and call the method.
struct RescrapingPolicy {
    /// How long to wait before re-checking a thread for new replies.
    /// Returns nil if the post is too old to re-check (past cutoff).
    func recheckInterval(for post: Post) -> TimeInterval? {
        guard post.isRootPost else { return nil }

        let age = Date().timeIntervalSince(post.createdAt)
        let hour: TimeInterval = 3600
        let day: TimeInterval = 86400

        switch age {
        case ..<(48 * hour):    return 6 * hour
        case ..<(7 * day):      return day
        case ..<(30 * day):     return 3 * day
        case ..<(90 * day):     return 7 * day
        default:                return nil   // stop re-checking after 90 days
        }
    }

    /// Whether a root post should be re-scraped right now.
    func needsRescrape(_ post: Post) -> Bool {
        guard let interval = recheckInterval(for: post) else { return false }
        guard let lastChecked = post.replyTreeLastChecked else { return true }
        return Date().timeIntervalSince(lastChecked) >= interval
    }
}
