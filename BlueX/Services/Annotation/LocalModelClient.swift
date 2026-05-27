// BlueX/Services/Annotation/LocalModelClient.swift
import Foundation

protocol LocalModelClient {
    var modelName: String { get }
    var modelVersion: String { get }
    func classify(text: String, language: String) async throws -> LLMAnnotation
}

struct LLMAnnotation {
    let speechClass: String    // "hate" | "counter" | "neutral"
    let severity: String?      // non-nil only for hate
    let confidence: Double     // 0.0–1.0
    let reasoning: String?
    let rawResponse: String    // full JSON string for audit
}
