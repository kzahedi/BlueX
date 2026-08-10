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

    /// Loads weekly buckets from the aggregate reader, off the main actor.
    ///
    /// Replaces `computeBuckets(from:)`, which materialised up to ~874k `Post` objects
    /// and ran eight filter passes per bucket on the MainActor to produce twelve numbers.
    /// Speech-class and sentiment fields stay zero: `ZANNOTATION` is empty right now, so
    /// there is nothing to classify by yet.
    @MainActor
    func load(accountPKs: [Int64], reader: AggregateReader) async {
        let buckets: [WeekBucket] = await Task.detached(priority: .userInitiated) {
            let roots = (try? reader.rootPostsPerWeek(accountPKs: accountPKs)) ?? []
            let replies = (try? reader.repliesPerWeek(accountPKs: accountPKs)) ?? []

            var byWeek: [Date: (root: Int, reply: Int)] = [:]
            for w in roots { byWeek[w.weekStart, default: (0, 0)].root += w.count }
            for w in replies { byWeek[w.weekStart, default: (0, 0)].reply += w.count }

            return byWeek.map { week, counts in
                WeekBucket(
                    id: week, weekStart: week,
                    hateCount: 0, counterCount: 0, neutralCount: 0,
                    pendingCount: counts.root,
                    replyHateCount: 0, replyCounterCount: 0, replyNeutralCount: 0,
                    replyPendingCount: counts.reply,
                    avgSentiment: 0, sentimentSampleCount: 0
                )
            }.sorted { $0.weekStart < $1.weekStart }
        }.value
        self.weekBuckets = buckets
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
