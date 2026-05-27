import Foundation
import SwiftData

@Model
final class ModelConfig {
    var name: String
    var endpoint: String        // e.g. "http://localhost:11434"
    var modelID: String         // e.g. "llama3.2"
    var promptTemplate: String  // contains {{text}} and {{language}} placeholders
    var isDefault: Bool
    var createdAt: Date

    init(name: String, endpoint: String, modelID: String,
         promptTemplate: String, isDefault: Bool = false) {
        self.name = name
        self.endpoint = endpoint
        self.modelID = modelID
        self.promptTemplate = promptTemplate
        self.isDefault = isDefault
        self.createdAt = Date()
    }

    // The research-grade default prompt matching the founding paper's three-class schema
    static let defaultPromptTemplate = """
    You are a research assistant classifying social media replies for a study on hate speech and counter speech.

    Reply language: {{language}}
    Reply text: {{text}}

    Classify this reply as exactly ONE of:
    - hate: hateful rhetoric targeting groups, individuals, or identities
    - counter: counter speech that responds to, challenges, or de-escalates hate
    - neutral: neither hate nor counter speech

    If hate, also rate severity: mild / moderate / severe

    Respond in JSON only, no explanation outside the JSON:
    {
      "class": "hate | counter | neutral",
      "severity": "mild | moderate | severe | null",
      "confidence": 0.0-1.0,
      "reasoning": "one sentence"
    }
    """
}
