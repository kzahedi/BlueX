// BlueX/ViewModels/AccountViewModel.swift
import Foundation
import SwiftData
import Observation

@Observable
final class AccountViewModel {
    var searchText: String = ""
    var filterClass: String? = nil   // nil = show all
    var sortNewestFirst: Bool = true
    var isLoading: Bool = false

    // Derived counts (updated externally from SwiftData query results)
    var totalPosts: Int = 0
    var hateCount: Int = 0
    var counterCount: Int = 0
    var neutralCount: Int = 0
    var pendingCount: Int = 0

    func filteredPosts(_ posts: [Post]) -> [Post] {
        var result = posts

        // Text filter
        if !searchText.isEmpty {
            result = result.filter {
                $0.text.localizedCaseInsensitiveContains(searchText) ||
                $0.authorHandle.localizedCaseInsensitiveContains(searchText)
            }
        }

        // Class filter
        if let cls = filterClass {
            result = result.filter { $0.currentSpeechClass == cls }
        }

        // Sort
        if sortNewestFirst {
            result.sort { $0.createdAt > $1.createdAt }
        } else {
            result.sort { $0.createdAt < $1.createdAt }
        }

        return result
    }

    func updateCounts(from posts: [Post]) {
        totalPosts = posts.count
        hateCount = posts.filter { $0.currentSpeechClass == "hate" }.count
        counterCount = posts.filter { $0.currentSpeechClass == "counter" }.count
        neutralCount = posts.filter { $0.currentSpeechClass == "neutral" }.count
        pendingCount = posts.filter { !$0.hasLLMAnnotation }.count
    }
}
