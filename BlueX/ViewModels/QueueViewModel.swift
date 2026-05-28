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

    func loadQueue(from context: ModelContext) {
        do {
            // Counts via fetchCount — no post objects loaded. We approximate
            // "posts with an X annotation" as "X-stage annotations": a post can in
            // principle have multiple X annotations after re-annotation, but in
            // practice it has one, so this is accurate within ±1 per re-annotated post.
            let totalPosts = try context.fetchCount(FetchDescriptor<Post>())
            let nlTaggerAnnotated = try context.fetchCount(FetchDescriptor<Annotation>(
                predicate: #Predicate { $0.stage == "nltagger" }
            ))
            let llmAnnotated = try context.fetchCount(FetchDescriptor<Annotation>(
                predicate: #Predicate { $0.stage == "llm" }
            ))
            sentimentPending = max(0, totalPosts - nlTaggerAnnotated)
            totalQueued = max(0, totalPosts - llmAnnotated)

            // Bounded fetch for the visible queue list. Newest first; filter to those
            // still needing LLM annotation, keep the first N.
            var descriptor = FetchDescriptor<Post>(
                sortBy: [SortDescriptor(\Post.createdAt, order: .reverse)]
            )
            descriptor.fetchLimit = Self.queueFilterLimit
            let candidates = try context.fetch(descriptor)
            pendingPosts = Array(
                candidates
                    .lazy
                    .filter { $0.needsReAnnotation || !$0.hasLLMAnnotation }
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
