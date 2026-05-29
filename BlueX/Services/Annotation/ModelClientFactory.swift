import Foundation

/// Picks the right `LocalModelClient` for a given `ModelConfig`. Single dispatch
/// point shared by the GUI Queue, the CLI `blueX-annotate`, and the Settings
/// "Test connection" probe — new transports plug in here without touching
/// call sites.
///
/// The `endpoint` field is the dispatch key:
///
///   - `"apple-foundation"`           → `AppleFoundationModelClient` (macOS 26+)
///   - URL containing `cerebras.ai`   → `OpenAICompatibleClient` (= MLXClient)
///                                       with the Cerebras API key from Keychain
///                                       and a longer timeout
///   - URL containing `groq.com`,
///     `openrouter.ai`, `together.xyz` → `OpenAICompatibleClient` with their key
///   - anything else (typically a
///     localhost Ollama URL)          → `OllamaClient`
///
/// All sentiment-mode call sites override the prompt template (sentiment uses a
/// distinct prompt + class set) via the `promptOverride` / `validClasses`
/// parameters. The HICC classification pass uses the defaults.
enum ModelClientFactory {

    enum FactoryError: Error, LocalizedError {
        case appleFoundationUnavailable(reason: String)
        case missingAPIKey(provider: String)

        var errorDescription: String? {
            switch self {
            case .appleFoundationUnavailable(let reason):
                return "Apple Foundation Models not available: \(reason). Requires macOS 26+ with Apple Intelligence enabled."
            case .missingAPIKey(let provider):
                return "No API key found for '\(provider)'. Open BlueX → Settings → Credentials and paste the key from cloud.\(provider).ai (or the provider's console)."
            }
        }
    }

    /// Sentinel endpoint string for the Apple Foundation Models transport.
    static let appleFoundationEndpoint = "apple-foundation"
    /// Standard Cerebras Cloud OpenAI-compatible base URL.
    static let cerebrasEndpoint = "https://api.cerebras.ai"

    /// Original entry point — uses the ModelConfig's own prompt template and the
    /// hate/counter/neutral class set. Kept for backwards compatibility with the
    /// classification pass.
    static func make(from cfg: ModelConfig) throws -> any LocalModelClient {
        try make(from: cfg, promptOverride: nil, validClasses: LLMResponseParser.hateCounterNeutral)
    }

    /// Dispatch with explicit prompt + class-set overrides. Used by the sentiment
    /// pass (which uses a different prompt and the positive/neutral/negative set)
    /// and by the "Test connection" probe (which wants minimal output).
    static func make(from cfg: ModelConfig,
                     promptOverride: String?,
                     validClasses: Set<String>) throws -> any LocalModelClient {
        let prompt = promptOverride ?? cfg.promptTemplate

        // 1) Apple on-device
        if cfg.endpoint == appleFoundationEndpoint {
            if #available(macOS 26.0, *) {
                return try AppleFoundationModelClient(promptTemplate: prompt)
            } else {
                throw FactoryError.appleFoundationUnavailable(reason: "this macOS is older than 26.0")
            }
        }

        // 2) Cloud OpenAI-compatible (Cerebras / Groq / OpenRouter / Together) —
        //    requires an API key, looked up in Keychain per provider.
        if let provider = KeychainAPIKey.provider(forEndpoint: cfg.endpoint) {
            guard let apiKey = KeychainAPIKey.load(provider: provider) else {
                throw FactoryError.missingAPIKey(provider: provider)
            }
            // Hosted free-tier providers can have cold-start latency; bump the
            // timeout. Local MLX/LM Studio stays at the default 120 s.
            return MLXClient(
                modelName: cfg.modelID,
                modelVersion: provider,
                endpoint: cfg.endpoint,
                promptTemplate: prompt,
                apiKey: apiKey,
                validClasses: validClasses,
                timeoutSeconds: 180
            )
        }

        // 3) Default — Ollama (or any other unauthenticated localhost LLM)
        return OllamaClient(
            modelName: cfg.modelID,
            endpoint: cfg.endpoint,
            promptTemplate: prompt,
            validClasses: validClasses
        )
    }
}
