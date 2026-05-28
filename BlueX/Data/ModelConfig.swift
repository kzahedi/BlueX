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

    // Research-grade prompt — tightened with concrete criteria and explicit
    // non-examples after qwen2.5:7b kept flagging mere political anger as "hate".
    static let defaultPromptTemplate = """
    You are classifying ONE Bluesky reply for a research study on hate speech vs. counter speech. Be precise and conservative.

    Classify the reply into EXACTLY ONE of:
    - "hate": contains slurs, dehumanizing language, explicit calls for violence or harassment, or pejorative attacks targeting a person or group BASED ON race, ethnicity, religion, gender, sexual orientation, disability, immigration status, or other protected attributes.
    - "counter": directly responds to, challenges, refutes, or de-escalates hateful content — defends a targeted group, calls for civility, fact-checks hate, expresses solidarity with targets.
    - "neutral": none of the above. This is the DEFAULT class when you are uncertain.

    DO NOT classify as "hate":
    - mere disagreement, frustration, or anger toward public figures, institutions, parties, or policies
    - sarcasm, snark, or strong political opinion that does not target a protected group
    - "they should be held accountable" / "this is terrible" / "disgusting" without identity-based targeting
    - expressions of sadness, worry, moral concern, or exasperation

    For "hate" only, also pick severity: "mild" / "moderate" / "severe".
    For "counter" or "neutral", set severity to JSON null (literal null, NOT the string "null").

    Confidence: a number 0.0–1.0. Reasoning: one short sentence.

    Reply language: {{language}}
    Reply text:
    \"\"\"
    {{text}}
    \"\"\"

    Output a SINGLE JSON object only, nothing before or after:
    {"class": "hate" | "counter" | "neutral", "severity": "mild" | "moderate" | "severe" | null, "confidence": 0.0, "reasoning": "..."}
    """
}
