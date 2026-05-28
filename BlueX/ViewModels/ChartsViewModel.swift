// BlueX/ViewModels/ChartsViewModel.swift
import Foundation
import Observation

/// One weekly bucket of annotation counts, split by root posts vs replies.
struct WeekBucket: Identifiable {
    let id: Date  // start of the ISO week (Monday)
    let weekStart: Date

    // Root posts (isRootPost == true) — the tracked account's own posts
    let hateCount: Int
    let counterCount: Int
    let neutralCount: Int
    let pendingCount: Int

    // Replies (isRootPost == false) — other users responding in thread
    let replyHateCount: Int
    let replyCounterCount: Int
    let replyNeutralCount: Int
    let replyPendingCount: Int

    // Apple NLTagger sentiment, averaged across every post in the week that has a
    // score (root + replies). `sentimentSampleCount == 0` means no posts were scored.
    let avgSentiment: Double
    let sentimentSampleCount: Int

    var totalAnnotated: Int { hateCount + counterCount + neutralCount }
    var total: Int { totalAnnotated + pendingCount }

    var replyTotalAnnotated: Int { replyHateCount + replyCounterCount + replyNeutralCount }
    var replyTotal: Int { replyTotalAnnotated + replyPendingCount }

    var hateRatio: Double { total > 0 ? Double(hateCount) / Double(total) : 0 }
    var counterRatio: Double { total > 0 ? Double(counterCount) / Double(total) : 0 }
    var neutralRatio: Double { total > 0 ? Double(neutralCount) / Double(total) : 0 }

    var replyHateRatio: Double { replyTotal > 0 ? Double(replyHateCount) / Double(replyTotal) : 0 }
    var replyCounterRatio: Double { replyTotal > 0 ? Double(replyCounterCount) / Double(replyTotal) : 0 }
}

@Observable
final class ChartsViewModel {
    var weekBuckets: [WeekBucket] = []
    var selectedWeek: Date? = nil
    var windowWeeks: Int = 12    // default: show 12 weeks

    // MARK: - Aggregation

    func computeBuckets(from posts: [Post]) {
        guard !posts.isEmpty else {
            weekBuckets = []
            return
        }

        let calendar = Calendar(identifier: .iso8601)

        // Group posts by ISO week start (Monday)
        var grouped: [Date: [Post]] = [:]
        for post in posts {
            let weekStart = calendar.dateInterval(of: .weekOfYear, for: post.createdAt)?.start ?? post.createdAt
            grouped[weekStart, default: []].append(post)
        }

        // Build sorted buckets, splitting root posts from replies
        let sorted = grouped.sorted { $0.key < $1.key }
        weekBuckets = sorted.map { (weekStart, weekPosts) in
            let roots   = weekPosts.filter { $0.isRootPost }
            let replies = weekPosts.filter { !$0.isRootPost }

            func classCount(_ pool: [Post], _ cls: String) -> Int {
                pool.filter { $0.currentSpeechClass == cls }.count
            }
            func pendingCount(_ pool: [Post]) -> Int {
                pool.filter { !$0.hasLLMAnnotation }.count
            }

            let scores = weekPosts.compactMap { $0.nlTaggerAnnotation?.sentimentScore }
            let avg = scores.isEmpty ? 0 : scores.reduce(0, +) / Double(scores.count)

            return WeekBucket(
                id: weekStart,
                weekStart: weekStart,
                hateCount:    classCount(roots,   "hate"),
                counterCount: classCount(roots,   "counter"),
                neutralCount: classCount(roots,   "neutral"),
                pendingCount: pendingCount(roots),
                replyHateCount:    classCount(replies, "hate"),
                replyCounterCount: classCount(replies, "counter"),
                replyNeutralCount: classCount(replies, "neutral"),
                replyPendingCount: pendingCount(replies),
                avgSentiment: avg,
                sentimentSampleCount: scores.count
            )
        }
    }

    /// Returns only the most recent `windowWeeks` buckets.
    var visibleBuckets: [WeekBucket] {
        guard weekBuckets.count > windowWeeks else { return weekBuckets }
        return Array(weekBuckets.suffix(windowWeeks))
    }

    // MARK: - Summary stats across visible window

    var totalHate: Int { visibleBuckets.reduce(0) { $0 + $1.hateCount } }
    var totalCounter: Int { visibleBuckets.reduce(0) { $0 + $1.counterCount } }
    var totalNeutral: Int { visibleBuckets.reduce(0) { $0 + $1.neutralCount } }
    var totalPosts: Int { visibleBuckets.reduce(0) { $0 + $1.total } }

    var totalReplies: Int { visibleBuckets.reduce(0) { $0 + $1.replyTotal } }
    var totalReplyHate: Int { visibleBuckets.reduce(0) { $0 + $1.replyHateCount } }
    var totalReplyCounter: Int { visibleBuckets.reduce(0) { $0 + $1.replyCounterCount } }

    var overallHateRatio: Double {
        totalPosts > 0 ? Double(totalHate) / Double(totalPosts) : 0
    }
    var overallCounterRatio: Double {
        totalPosts > 0 ? Double(totalCounter) / Double(totalPosts) : 0
    }

    // MARK: - Trend (latest week vs previous week)

    var hateTrend: Double {
        guard visibleBuckets.count >= 2 else { return 0 }
        let latest = Double(visibleBuckets.last!.hateCount)
        let previous = Double(visibleBuckets[visibleBuckets.count - 2].hateCount)
        guard previous > 0 else { return 0 }
        return (latest - previous) / previous
    }
}
