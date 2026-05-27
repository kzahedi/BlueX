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

    @MainActor
    func runNLTaggerPass() async throws {
        let context = modelContainer.mainContext
        let posts = try fetchPostsWithoutNLTaggerAnnotation(context: context)
        queueSize = posts.count

        for post in posts {
            let annotation = nlTagger.analyse(text: post.text)
            context.insert(annotation)
            annotation.post = post
            processedCount += 1
        }
        try context.save()
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
