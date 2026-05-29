import Foundation
import SwiftData
import CryptoKit

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

    /// SHA-256 of the prompt template. Used as the annotation's `promptHash` so the
    /// same model with two different prompts produces two distinct annotation lineages.
    static func promptHash(of template: String) -> String {
        let data = Data(template.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Convenience for this config's own prompt hash.
    var promptHash: String { Self.promptHash(of: promptTemplate) }

    // Research-grade prompt — structure adapted from the HICC three-class hate /
    // counter / neutral benchmark (Schmid et al., KONVENS 2025). Conjunctive hate
    // criteria (identity-based targeting AND dehumanization/harm-call) plus explicit
    // few-shot examples are the documented fix for 7B-and-up over-flagging of
    // political anger as hate.
    static let defaultPromptTemplate = """
    You are classifying ONE Bluesky reply for a research study on hate speech and counter speech.
    The reply is in {{language}} and may respond to a news post or to another reply.
    Be precise and conservative — most replies are NEUTRAL.

    CLASSES

    - "hate": REQUIRES BOTH
        (a) the reply targets a person or group based on race, ethnicity, religion, gender,
            sexual orientation, disability, immigration status, or another protected attribute, AND
        (b) the reply uses a slur, dehumanizing language, an explicit call for violence or
            harassment, OR a sustained pejorative attack tied to that identity.
      Both conditions must hold. Political criticism alone is NOT hate, no matter how harsh.

    - "counter": the reply pushes back against hateful content elsewhere in the thread —
      defends a targeted group, refutes or fact-checks hate, expresses solidarity with victims,
      or calls for civility specifically in response to hostility. Counter speech is directed
      at HATE, not at every political disagreement.

    - "neutral": everything else. Default to neutral when in doubt.

    EXAMPLES — NOT HATE (classify as "neutral")

    - "Trump weaponized the DOJ. They should be held accountable."          → political criticism
    - "This is disgusting and terrible."                                     → moral exasperation
    - "Diese Politik ist unverantwortlich und gehört vor Gericht."           → political criticism
    - "Yeah" / emoji-only replies                                            → not a substantive claim
    - "I disagree with that policy, it harms working families."              → mere disagreement

    EXAMPLES — HATE

    - "[slur] like them shouldn't be in this country."                       → slur + identity targeting
    - "Send them all back, they are vermin."                                 → dehumanization + identity
    - Sustained pejorative attack tied to a religion or sexual orientation

    EXAMPLES — COUNTER

    - "Calling immigrants 'invaders' is dehumanizing. They are people."       → refutes hate framing
    - "You're wrong about Muslims; here are the actual statistics."           → fact-checks hate
    - "Solidarität mit allen Betroffenen dieser Hetze."                       → solidarity with targets

    OUTPUT

    Respond with a SINGLE JSON object, nothing before or after:

    {
      "class":      "hate" | "counter" | "neutral",
      "severity":   "mild" | "moderate" | "severe" | null,
      "confidence": 0.0 to 1.0,
      "reasoning":  "<one short sentence justifying the class>"
    }

    severity MUST be JSON null (the literal null, NOT the string "null") for "counter" and "neutral".
    severity may also be null for "hate" if intensity is unclear.

    REPLY TEXT
    \"\"\"
    {{text}}
    \"\"\"
    """

    /// Prompt used by the LLM sentiment pass (`stage = "llm-sentiment"`). Distinct
    /// from the hate/counter/neutral prompt above: this one classifies emotional
    /// valence on a positive/neutral/negative scale and is explicitly tuned to
    /// catch the failure mode that broke NLTagger — contrastive replies that
    /// START with a positive cue but PIVOT to criticism. ("I've been a subscriber
    /// for 40 years but this article is full of shit" → must come back NEGATIVE.)
    /// Same {{text}} / {{language}} placeholders; same JSON output shape so it
    /// flows through LLMResponseParser unchanged.
    static let defaultSentimentPromptTemplate = """
    You are classifying ONE Bluesky reply for emotional valence (sentiment).
    The reply is in {{language}}. Read the WHOLE reply before deciding.

    CLASSES

    - "positive": the dominant emotion is approval, support, joy, gratitude, or
      appreciation. The reply as a whole leaves the reader feeling the author is
      pleased.

    - "negative": the dominant emotion is anger, frustration, contempt,
      disappointment, hostility, sarcasm, or strong criticism. CRUCIAL: replies
      that open with a positive frame and then pivot to a complaint, criticism,
      or insult are NEGATIVE — the criticism is what the author is actually
      communicating. Sarcastic praise is NEGATIVE.

    - "neutral": informational, asks a question, makes a factual observation,
      shares a link without comment, or expresses no clear emotional valence.
      Default to neutral when in doubt.

    EXAMPLES — NEGATIVE (do NOT mistake for positive)

    - "I've been a subscriber for 40 years but this article is full of shit."
        → mixed-frame contrast; criticism is the point. NEGATIVE.
    - "Great reporting, except every single fact is wrong."
        → sarcastic praise followed by undercut. NEGATIVE.
    - "Toller Artikel, der nichts erklärt und alles falsch macht."
        → German equivalent of the above pattern. NEGATIVE.

    EXAMPLES — POSITIVE

    - "Genuinely well-researched piece, thank you for this."         → straight praise
    - "Hervorragende Analyse, vielen Dank!"                          → straight praise

    EXAMPLES — NEUTRAL

    - "Where did this data come from?"                               → question
    - "Linking the source: [...]"                                    → informational
    - "Yep" / single emoji                                            → no substantive valence

    OUTPUT

    Respond with a SINGLE JSON object, nothing before or after:

    {
      "class":      "positive" | "neutral" | "negative",
      "confidence": 0.0 to 1.0,
      "reasoning":  "<one short sentence justifying the class>"
    }

    severity MUST be JSON null (this field is unused for sentiment).

    REPLY TEXT
    \"\"\"
    {{text}}
    \"\"\"
    """
}
