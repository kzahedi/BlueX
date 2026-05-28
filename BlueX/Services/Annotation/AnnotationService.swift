// BlueX/Services/Annotation/AnnotationService.swift
import Foundation
import SwiftData
import Observation

@Observable
final class AnnotationService {
    var isRunning: Bool = false
    var passLabel: String = ""        // e.g. "Apple sentiment" or "LLM · qwen2.5:7b"
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
        passLabel = "Apple sentiment"
        queueSize = 0
        processedCount = 0
        defer {
            isRunning = false
            passLabel = ""
        }

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

    /// Stops the in-flight runLLMPass (if any) at the next cancellation checkpoint.
    func cancel() {
        runningTask?.cancel()
    }

    private var runningTask: Task<Void, Error>?

    /// Continuously classifies every post that lacks an LLM annotation, until the queue
    /// is empty or `cancel()` is called. Runs on a detached Task with its own
    /// background ModelContext; saves every `saveEvery` posts; streams progress back
    /// to @Observable properties on the main actor.
    ///
    /// `saveEvery` is the transactional batch size, NOT a hard cap on the run. Each
    /// LLM call is one post; the save just bounds the in-memory annotation list and
    /// the SQLite transaction.
    @MainActor
    func runLLMPass(saveEvery: Int = 20) async throws {
        guard let client = activeClient else { return }

        isRunning = true
        passLabel = "LLM · \(client.modelName)"
        queueSize = 0
        processedCount = 0
        errorCount = 0
        lastLLMError = nil
        currentPostText = ""
        defer {
            isRunning = false
            passLabel = ""
            currentPostText = ""
            runningTask = nil
        }

        let container = modelContainer

        let stream = AsyncThrowingStream<LLMPassEvent, Error> { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let context = ModelContext(container)

                    // Estimate total. Approximation using Annotation count — fast and good
                    // enough for a progress bar; the true denominator drifts as work runs.
                    let totalPosts = try context.fetchCount(FetchDescriptor<Post>())
                    let llmAnnotated = try context.fetchCount(FetchDescriptor<Annotation>(
                        predicate: #Predicate { $0.stage == "llm" }
                    ))
                    let initialPending = max(0, totalPosts - llmAnnotated)
                    continuation.yield(.start(total: initialPending))

                    var processed = 0
                    var errors = 0

                    classifyLoop: while true {
                        try Task.checkCancellation()

                        // Fetch next batch (over-fetch then filter by hasLLMAnnotation)
                        var desc = FetchDescriptor<Post>(
                            sortBy: [SortDescriptor(\Post.createdAt, order: .reverse)]
                        )
                        desc.fetchLimit = saveEvery * 4
                        let candidates = try context.fetch(desc)
                        let batch = candidates.filter { !$0.hasLLMAnnotation }.prefix(saveEvery)
                        if batch.isEmpty { break classifyLoop }

                        for post in batch {
                            try Task.checkCancellation()
                            let baseline = post.nlTaggerAnnotation
                            let language = baseline?.detectedLanguage ?? "other"
                            let baselineSentiment = baseline?.sentimentScore ?? 0.0
                            let preview = String(post.text.prefix(60))
                            continuation.yield(.tick(processed: processed, currentText: preview, errors: errors))

                            do {
                                let llmResult = try await client.classify(text: post.text, language: language)
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
                                processed += 1
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                errors += 1
                                continuation.yield(.error(message: error.localizedDescription))
                            }
                        }
                        try context.save()
                        continuation.yield(.tick(processed: processed, currentText: "", errors: errors))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()  // graceful stop
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }

        // Track the parent task so cancel() can stop us from outside.
        runningTask = Task<Void, Error> {
            for try await event in stream {
                await MainActor.run {
                    switch event {
                    case .start(let total):
                        queueSize = total
                    case .tick(let p, let text, let e):
                        processedCount = p
                        errorCount = e
                        if !text.isEmpty { currentPostText = text }
                    case .error(let msg):
                        lastLLMError = msg
                    }
                }
            }
        }
        try await runningTask?.value
    }

    private enum LLMPassEvent: Sendable {
        case start(total: Int)
        case tick(processed: Int, currentText: String, errors: Int)
        case error(message: String)
    }

    private func fetchPostsWithoutNLTaggerAnnotation(context: ModelContext) throws -> [Post] {
        let posts = try context.fetch(FetchDescriptor<Post>())
        return posts.filter { !$0.hasNLTaggerAnnotation }
    }

}
