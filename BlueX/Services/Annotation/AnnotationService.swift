// BlueX/Services/Annotation/AnnotationService.swift
import Foundation
import SwiftData
import Observation

@Observable
final class AnnotationService {
    var isRunning: Bool = false
    var queueSize: Int = 0
    var processedCount: Int = 0
    var currentPostText: String = ""
    var errorCount: Int = 0
    var lastLLMError: String? = nil

    private let modelContainer: ModelContainer
    private let nlTagger = NLTaggerAnalyser()
    private var activeClient: (any LocalModelClient)?

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    func setActiveClient(_ client: any LocalModelClient) {
        self.activeClient = client
    }

    /// Runs Apple's NLTagger sentiment + language pass on every post lacking an
    /// nltagger annotation. The heavy work runs on a detached Task with its own
    /// background ModelContext; progress (current, total) is streamed back here and
    /// published on @Observable properties on the main actor. Saves in batches of
    /// `batchSize` so the SQLite write stays bounded and the UI stays responsive.
    @MainActor
    func runNLTaggerPass(batchSize: Int = 200) async throws {
        isRunning = true
        queueSize = 0
        processedCount = 0
        defer { isRunning = false }

        // Capture only Sendable values for the detached task — @Model instances are
        // confined to the context where they were fetched and must not escape.
        let container = modelContainer
        let tagger = nlTagger

        let stream = AsyncThrowingStream<(Int, Int), Error> { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    let context = ModelContext(container)
                    let pending = try context.fetch(FetchDescriptor<Post>())
                        .filter { !$0.hasNLTaggerAnnotation }
                    let total = pending.count
                    continuation.yield((0, total))

                    var processed = 0
                    while processed < total {
                        try Task.checkCancellation()
                        let upper = min(processed + batchSize, total)
                        for i in processed..<upper {
                            let post = pending[i]
                            let annotation = tagger.analyse(text: post.text)
                            context.insert(annotation)
                            annotation.post = post
                        }
                        try context.save()
                        processed = upper
                        continuation.yield((processed, total))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }

        for try await (processed, total) in stream {
            queueSize = total
            processedCount = processed
        }
    }

    @MainActor
    func runLLMPass(batchSize: Int = 10) async throws {
        guard let client = activeClient else { return }

        isRunning = true
        defer { isRunning = false }

        let context = modelContainer.mainContext
        let posts = try fetchPostsWithoutLLMAnnotation(context: context, limit: batchSize)
        queueSize = posts.count

        for post in posts {
            currentPostText = String(post.text.prefix(60))
            let baseline = post.nlTaggerAnnotation
            let language = baseline?.detectedLanguage ?? "other"
            do {
                let llmResult = try await client.classify(text: post.text, language: language)
                let baselineSentiment = baseline?.sentimentScore ?? 0.0
                let annotation = Annotation(
                    speechClass: llmResult.speechClass,
                    sentimentScore: baselineSentiment,
                    detectedLanguage: language,
                    modelName: client.modelName,
                    modelVersion: client.modelVersion,
                    promptHash: client.promptHash,
                    rawResponse: llmResult.rawResponse,
                    stage: "llm",
                    severity: llmResult.severity,
                    confidence: llmResult.confidence,
                    reasoning: llmResult.reasoning
                )
                annotation.post = post
                context.insert(annotation)
                post.needsReAnnotation = false
                processedCount += 1
            } catch {
                errorCount += 1
                lastLLMError = error.localizedDescription
                print("[AnnotationService] Failed to annotate post \(post.uri): \(error)")
            }
            try context.save()
        }
        currentPostText = ""
    }

    private func fetchPostsWithoutNLTaggerAnnotation(context: ModelContext) throws -> [Post] {
        let posts = try context.fetch(FetchDescriptor<Post>())
        return posts.filter { !$0.hasNLTaggerAnnotation }
    }

    private func fetchPostsWithoutLLMAnnotation(context: ModelContext, limit: Int) throws -> [Post] {
        var descriptor = FetchDescriptor<Post>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit * 5
        let posts = try context.fetch(descriptor)
        return posts
            .filter { !$0.hasLLMAnnotation }
            .prefix(limit)
            .map { $0 }
    }
}
