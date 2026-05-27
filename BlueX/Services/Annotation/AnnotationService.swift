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

    func runLLMPass(batchSize: Int = 10) async throws {
        guard let client = activeClient else { return }

        isRunning = true
        defer { isRunning = false }

        let context = ModelContext(modelContainer)
        let posts = try fetchPostsWithoutLLMAnnotation(context: context, limit: batchSize)
        queueSize = posts.count

        for post in posts {
            currentPostText = String(post.text.prefix(60))

            let language = post.annotations
                .first(where: { $0.stage == "nltagger" })?
                .detectedLanguage ?? "other"

            do {
                let llmResult = try await client.classify(text: post.text, language: language)
                let baselineSentiment = post.annotations
                    .first(where: { $0.stage == "nltagger" })?.sentimentScore ?? 0.0

                let promptHashValue: String
                if let ollamaClient = client as? OllamaClient {
                    promptHashValue = ollamaClient.promptHash
                } else if let mlxClient = client as? MLXClient {
                    promptHashValue = mlxClient.promptHash
                } else {
                    promptHashValue = ""
                }

                let annotation = Annotation(
                    speechClass: llmResult.speechClass,
                    sentimentScore: baselineSentiment,
                    detectedLanguage: language,
                    modelName: client.modelName,
                    modelVersion: client.modelVersion,
                    promptHash: promptHashValue,
                    rawResponse: llmResult.rawResponse,
                    stage: "llm",
                    severity: llmResult.severity,
                    confidence: llmResult.confidence,
                    reasoning: llmResult.reasoning
                )
                context.insert(annotation)
                annotation.post = post
                post.needsReAnnotation = false
                processedCount += 1

            } catch {
                print("[AnnotationService] Failed to annotate post \(post.uri): \(error)")
            }

            try context.save()
        }

        currentPostText = ""
    }

    private func fetchPostsWithoutNLTaggerAnnotation(context: ModelContext) throws -> [Post] {
        let posts = try context.fetch(FetchDescriptor<Post>())
        return posts.filter { post in
            !post.annotations.contains { $0.stage == "nltagger" }
        }
    }

    private func fetchPostsWithoutLLMAnnotation(context: ModelContext, limit: Int) throws -> [Post] {
        var descriptor = FetchDescriptor<Post>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit * 5
        let posts = try context.fetch(descriptor)
        return posts
            .filter { !$0.annotations.contains { $0.stage == "llm" } }
            .prefix(limit)
            .map { $0 }
    }
}
