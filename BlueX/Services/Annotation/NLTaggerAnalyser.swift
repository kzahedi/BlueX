// BlueX/Services/Annotation/NLTaggerAnalyser.swift
import Foundation
import NaturalLanguage

struct NLTaggerAnalyser {
    static let modelVersion = "apple-nltagger-2024"
    static let promptHash = "nltagger-no-prompt"

    func analyse(text: String) -> Annotation {
        let sentiment = measureSentiment(text: text)
        let language = detectLanguage(text: text)

        return Annotation(
            speechClass: "neutral",
            sentimentScore: sentiment,
            detectedLanguage: language,
            modelName: "apple-nltagger",
            modelVersion: Self.modelVersion,
            promptHash: Self.promptHash,
            rawResponse: "sentiment=\(sentiment),language=\(language)",
            stage: "nltagger"
        )
    }

    private func measureSentiment(text: String) -> Double {
        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        tagger.string = text
        let (tag, _) = tagger.tag(at: text.startIndex, unit: .paragraph, scheme: .sentimentScore)
        return Double(tag?.rawValue ?? "0") ?? 0.0
    }

    private func detectLanguage(text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage else { return "other" }
        switch language {
        case .german: return "de"
        case .english: return "en"
        default: return "other"
        }
    }
}
