// BlueX/Services/Annotation/MLXClient.swift
import Foundation
import CryptoKit

/// OpenAI-compatible chat-completions client. Despite the filename, this is the
/// transport for ANY endpoint that speaks `/v1/chat/completions` — a local MLX
/// server, LM Studio, Cerebras Cloud, Groq, OpenRouter, Together.ai, etc. The
/// `OpenAICompatibleClient` typealias points here.
///
/// Per-endpoint behaviour is controlled at construction time, not by the class:
///   - localhost (MLX / LM Studio): omit `apiKey`, default timeout
///   - hosted (Cerebras / Groq / …): pass `apiKey`; the factory pulls it from
///     Keychain and attaches it as a Bearer token. Cerebras' `/v1` endpoint
///     also recommends a longer timeout because cold-start can stretch into
///     the 30-60 s range on shared free-tier capacity.
struct MLXClient: LocalModelClient {
    let modelName: String
    let modelVersion: String
    let endpoint: String
    let promptTemplate: String
    /// Bearer token. nil for endpoints that don't require auth (local MLX/LM Studio).
    let apiKey: String?
    /// Which class label set the parser validates against. Defaults to the
    /// hate/counter/neutral set; the sentiment pass overrides with
    /// positive/neutral/negative.
    let validClasses: Set<String>
    /// Per-request timeout. Hosted free-tier providers (Cerebras) need more
    /// headroom than localhost (which usually responds in 1-5 s).
    let timeoutSeconds: TimeInterval
    private let session: URLSessionProtocol

    var promptHash: String { ModelConfig.promptHash(of: promptTemplate) }

    init(
        modelName: String,
        modelVersion: String = "local",
        endpoint: String = "http://localhost:8080",
        promptTemplate: String = ModelConfig.defaultPromptTemplate,
        apiKey: String? = nil,
        validClasses: Set<String> = LLMResponseParser.hateCounterNeutral,
        timeoutSeconds: TimeInterval = 120,
        session: URLSessionProtocol = URLSession.shared
    ) {
        self.modelName = modelName
        self.modelVersion = modelVersion
        self.endpoint = endpoint
        self.promptTemplate = promptTemplate
        self.apiKey = apiKey
        self.validClasses = validClasses
        self.timeoutSeconds = timeoutSeconds
        self.session = session
    }

    func classify(text: String, language: String) async throws -> LLMAnnotation {
        let prompt = promptTemplate
            .replacingOccurrences(of: "{{text}}", with: text)
            .replacingOccurrences(of: "{{language}}", with: language)

        let body: [String: Any] = [
            "model": modelName,
            "messages": [["role": "user", "content": prompt]],
            "temperature": 0.1,
            "stream": false
        ]

        guard let url = URL(string: "\(endpoint)/v1/chat/completions"),
              let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            throw BlueskyError.networkError(underlying: "Invalid endpoint: \(endpoint)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = bodyData
        request.timeoutInterval = timeoutSeconds

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw BlueskyError.networkError(underlying: "Non-HTTP response")
        }
        // Surface auth / rate-limit failures with their actual codes so the caller
        // can decide whether to retry or escalate. Cerebras returns 401 for bad
        // keys, 429 for rate-limit hit, 5xx for transient capacity errors.
        switch http.statusCode {
        case 200...299:
            break
        case 401, 403:
            throw BlueskyError.authFailed
        case 429:
            let retry = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "60") ?? 60
            throw BlueskyError.rateLimited(retryAfter: retry)
        case 400:
            let body = String(data: data, encoding: .utf8) ?? "<unparseable>"
            throw BlueskyError.badRequest(message: body)
        default:
            throw BlueskyError.networkError(underlying: "HTTP \(http.statusCode)")
        }

        struct ChatResponse: Codable {
            struct Choice: Codable {
                struct Message: Codable { let content: String }
                let message: Message
            }
            let choices: [Choice]
        }

        let chatResponse = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = chatResponse.choices.first?.message.content else {
            throw BlueskyError.decodingError(underlying: "Empty choices in chat response")
        }
        return try LLMResponseParser.parse(content, validClasses: validClasses)
    }
}
