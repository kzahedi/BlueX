// BlueX/Services/Annotation/LLMResponseParser.swift
import Foundation

// Why: Both OllamaClient and MLXClient use identical JSON parsing logic.
// A shared static function avoids duplication and cross-client coupling.
enum LLMResponseParser {
    static func parse(_ raw: String) throws -> LLMAnnotation {
        guard let jsonStart = raw.range(of: "{"),
              let jsonEnd = raw.range(of: "}", options: .backwards) else {
            throw BlueskyError.decodingError(underlying: "No JSON object found in: \(raw)")
        }
        let jsonString = String(raw[jsonStart.lowerBound...jsonEnd.lowerBound])

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

        // Some models emit the literal string "null" or empty string for severity
        // when the post isn't hate. Normalise to nil.
        let severity: String? = {
            guard let s = decoded.severity else { return nil }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return (trimmed.isEmpty || trimmed == "null") ? nil : s
        }()
        return LLMAnnotation(
            speechClass: decoded.class,
            severity: severity,
            confidence: max(0.0, min(1.0, decoded.confidence)),
            reasoning: decoded.reasoning,
            rawResponse: raw
        )
    }
}
