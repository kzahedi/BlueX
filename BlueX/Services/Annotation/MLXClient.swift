// BlueX/Services/Annotation/MLXClient.swift
import Foundation
import CryptoKit

struct MLXClient: LocalModelClient {
    let modelName: String
    let modelVersion: String
    let endpoint: String
    let promptTemplate: String
    private let session: URLSessionProtocol

    var promptHash: String { ModelConfig.promptHash(of: promptTemplate) }

    init(
        modelName: String,
        modelVersion: String = "local",
        endpoint: String = "http://localhost:8080",
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

        let body: [String: Any] = [
            "model": modelName,
            "messages": [["role": "user", "content": prompt]],
            "temperature": 0.1,
            "stream": false
        ]

        guard let url = URL(string: "\(endpoint)/v1/chat/completions"),
              let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            throw BlueskyError.networkError(underlying: "Invalid MLX endpoint: \(endpoint)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        request.timeoutInterval = 120

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw BlueskyError.networkError(underlying: "MLX server returned non-200 status")
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
            throw BlueskyError.decodingError(underlying: "Empty choices in MLX response")
        }

        return try LLMResponseParser.parse(content)
    }
}
