// tools/benchmark/support/nl_score.swift
//
// Standalone scorer mirroring BlueX/Services/Annotation/NLTaggerAnalyser.swift
// exactly: NLTagger(tagSchemes: [.sentimentScore]), unit: .paragraph for
// sentiment, plus NLLanguageRecognizer collapsed to en / de / other.
//
// This is the ONLY place sentiment/language scoring logic lives for the
// benchmark harness. detectors/nltagger.py shells out to the binary compiled
// from this file so the score it reports is provably the app's own
// configuration, not a Python reimplementation that could silently drift.
//
// Protocol: reads a JSON array of strings from stdin, writes a JSON array of
// {"sentiment": Double, "language": "en"|"de"|"other"} objects to stdout, in
// the same order. No network, no store access, no side effects.
import Foundation
import NaturalLanguage

struct NLResult: Codable {
    let sentiment: Double
    let language: String
}

func scoreOne(_ text: String) -> NLResult {
    if text.isEmpty {
        return NLResult(sentiment: 0.0, language: "other")
    }

    let tagger = NLTagger(tagSchemes: [.sentimentScore])
    tagger.string = text
    let (tag, _) = tagger.tag(at: text.startIndex, unit: .paragraph, scheme: .sentimentScore)
    let sentiment = Double(tag?.rawValue ?? "0") ?? 0.0

    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)
    let language: String
    switch recognizer.dominantLanguage {
    case .some(.german): language = "de"
    case .some(.english): language = "en"
    default: language = "other"
    }

    return NLResult(sentiment: sentiment, language: language)
}

let inputData = FileHandle.standardInput.readDataToEndOfFile()
let texts: [String]
do {
    texts = try JSONDecoder().decode([String].self, from: inputData)
} catch {
    FileHandle.standardError.write("nl_score: bad JSON on stdin: \(error)\n".data(using: .utf8)!)
    exit(1)
}

let results = texts.map(scoreOne)

do {
    let outputData = try JSONEncoder().encode(results)
    FileHandle.standardOutput.write(outputData)
} catch {
    FileHandle.standardError.write("nl_score: failed to encode output: \(error)\n".data(using: .utf8)!)
    exit(1)
}
