// BlueX/ViewModels/QueueViewModel.swift
import Foundation
import SwiftData
import Observation

@Observable
final class QueueViewModel {
    var isRunning: Bool = false
    var batchSize: Int = 10
    var processedCount: Int = 0
    var totalQueued: Int = 0
    var lastError: String? = nil
    var progress: Double = 0.0

    var pendingPosts: [Post] = []
    var sentimentPending: Int = 0   // posts lacking an Apple-sentiment (nltagger) annotation

    func loadQueue(from context: ModelContext) {
        do {
            sentimentPending = try context.fetch(FetchDescriptor<Post>())
                .filter { !$0.hasNLTaggerAnnotation }
                .count
            let all = try context.fetch(
                FetchDescriptor<Post>(
                    predicate: #Predicate<Post> { $0.needsReAnnotation == true },
                    sortBy: [SortDescriptor(\Post.createdAt, order: .reverse)]
                )
            )
            // Also include posts with no LLM annotation
            let unannotated = try context.fetch(
                FetchDescriptor<Post>(
                    sortBy: [SortDescriptor(\Post.createdAt, order: .reverse)]
                )
            ).filter { !$0.hasLLMAnnotation }

            var combined = all
            for post in unannotated {
                if !combined.contains(where: { $0.uri == post.uri }) {
                    combined.append(post)
                }
            }
            pendingPosts = combined
            totalQueued = combined.count
        } catch {
            lastError = error.localizedDescription
        }
    }

    func updateProgress(processed: Int, total: Int) {
        processedCount = processed
        totalQueued = total
        progress = total > 0 ? Double(processed) / Double(total) : 0
    }
}
