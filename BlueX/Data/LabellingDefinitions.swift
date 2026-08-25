import Foundation

/// Single source of truth for what the labelling classes mean, mirrored verbatim from
/// `docs/labelling/definitions.md` (the actual canonical document, quoting Garland,
/// Ghazi-Zahedi, Young, Hébert-Dufresne and Galesic, *Countering hate on social media:
/// large scale classification of hate and counter speech*, arXiv:2006.01974, §2.1).
///
/// This enum is embedded in three places that must never silently drift apart: the
/// labelling interface (`LabellingSessionView`'s reference panel), every LLM
/// classification prompt (`ModelConfig.defaultPromptTemplate`), and the per-annotation
/// `definitionVersion` recorded by `LabellingViewModel.record`.
///
/// **Do not paraphrase, reword, shorten or "improve" any string here.** Every quoted
/// sentence and bullet below must appear character-for-character in the markdown file —
/// `LabellingDefinitionsTests` reads that file at test time and fails the build if
/// they diverge. Wording changes belong in the markdown first, this file second.
enum LabellingDefinitions {
    /// Bumped whenever the definitions themselves change. Recorded per annotation as
    /// `Annotation.definitionVersion` so an analysis can group by, and never silently
    /// pool across, definition versions.
    static let version = 1

    struct ClassDefinition {
        /// The labelling-interface key: 1/2/3 for hate/counter/neutral, 0 for skip.
        let key: Int
        let name: String
        /// Verbatim core definition sentence(s), quoted from the paper where the class
        /// itself derives from a direct quotation (hate, counter); the paper's own prose
        /// for neutral and skip, which it does not quote a source for.
        let definition: String
        /// Verbatim "not this class" bullets from the markdown's "Not X under this
        /// definition" lists. Empty for classes the document gives no such list for
        /// (neutral, skip).
        let notThis: [String]
    }

    static let hate = ClassDefinition(
        key: 1,
        name: "hate",
        definition: """
        "insults, discrimination, or intimidation of individuals or groups on the
        Internet, on the grounds of their supposed race, ethnic origin, gender,
        religion, or political beliefs"
        """,
        notThis: [
            "Insults with no protected-group basis (\"you fucking idiot\", \"grifting piece of shit\") — these are incivility, and the corpus has a separate measure for it.",
            "Anger at an institution, outlet, party or politician as an actor rather than as a member of a group.",
            "Discussing hate, quoting it, or reporting on it (\"racism in Japan is subtle…\", a news summary about femicide).",
            "Harsh criticism, contempt or ridicule that does not invoke a protected attribute.",
        ]
    )

    static let counter = ClassDefinition(
        key: 2,
        name: "counter",
        definition: """
        "a citizen generated response to online hate in order to stop and prevent the
        spread of hate speech, and if possible change perpetrators' attitudes about
        their victims."
        """,
        notThis: [
            "Disagreeing with the article, the outlet, or a politician.",
            "Arguing against a factual claim.",
            "General pro-social or pro-tolerance sentiment posted into a thread that contains no hate.",
            "Attacking someone who is being obnoxious but not hateful.",
        ]
    )

    static let neutral = ClassDefinition(
        key: 3,
        name: "neutral",
        definition: """
        Everything else — including uncivil, rude, sarcastic, aggressive or unpleasant
        posts that meet neither definition above. Neutral is not "polite". Most of
        the corpus is neutral.
        """,
        notThis: []
    )

    static let skip = ClassDefinition(
        key: 0,
        name: "skip",
        definition: """
        Genuinely undecidable for you, on this text — missing context, unclear
        referent, unfamiliar language. A skip is recorded and revisitable. Prefer a skip
        over a coin-flip: a guessed label silently corrupts the prevalence estimate,
        whereas a skip is visible in the reporting.
        """,
        notThis: []
    )

    /// Order matches the labelling interface's key bindings: 1, 2, 3, 0.
    static let all: [ClassDefinition] = [hate, counter, neutral, skip]

    /// Verbatim, from the markdown's "Notes on applying these" section — shown
    /// alongside the four class definitions in the reference panel.
    static let applyingNotes: [String] = [
        "Judge the reply, using the parent and root only as context. The question is what this post does, not what the thread is about.",
        "The target test for hate: can you name the group being attacked, and is it attacked because of the protected attribute? If not, it is very likely neutral (or incivility).",
        "The hate test for counter: can you point at the hate it responds to? If not, it is not counter speech.",
    ]

    /// A short reasoning line each LLM prompt (`ModelConfig.defaultPromptTemplate`) is
    /// built against — combines the two conjunctive tests above into the same wording
    /// used for the human interface, so an automatic label is judged against the same
    /// criteria as a human one.
    static var promptSummary: String {
        var lines: [String] = []
        lines.append("CANONICAL DEFINITIONS (definitionVersion \(version), from Garland et al. 2020, §2.1 — quoted verbatim, do not reinterpret):")
        lines.append("")
        lines.append("hate: \(hate.definition)")
        for bullet in hate.notThis {
            lines.append("  NOT hate: \(bullet)")
        }
        lines.append("")
        lines.append("counter: \(counter.definition)")
        for bullet in counter.notThis {
            lines.append("  NOT counter: \(bullet)")
        }
        lines.append("")
        lines.append("neutral: \(neutral.definition)")
        lines.append("")
        for note in applyingNotes {
            lines.append("Note: \(note)")
        }
        return lines.joined(separator: "\n")
    }
}
