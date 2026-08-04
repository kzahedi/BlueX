// BlueX/Services/Annotation/NLTaggerPass.swift
import Foundation
import SwiftData

/// Applies Apple's on-device NLTagger sentiment to every post lacking an "nltagger"
/// annotation.
///
/// Deliberately plain — no Observation, no @MainActor — because project.yml excludes
/// AnnotationService.swift from the BlueXAnnotate target, so the CLI cannot use that
/// class. Both the GUI service and blueX-annotate call this instead: one
/// implementation, two consumers.
///
/// Paging is the point. The store holds ~797k posts; the previous implementation
/// fetched all of them and then tested `post.hasNLTaggerAnnotation`, which faults
/// each post's `annotations` relationship. That is why a full backfill never
/// completed.
struct NLTaggerPass {
    private let container: ModelContainer
    private let tagger = NLTaggerAnalyser()

    init(container: ModelContainer) {
        self.container = container
    }

    /// Annotates pending posts and returns how many were written.
    ///
    /// - Parameters:
    ///   - batchSize: posts fetched and saved per page.
    ///   - limit: stop after this many annotations. Needed to measure throughput
    ///     before committing to a full-corpus run.
    ///   - minTextLength: posts whose text is shorter than this after a whitespace
    ///     trim are skipped entirely — no annotation is written. NLTagger scores a
    ///     contentless post 0.0, whereas genuinely neutral German text scores ~0.4,
    ///     and ChartsViewModel averages raw scores; a population of 0.0s therefore
    ///     drags sentiment trends downward. Skipping (rather than sentinel-marking,
    ///     as the LLM passes do) keeps them out of the average. They stay pending,
    ///     which costs nothing: this pass already walks the whole corpus per run.
    ///     0 disables the filter — the default, so GUI callers are unchanged.
    ///   - isCancelled: polled once per page.
    ///   - progress: called after each page with (annotatedSoFar, estimatedTotal).
    @discardableResult
    func run(batchSize: Int = 200,
             limit: Int? = nil,
             minTextLength: Int = 0,
             isCancelled: () -> Bool = { false },
             progress: ((Int, Int) -> Void)? = nil) throws -> Int {

        // URIs that already carry an nltagger annotation. One cheap fetch (2,600 rows
        // today) instead of faulting 797k relationships — the same `alreadyDone`
        // pattern already proven at cli/annotate/main.swift:361-370.
        let indexContext = ModelContext(container)
        let doneURIs: Set<String> = Set(
            try indexContext.fetch(FetchDescriptor<Annotation>(
                predicate: #Predicate<Annotation> { $0.stage == "nltagger" }
            )).compactMap { $0.post?.uri }
        )

        let postCount = try indexContext.fetchCount(FetchDescriptor<Post>())
        let estimatedTotal = limit ?? max(0, postCount - doneURIs.count)
        progress?(0, estimatedTotal)

        var offset = 0
        var annotated = 0

        while offset < postCount {
            if isCancelled() { break }
            if let limit, annotated >= limit { break }

            // A fresh context per page keeps the object graph bounded. One long-lived
            // context would end up registering all 797k posts.
            let context = ModelContext(container)
            var page = FetchDescriptor<Post>(sortBy: [SortDescriptor(\Post.uri)])
            page.fetchOffset = offset
            page.fetchLimit = batchSize
            let posts = try context.fetch(page)
            if posts.isEmpty { break }
            // Inserting annotations never changes the Post count, so advancing the
            // offset by the page size stays correct across iterations.
            offset += posts.count

            var insertedThisPage = 0
            for post in posts {
                if let limit, annotated >= limit { break }
                guard !doneURIs.contains(post.uri) else { continue }
                if minTextLength > 0,
                   post.text.trimmingCharacters(in: .whitespacesAndNewlines).count < minTextLength {
                    continue
                }
                let annotation = tagger.analyse(text: post.text)
                context.insert(annotation)
                annotation.post = post
                annotated += 1
                insertedThisPage += 1
            }
            if insertedThisPage > 0 { try context.save() }
            progress?(annotated, estimatedTotal)
        }

        return annotated
    }
}
