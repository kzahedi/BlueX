// BlueX/Services/Annotation/OllamaClient.swift
import Foundation
import CryptoKit

struct OllamaClient: LocalModelClient {
    let modelName: String
    let modelVersion: String
    let endpoint: String
    let promptTemplate: String
    /// Which class label set the parser should validate against. Defaults to the
    /// hate/counter/neutral set used by the LLM classification pass; the LLM
    /// sentiment pass overrides this with positive/neutral/negative.
    let validClasses: Set<String>
    private let session: URLSessionProtocol

    var promptHash: String { ModelConfig.promptHash(of: promptTemplate) }

    init(
        modelName: String,
        modelVersion: String = "latest",
        endpoint: String = "http://localhost:11434",
        promptTemplate: String = ModelConfig.defaultPromptTemplate,
        validClasses: Set<String> = LLMResponseParser.hateCounterNeutral,
        session: URLSessionProtocol = URLSession.shared
    ) {
        self.modelName = modelName
        self.modelVersion = modelVersion
        self.endpoint = endpoint
        self.promptTemplate = promptTemplate
        self.validClasses = validClasses
        self.session = session
    }

    func classify(text: String, language: String) async throws -> LLMAnnotation {
        let prompt = promptTemplate
            .replacingOccurrences(of: "{{text}}", with: text)
            .replacingOccurrences(of: "{{language}}", with: language)

        let body: [String: Any] = ["model": modelName, "prompt": prompt, "stream": false]

        guard let url = URL(string: "\(endpoint)/api/generate"),
              let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            throw BlueskyError.networkError(underlying: "Invalid Ollama endpoint: \(endpoint)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        request.timeoutInterval = 60

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw BlueskyError.networkError(underlying: "Ollama returned non-200 status")
        }

        struct OllamaResponse: Codable { let response: String }
        let ollamaResponse = try JSONDecoder().decode(OllamaResponse.self, from: data)
        return try parseLLMResponse(ollamaResponse.response)
    }

    // Internal for testing — delegates to shared LLMResponseParser
    func parseLLMResponse(_ raw: String) throws -> LLMAnnotation {
        return try LLMResponseParser.parse(raw, validClasses: validClasses)
    }
}
