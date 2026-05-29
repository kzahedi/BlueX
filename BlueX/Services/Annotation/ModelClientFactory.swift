import Foundation

/// Picks the right `LocalModelClient` for a given `ModelConfig`. Both the GUI's
/// Annotation Queue and the `blueX-annotate` CLI used to construct `OllamaClient`
/// inline at every call site — fine while there was one transport, but it pinned
/// every config to a localhost Ollama port even though some configs (Apple
/// Foundation Models, future MLX, hosted Cerebras) need entirely different runners.
///
/// The `endpoint` field is the dispatch key:
///
///   - `"apple-foundation"` → `AppleFoundationModelClient` (on-device, macOS 26+)
///   - anything else (typically `"http://…:11434"`) → `OllamaClient`
///
/// New transports (MLX server, hosted free tiers, HF Transformers via
/// swift-transformers) plug in here without touching call sites.
enum ModelClientFactory {

    enum FactoryError: Error, LocalizedError {
        case appleFoundationUnavailable(reason: String)

        var errorDescription: String? {
            switch self {
            case .appleFoundationUnavailable(let reason):
                return "Apple Foundation Models not available: \(reason). Requires macOS 26+ with Apple Intelligence enabled."
            }
        }
    }

    /// Sentinel endpoint string for the Apple Foundation Models transport. Stored in
    /// `ModelConfig.endpoint` so the same dispatch works from GUI and CLI.
    static let appleFoundationEndpoint = "apple-foundation"

    static func make(from cfg: ModelConfig) throws -> any LocalModelClient {
        if cfg.endpoint == appleFoundationEndpoint {
            if #available(macOS 26.0, *) {
                return try AppleFoundationModelClient(promptTemplate: cfg.promptTemplate)
            } else {
                throw FactoryError.appleFoundationUnavailable(reason: "this macOS is older than 26.0")
            }
        }
        return OllamaClient(
            modelName: cfg.modelID,
            endpoint: cfg.endpoint,
            promptTemplate: cfg.promptTemplate
        )
    }
}
