// BlueX/ViewModels/GroupViewModel.swift
import Foundation
import Observation

@Observable
final class GroupViewModel {
    var searchText: String = ""
    var filterClass: String? = nil
    var sortNewestFirst: Bool = true

    // Per-account stats for group overview
    var accountStats: [String: AccountStats] = [:]

    struct AccountStats {
        let handle: String
        let totalPosts: Int
        let hateCount: Int
        let counterCount: Int
        let neutralCount: Int
        let pendingCount: Int

        var hateRatio: Double {
            guard totalPosts > 0 else { return 0 }
            return Double(hateCount) / Double(totalPosts)
        }
        var counterRatio: Double {
            guard totalPosts > 0 else { return 0 }
            return Double(counterCount) / Double(totalPosts)
        }
    }

    func updateStats(for accounts: [TrackedAccount]) {
        var stats: [String: AccountStats] = [:]
        for account in accounts {
            let posts = account.posts
            let hate = posts.filter { $0.annotations.last(where: { $0.stage == "llm" })?.speechClass == "hate" }.count
            let counter = posts.filter { $0.annotations.last(where: { $0.stage == "llm" })?.speechClass == "counter" }.count
            let neutral = posts.filter { $0.annotations.last(where: { $0.stage == "llm" })?.speechClass == "neutral" }.count
            let pending = posts.filter { $0.annotations.last(where: { $0.stage == "llm" }) == nil }.count
            stats[account.handle] = AccountStats(
                handle: account.handle,
                totalPosts: posts.count,
                hateCount: hate,
                counterCount: counter,
                neutralCount: neutral,
                pendingCount: pending
            )
        }
        accountStats = stats
    }

    var totalGroupPosts: Int { accountStats.values.reduce(0) { $0 + $1.totalPosts } }
    var totalHate: Int { accountStats.values.reduce(0) { $0 + $1.hateCount } }
    var totalCounter: Int { accountStats.values.reduce(0) { $0 + $1.counterCount } }
    var totalNeutral: Int { accountStats.values.reduce(0) { $0 + $1.neutralCount } }
    var totalPending: Int { accountStats.values.reduce(0) { $0 + $1.pendingCount } }
}
