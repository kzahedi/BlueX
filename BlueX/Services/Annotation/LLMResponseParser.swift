// BlueX/Services/Annotation/LLMResponseParser.swift
import Foundation

// Why: Both OllamaClient and MLXClient use identical JSON parsing logic.
// A shared static function avoids duplication and cross-client coupling.
enum LLMResponseParser {
    /// Class sets vary by pass:
    ///   - HICC hate/counter classification: hate / counter / neutral
    ///   - Sentiment classification:         positive / neutral / negative
    /// The parser is otherwise identical (same JSON shape, same brace-balanced
    /// extraction, same severity normalisation). Defaults to the HICC set for
    /// backwards compatibility with the original LLM annotation pass.
    static let hateCounterNeutral: Set<String> = ["hate", "counter", "neutral"]
    static let positiveNeutralNegative: Set<String> = ["positive", "neutral", "negative"]

    static func parse(_ raw: String,
                      validClasses: Set<String> = hateCounterNeutral) throws -> LLMAnnotation {
        guard let jsonString = extractBalancedJSONObject(from: raw) else {
            throw BlueskyError.decodingError(underlying: "No JSON object found in: \(raw)")
        }

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

        guard validClasses.contains(decoded.class) else {
            throw BlueskyError.decodingError(
                underlying: "Invalid class '\(decoded.class)' (expected one of \(validClasses.sorted().joined(separator: ", ")))"
            )
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

    /// Scans `raw` left-to-right and returns the first balanced JSON object substring.
    /// Tracks string literals (handling `\"` escapes) so braces inside strings don't
    /// throw off the depth count. The earlier first-`{` / last-`}` approach went wrong
    /// when models prepended reasoning containing `{...}` or wrapped the JSON in
    /// ```json fences with a trailing brace from a different structure.
    static func extractBalancedJSONObject(from raw: String) -> String? {
        var depth = 0
        var startIdx: String.Index?
        var inString = false
        var prevWasBackslash = false

        var i = raw.startIndex
        while i < raw.endIndex {
            let ch = raw[i]
            if inString {
                if prevWasBackslash {
                    prevWasBackslash = false
                } else if ch == "\\" {
                    prevWasBackslash = true
                } else if ch == "\"" {
                    inString = false
                }
            } else {
                switch ch {
                case "\"":
                    inString = true
                case "{":
                    if depth == 0 { startIdx = i }
                    depth += 1
                case "}":
                    depth -= 1
                    if depth == 0, let start = startIdx {
                        return String(raw[start...i])
                    }
                    if depth < 0 {
                        // Stray closing brace before any open — reset.
                        depth = 0
                        startIdx = nil
                    }
                default:
                    break
                }
            }
            i = raw.index(after: i)
        }
        return nil
    }
}
