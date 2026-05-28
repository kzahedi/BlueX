// BlueX/Data/AnnotationDedup.swift
import Foundation
import SwiftData

/// One-shot maintenance: ensure every (post, modelName) pair has at most one LLM
/// annotation. Older duplicates left over from earlier prompt-revision runs are
/// removed via SwiftData's ModelContext so the CoreData metadata stays consistent
/// (raw-SQL deletes against the store can corrupt the store).
enum AnnotationDedup {
    /// Removes older duplicate LLM annotations, keeping the newest per (post, modelName).
    /// - Returns: number of annotations deleted.
    @discardableResult
    static func dedupLLM(in context: ModelContext) throws -> Int {
        let llmAnnotations = try context.fetch(FetchDescriptor<Annotation>(
            predicate: #Predicate { $0.stage == "llm" }
        ))

        // Group by (postURI, modelName).
        var grouped: [String: [Annotation]] = [:]
        for ann in llmAnnotations {
            guard let postURI = ann.post?.uri else { continue }
            let key = "\(postURI)\u{0}\(ann.modelName)"
            grouped[key, default: []].append(ann)
        }

        var deleted = 0
        for (_, group) in grouped where group.count > 1 {
            // Sort newest-first; delete every annotation past index 0.
            let sorted = group.sorted { $0.createdAt > $1.createdAt }
            for old in sorted.dropFirst() {
                context.delete(old)
                deleted += 1
            }
        }
        if deleted > 0 {
            try context.save()
        }
        return deleted
    }
}
