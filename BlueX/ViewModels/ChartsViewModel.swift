// BlueX/ViewModels/ChartsViewModel.swift
import Foundation
import Observation

/// One weekly bucket of annotation counts.
struct WeekBucket: Identifiable {
    let id: Date  // start of the ISO week (Monday)
    let weekStart: Date
    let hateCount: Int
    let counterCount: Int
    let neutralCount: Int
    let pendingCount: Int

    var totalAnnotated: Int { hateCount + counterCount + neutralCount }
    var total: Int { totalAnnotated + pendingCount }

    var hateRatio: Double { total > 0 ? Double(hateCount) / Double(total) : 0 }
    var counterRatio: Double { total > 0 ? Double(counterCount) / Double(total) : 0 }
    var neutralRatio: Double { total > 0 ? Double(neutralCount) / Double(total) : 0 }
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

        // Build sorted buckets
        let sorted = grouped.sorted { $0.key < $1.key }
        weekBuckets = sorted.map { (weekStart, weekPosts) in
            let hate = weekPosts.filter { $0.annotations.last(where: { $0.stage == "llm" })?.speechClass == "hate" }.count
            let counter = weekPosts.filter { $0.annotations.last(where: { $0.stage == "llm" })?.speechClass == "counter" }.count
            let neutral = weekPosts.filter { $0.annotations.last(where: { $0.stage == "llm" })?.speechClass == "neutral" }.count
            let pending = weekPosts.filter { $0.annotations.last(where: { $0.stage == "llm" }) == nil }.count
            return WeekBucket(
                id: weekStart,
                weekStart: weekStart,
                hateCount: hate,
                counterCount: counter,
                neutralCount: neutral,
                pendingCount: pending
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
