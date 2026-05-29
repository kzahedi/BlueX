// BlueX/ViewModels/QueueViewModel.swift
import Foundation
import SwiftData
import Observation

@Observable
final class QueueViewModel {
    /// True while the QueueView's own per-pass async Task is running. Distinct from
    /// `coordinator.annotationService.isRunning` only briefly during setup/teardown.
    var isRunning: Bool = false
    var totalQueued: Int = 0
    var lastError: String? = nil

    var pendingPosts: [Post] = []
    var sentimentPending: Int = 0   // posts lacking an Apple-sentiment (nltagger) annotation

    /// Reasonable upper bound for posts shown in the queue list. Walking the full set
    /// (tens of thousands) hangs the main thread when each post's annotations
    /// relationship is faulted in.
    static let queueDisplayLimit = 100
    /// We also cap the candidate fetch we filter through, to avoid faulting relationships
    /// for the entire store just to get 100 visible rows.
    private static let queueFilterLimit = 1_000

    /// Counts and visible list are scoped to the LLM model currently selected in the
    /// picker. Each (post, modelName) is annotated at most once — prompt revisions on
    /// the same model do NOT trigger re-runs, so a tightened prompt won't silently
    /// double the existing queue.
    func loadQueue(from context: ModelContext,
                   activeModelName: String? = nil) {
        do {
            let totalPosts = try context.fetchCount(FetchDescriptor<Post>())
            let nlTaggerAnnotated = try context.fetchCount(FetchDescriptor<Annotation>(
                predicate: #Predicate { $0.stage == "nltagger" }
            ))
            sentimentPending = max(0, totalPosts - nlTaggerAnnotated)

            if let modelName = activeModelName {
                let matchedCount = try context.fetchCount(FetchDescriptor<Annotation>(
                    predicate: #Predicate {
                        $0.stage == "llm" && $0.modelName == modelName
                    }
                ))
                totalQueued = max(0, totalPosts - matchedCount)
            } else {
                totalQueued = totalPosts  // no model selected — everything is pending
            }

            // Bounded fetch for the visible queue list. Newest first; filter to those
            // the active model has not yet annotated, keep the first N.
            var descriptor = FetchDescriptor<Post>(
                sortBy: [SortDescriptor(\Post.createdAt, order: .reverse)]
            )
            descriptor.fetchLimit = Self.queueFilterLimit
            let candidates = try context.fetch(descriptor)
            pendingPosts = Array(
                candidates
                    .lazy
                    .filter { post in
                        guard let modelName = activeModelName else {
                            return !post.hasLLMAnnotation
                        }
                        return !post.annotations.contains {
                            $0.stage == "llm" && $0.modelName == modelName
                        }
                    }
                    .prefix(Self.queueDisplayLimit)
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

}
