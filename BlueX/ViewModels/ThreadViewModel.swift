// BlueX/ViewModels/ThreadViewModel.swift
import Foundation
import Observation

@Observable
final class ThreadViewModel {
    var isExpanded: Bool = true
    var selectedPostURI: String? = nil
    var filterClass: String? = nil

    // Build a flat, depth-ordered list of posts from the thread tree
    func orderedPosts(root: Post, allPosts: [Post]) -> [Post] {
        // Build a map from parentURI → children
        var childMap: [String: [Post]] = [:]
        for post in allPosts {
            if let parentURI = post.parentURI {
                childMap[parentURI, default: []].append(post)
            }
        }
        // Sort children by date
        for key in childMap.keys {
            childMap[key]?.sort { $0.createdAt < $1.createdAt }
        }
        // DFS traversal
        var result: [Post] = []
        func traverse(_ post: Post) {
            if let cls = filterClass {
                if post.currentSpeechClass == cls { result.append(post) }
            } else {
                result.append(post)
            }
            for child in childMap[post.uri] ?? [] {
                traverse(child)
            }
        }
        traverse(root)
        return result
    }

    func hateCount(in posts: [Post]) -> Int {
        posts.filter { $0.currentSpeechClass == "hate" }.count
    }

    func counterCount(in posts: [Post]) -> Int {
        posts.filter { $0.currentSpeechClass == "counter" }.count
    }

    func pendingCount(in posts: [Post]) -> Int {
        posts.filter { !$0.hasLLMAnnotation }.count
    }
}
