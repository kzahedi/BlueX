// BlueX/Services/Annotation/OllamaClient.swift
import Foundation
import CryptoKit

struct OllamaClient: LocalModelClient {
    let modelName: String
    let modelVersion: String
    let endpoint: String
    let promptTemplate: String
    private let session: URLSessionProtocol

    var promptHash: String {
        let data = Data(promptTemplate.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    init(
        modelName: String,
        modelVersion: String = "latest",
        endpoint: String = "http://localhost:11434",
        promptTemplate: String = ModelConfig.defaultPromptTemplate,
        session: URLSessionProtocol = URLSession.shared
    ) {
        self.modelName = modelName
        self.modelVersion = modelVersion
        self.endpoint = endpoint
        self.promptTemplate = promptTemplate
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

    // Internal for testing
    func parseLLMResponse(_ raw: String) throws -> LLMAnnotation {
        guard let jsonStart = raw.range(of: "{"),
              let jsonEnd = raw.range(of: "}", options: .backwards) else {
            throw BlueskyError.decodingError(underlying: "No JSON object found in: \(raw)")
        }
        let jsonString = String(raw[jsonStart.lowerBound...jsonEnd.upperBound])

        struct LLMResponse: Codable {
            let `class`: String
            let severity: String?
            let confidence: Double
            let reasoning: String?
        }

        guard let jsonData = jsonString.data(using: .utf8) else {
            throw BlueskyError.decodingError(underlying: "Could not encode JSON string")
        }

        let decoded: LLMResponse
        do {
            decoded = try JSONDecoder().decode(LLMResponse.self, from: jsonData)
        } catch {
            throw BlueskyError.decodingError(underlying: "JSON parse failed: \(error.localizedDescription)")
        }

        let validClasses = ["hate", "counter", "neutral"]
        guard validClasses.contains(decoded.class) else {
            throw BlueskyError.decodingError(underlying: "Invalid class '\(decoded.class)'")
        }

        return LLMAnnotation(
            speechClass: decoded.class,
            severity: decoded.severity,
            confidence: max(0.0, min(1.0, decoded.confidence)),
            reasoning: decoded.reasoning,
            rawResponse: raw
        )
    }
}
