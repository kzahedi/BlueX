import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Classifies a Bluesky reply using Apple's on-device Foundation Models (~3B params,
/// runs entirely on the M-series Neural Engine). Available on macOS 26+ with Apple
/// Intelligence enabled.
///
/// Why this exists:
/// - The 27B Ollama models eat 16+ GB of unified memory; on a 32 GB Mac that crowds
///   out everything else and triggers swap. Apple's on-device model is roughly 2 GB
///   resident.
/// - `@Generable` enforces structured output natively, so we don't need the brittle
///   "respond with JSON only" prompt scaffolding the LLM-via-Ollama path uses.
///   Output is decoded straight into a Swift struct.
/// - It's free — no API key, no rate limit budget to manage.
///
/// Trade-off: at ~3B parameters the model is smaller than the 24-32B Ollama options.
/// For binary "is this hate or harsh political criticism" calls it's typically
/// sufficient, but it's worth A/B-ing against gemma3:4b on a stratified sample.
@available(macOS 26.0, *)
final class AppleFoundationModelClient: LocalModelClient {
    let modelName: String = "apple-foundation"
    let modelVersion: String
    let promptHash: String
    private let promptTemplate: String

    init(promptTemplate: String) throws {
        #if canImport(FoundationModels)
        // The default Apple Foundation Model has aggressive content guardrails — it
        // refuses to classify anything containing slurs, threats, or hateful language
        // and surfaces .guardrailViolation. For a hate-speech classifier that's a
        // total non-starter; the very inputs we need to label are the ones the model
        // refuses. Apple provides `.permissiveContentTransformations` on
        // `SystemLanguageModel.Guardrails` specifically for content-moderation /
        // research use cases — it lets the model PROCESS content with mature themes
        // (analyse, classify, summarise) while still refusing to GENERATE harmful
        // content. That's exactly the right semantics for us.
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        switch model.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw NSError(
                domain: "BlueX.AppleFoundation", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(reason)"]
            )
        @unknown default:
            throw NSError(
                domain: "BlueX.AppleFoundation", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "unknown availability state"]
            )
        }
        self.foundationModel = model
        #endif
        self.promptTemplate = promptTemplate
        self.modelVersion = "1.0-permissive"
        self.promptHash = ModelConfig.promptHash(of: promptTemplate)
    }

    #if canImport(FoundationModels)
    private let foundationModel: SystemLanguageModel
    #endif

    func classify(text: String, language: String) async throws -> LLMAnnotation {
        #if canImport(FoundationModels)
        // We feed the same prompt template the Ollama path uses, with one swap: the
        // explicit "respond with JSON, nothing else" tail is pointless for Foundation
        // Models because @Generable handles output formatting. We leave it in anyway
        // — the model ignores it and produces the structured output we ask for, and
        // keeping the template identical means promptHash matches the Ollama lineage
        // (useful for cross-model agreement studies).
        let prompt = promptTemplate
            .replacingOccurrences(of: "{{text}}", with: text)
            .replacingOccurrences(of: "{{language}}", with: language)

        let session = LanguageModelSession(model: foundationModel)
        let response = try await session.respond(
            to: prompt,
            generating: AppleClassification.self
        )
        let content = response.content

        let normalisedSeverity: String? = {
            let s = content.severity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return (s.isEmpty || s == "null" || s == "none") ? nil : content.severity
        }()
        let normalisedClass = content.classification.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let validClasses: Set<String> = ["hate", "counter", "neutral"]
        guard validClasses.contains(normalisedClass) else {
            throw NSError(
                domain: "BlueX.AppleFoundation", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "model returned invalid class '\(content.classification)'"]
            )
        }
        return LLMAnnotation(
            speechClass: normalisedClass,
            severity: normalisedSeverity,
            confidence: max(0, min(1, content.confidence)),
            reasoning: content.reasoning,
            rawResponse: String(describing: content)
        )
        #else
        throw NSError(
            domain: "BlueX.AppleFoundation", code: 99,
            userInfo: [NSLocalizedDescriptionKey: "FoundationModels framework not available at compile time"]
        )
        #endif
    }
}

#if canImport(FoundationModels)
/// Structured output schema. `@Generable` is the Foundation Models macro that turns a
/// Swift struct into a JSON schema the framework enforces on the model — the response
/// is guaranteed to decode, no extraction or balanced-brace scanning needed.
@available(macOS 26.0, *)
@Generable
struct AppleClassification {
    @Guide(description: "Exactly one of: hate, counter, neutral. Default to neutral when in doubt.")
    let classification: String

    @Guide(description: "Severity if class is hate: mild, moderate, or severe. Use the empty string for counter or neutral.")
    let severity: String

    @Guide(description: "Confidence in [0.0, 1.0]")
    let confidence: Double

    @Guide(description: "One-sentence justification for the class.")
    let reasoning: String
}
#endif
