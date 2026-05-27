import XCTest
import NaturalLanguage
@testable import BlueX

final class NLTaggerAnalyserTests: XCTestCase {
    let analyser = NLTaggerAnalyser()

    func testPositiveTextHasPositiveSentiment() {
        let annotation = analyser.analyse(text: "This is wonderful and amazing! I love it.")
        XCTAssertGreaterThan(annotation.sentimentScore, 0.0)
    }

    func testNegativeTextHasNegativeSentiment() {
        let annotation = analyser.analyse(text: "This is terrible and disgusting. I hate it.")
        XCTAssertLessThan(annotation.sentimentScore, 0.0)
    }

    func testGermanTextDetected() {
        let annotation = analyser.analyse(text: "Das ist eine sehr interessante Nachricht über die Bundesregierung.")
        XCTAssertEqual(annotation.detectedLanguage, "de")
    }

    func testEnglishTextDetected() {
        let annotation = analyser.analyse(text: "The president signed a new bill into law today.")
        XCTAssertEqual(annotation.detectedLanguage, "en")
    }

    func testSpeechClassAlwaysNeutral() {
        let annotation = analyser.analyse(text: "Some text here")
        XCTAssertEqual(annotation.speechClass, "neutral")
        XCTAssertEqual(annotation.stage, "nltagger")
    }

    func testModelNameIsAppleNLTagger() {
        let annotation = analyser.analyse(text: "Test")
        XCTAssertEqual(annotation.modelName, "apple-nltagger")
    }
}
