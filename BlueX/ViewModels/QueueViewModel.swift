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

    /// Reasonable upper bound for posts shown in the queue list. Walking the full set
    /// (tens of thousands) hangs the main thread when each post's annotations
    /// relationship is faulted in.
    static let queueDisplayLimit = 100
    /// We also cap the candidate fetch we filter through, to avoid faulting relationships
    /// for the entire store just to get 100 visible rows.
    private static let queueFilterLimit = 1_000

    /// Counts and visible list are scoped to the LLM configuration (`activeModelName`,
    /// `activeModelPromptHash`) currently selected in the picker. Each (model, prompt)
    /// pair is treated as its own annotation lineage, so a second model run sees the
    /// full backlog again instead of "0 pending" once the first model is done.
    func loadQueue(from context: ModelContext,
                   activeModelName: String? = nil,
                   activeModelPromptHash: String? = nil) {
        do {
            let totalPosts = try context.fetchCount(FetchDescriptor<Post>())
            let nlTaggerAnnotated = try context.fetchCount(FetchDescriptor<Annotation>(
                predicate: #Predicate { $0.stage == "nltagger" }
            ))
            sentimentPending = max(0, totalPosts - nlTaggerAnnotated)

            if let modelName = activeModelName, let promptHash = activeModelPromptHash {
                let matchedCount = try context.fetchCount(FetchDescriptor<Annotation>(
                    predicate: #Predicate {
                        $0.stage == "llm"
                        && $0.modelName == modelName
                        && $0.promptHash == promptHash
                    }
                ))
                totalQueued = max(0, totalPosts - matchedCount)
            } else {
                totalQueued = totalPosts  // no model selected — everything is pending
            }

            // Bounded fetch for the visible queue list. Newest first; filter to those
            // the active model+prompt has not yet annotated, keep the first N.
            var descriptor = FetchDescriptor<Post>(
                sortBy: [SortDescriptor(\Post.createdAt, order: .reverse)]
            )
            descriptor.fetchLimit = Self.queueFilterLimit
            let candidates = try context.fetch(descriptor)
            pendingPosts = Array(
                candidates
                    .lazy
                    .filter { post in
                        guard let modelName = activeModelName, let promptHash = activeModelPromptHash else {
                            return !post.hasLLMAnnotation
                        }
                        return !post.annotations.contains {
                            $0.stage == "llm"
                            && $0.modelName == modelName
                            && $0.promptHash == promptHash
                        }
                    }
                    .prefix(Self.queueDisplayLimit)
            )
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
