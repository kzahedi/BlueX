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
    /// Estimated seconds remaining, computed from the per-post running average since
    /// the current pass started. nil before the first post completes.
    var etaSeconds: Double? = nil
    /// Latest sampled thermal state during the current pass; drives the cool-down
    /// back-off and a UI badge when the system is hot.
    var thermalState: ProcessInfo.ThermalState = .nominal

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
        etaSeconds = nil
        defer {
            isRunning = false
            passLabel = ""
            etaSeconds = nil
        }

        // Capture only Sendable values for the detached task — @Model instances are
        // confined to the context where they were fetched and must not escape.
        let container = modelContainer
        let tagger = nlTagger

        let stream = AsyncThrowingStream<(Int, Int, Double?), Error> { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    let context = ModelContext(container)
                    let pending = try context.fetch(FetchDescriptor<Post>())
                        .filter { !$0.hasNLTaggerAnnotation }
                    let total = pending.count
                    continuation.yield((0, total, nil))

                    let runStart = Date()
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
                        let eta = Self.etaFromRunningAverage(start: runStart, processed: processed, total: total)
                        continuation.yield((processed, total, eta))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }

        for try await (processed, total, eta) in stream {
            queueSize = total
            processedCount = processed
            etaSeconds = eta
        }
    }

    /// Linear ETA from the running per-post average since the current pass started.
    /// nil until at least one post has been processed.
    private static func etaFromRunningAverage(start: Date, processed: Int, total: Int) -> Double? {
        guard processed > 0, processed < total else { return nil }
        let elapsed = Date().timeIntervalSince(start)
        let avg = elapsed / Double(processed)
        return avg * Double(total - processed)
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
    ///
    /// `stage` is the annotation stage tag written for each post and also the filter
    /// for the "already done" pending set — so the sentiment pass (stage =
    /// "llm-sentiment") doesn't trip over annotations from the hate/counter pass
    /// (stage = "llm") and vice versa. Each (post, modelName, stage) is annotated
    /// at most once.
    ///
    /// `signedSentimentScore` controls how the `sentimentScore` field is filled:
    /// false (default) → preserve the NLTagger baseline; true → derive from the
    /// LLM's class label (positive → +confidence, negative → −confidence, else 0).
    /// The latter is for the LLM-sentiment pass where the model's own emission is
    /// what we want plotted.
    @MainActor
    func runLLMPass(saveEvery: Int = 20, pace: LLMPace = .steady,
                    stage: String = "llm", signedSentimentScore: Bool = false) async throws {
        guard let client = activeClient else { return }

        isRunning = true
        passLabel = (stage == "llm-sentiment" ? "LLM sentiment · " : "LLM · ") + client.modelName
        queueSize = 0
        processedCount = 0
        errorCount = 0
        lastLLMError = nil
        currentPostText = ""
        etaSeconds = nil
        thermalState = .nominal
        defer {
            isRunning = false
            passLabel = ""
            currentPostText = ""
            etaSeconds = nil
            thermalState = .nominal
            runningTask = nil
        }

        let container = modelContainer

        let stream = AsyncThrowingStream<LLMPassEvent, Error> { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let context = ModelContext(container)

                    // Build the pending set once, scoped to THIS run's (stage, model).
                    // A post is "done" once this stage+model has any annotation for it
                    // — we never re-classify the same post with the same stage+model,
                    // even if the prompt template has been revised since. Annotations
                    // from OTHER stages/models are preserved untouched so cross-pass
                    // comparison still works.
                    let currentModelName = client.modelName
                    let currentStage = stage
                    let matchingAnnotations = try context.fetch(FetchDescriptor<Annotation>(
                        predicate: #Predicate {
                            $0.stage == currentStage && $0.modelName == currentModelName
                        }
                    ))
                    let alreadyClassifiedURIs = Set(matchingAnnotations.compactMap { $0.post?.uri })

                    // Prefetch annotations so per-post baseline lookups don't trigger
                    // a relationship fault per post inside the loop.
                    var allDesc = FetchDescriptor<Post>(
                        sortBy: [SortDescriptor(\Post.createdAt, order: .reverse)]
                    )
                    allDesc.relationshipKeyPathsForPrefetching = [\.annotations]
                    let allPosts = try context.fetch(allDesc)
                    let pending = allPosts.filter { !alreadyClassifiedURIs.contains($0.uri) }

                    let total = pending.count
                    continuation.yield(.start(total: total))
                    guard total > 0 else { continuation.finish(); return }

                    var processed = 0
                    var errors = 0
                    let runStart = Date()

                    var chunkStart = 0
                    while chunkStart < total {
                        try Task.checkCancellation()
                        let chunkEnd = min(chunkStart + saveEvery, total)
                        for i in chunkStart..<chunkEnd {
                            try Task.checkCancellation()
                            let post = pending[i]
                            let baseline = post.nlTaggerAnnotation
                            let language = baseline?.detectedLanguage ?? "other"
                            let baselineSentiment = baseline?.sentimentScore ?? 0.0
                            let preview = String(post.text.prefix(60))
                            let eta = Self.etaFromRunningAverage(start: runStart, processed: processed, total: total)
                            let thermal = ProcessInfo.processInfo.thermalState
                            continuation.yield(.tick(processed: processed, currentText: preview, errors: errors, etaSeconds: eta, thermal: thermal))

                            do {
                                let llmResult = try await client.classify(text: post.text, language: language)
                                // For sentiment passes, the LLM's class label becomes a signed
                                // score (-conf..+conf) so charts can plot it directly. For the
                                // hate/counter pass we keep the NLTagger baseline since it
                                // carries the actual sentiment polarity.
                                let scoreToStore: Double
                                if signedSentimentScore {
                                    switch llmResult.speechClass {
                                    case "positive": scoreToStore = llmResult.confidence
                                    case "negative": scoreToStore = -llmResult.confidence
                                    default:         scoreToStore = 0.0
                                    }
                                } else {
                                    scoreToStore = baselineSentiment
                                }
                                let annotation = Annotation(
                                    speechClass: llmResult.speechClass,
                                    sentimentScore: scoreToStore,
                                    detectedLanguage: language,
                                    modelName: client.modelName,
                                    modelVersion: client.modelVersion,
                                    promptHash: client.promptHash,
                                    rawResponse: llmResult.rawResponse,
                                    stage: currentStage,
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

                            // Pace + thermal back-off between posts. Sleep is
                            // interruptible by Task.cancel(), so Stop stays snappy.
                            let cooldownThermal = ProcessInfo.processInfo.thermalState
                            let cooldownNs = pace.baseDelayNanoseconds + ThermalBackoff.extraDelayNanoseconds(for: cooldownThermal)
                            if cooldownNs > 0 {
                                try await Task.sleep(nanoseconds: cooldownNs)
                            }
                        }
                        try context.save()
                        let eta = Self.etaFromRunningAverage(start: runStart, processed: processed, total: total)
                        let thermal = ProcessInfo.processInfo.thermalState
                        continuation.yield(.tick(processed: processed, currentText: "", errors: errors, etaSeconds: eta, thermal: thermal))
                        chunkStart = chunkEnd
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
                    case .tick(let p, let text, let e, let eta, let thermal):
                        processedCount = p
                        errorCount = e
                        etaSeconds = eta
                        thermalState = thermal
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
        case tick(processed: Int, currentText: String, errors: Int, etaSeconds: Double?, thermal: ProcessInfo.ThermalState)
        case error(message: String)
    }

    private func fetchPostsWithoutNLTaggerAnnotation(context: ModelContext) throws -> [Post] {
        let posts = try context.fetch(FetchDescriptor<Post>())
        return posts.filter { !$0.hasNLTaggerAnnotation }
    }

}
