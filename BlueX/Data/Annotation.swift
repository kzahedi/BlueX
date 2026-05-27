import Foundation
import SwiftData

@Model
final class Annotation {
    // Classification (matching founding paper schema)
    var speechClass: String      // "hate" | "counter" | "neutral"
    var severity: String?        // "mild" | "moderate" | "severe" — hate only
    var confidence: Double       // 0.0–1.0

    // Baseline (NLTagger)
    var sentimentScore: Double   // -1.0 to +1.0
    var detectedLanguage: String // "de" | "en" | "other"

    // Reproducibility
    var modelName: String        // e.g. "llama3.2" | "apple-nltagger"
    var modelVersion: String
    var promptHash: String       // SHA256 of prompt template used
    var rawResponse: String      // full LLM output, always stored
    var stage: String            // "nltagger" | "llm"
    var reasoning: String?       // LLM explanation

    var createdAt: Date
    @Relationship(deleteRule: .nullify) var post: Post?

    init(speechClass: String, sentimentScore: Double, detectedLanguage: String,
         modelName: String, modelVersion: String, promptHash: String,
         rawResponse: String, stage: String,
         severity: String? = nil, confidence: Double = 0.0, reasoning: String? = nil) {
        self.speechClass = speechClass
        self.sentimentScore = sentimentScore
        self.detectedLanguage = detectedLanguage
        self.modelName = modelName
        self.modelVersion = modelVersion
        self.promptHash = promptHash
        self.rawResponse = rawResponse
        self.stage = stage
        self.severity = severity
        self.confidence = confidence
        self.reasoning = reasoning
        self.createdAt = Date()
    }
}
