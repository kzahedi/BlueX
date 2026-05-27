// BlueXTests/Views/AnnotationBadgeTests.swift
import XCTest
@testable import BlueX

final class AnnotationBadgeTests: XCTestCase {
    func testHateBadgeLabelIncludesSeverity() {
        let annotation = Annotation(
            speechClass: "hate", sentimentScore: -0.8, detectedLanguage: "de",
            modelName: "llama3.2", modelVersion: "latest", promptHash: "x",
            rawResponse: "{}", stage: "llm", severity: "moderate"
        )
        let badge = AnnotationBadge(annotation: annotation)
        XCTAssertTrue(badge.badgeLabelForTest.contains("hate"))
        XCTAssertTrue(badge.badgeLabelForTest.contains("moderate"))
    }
    func testHateBadgeLabelWithoutSeverity() {
        let annotation = Annotation(
            speechClass: "hate", sentimentScore: -0.8, detectedLanguage: "de",
            modelName: "llama3.2", modelVersion: "latest", promptHash: "x",
            rawResponse: "{}", stage: "llm", severity: nil
        )
        let badge = AnnotationBadge(annotation: annotation)
        XCTAssertEqual(badge.badgeLabelForTest, "● hate")
    }
    func testCounterBadgeLabel() {
        let annotation = Annotation(
            speechClass: "counter", sentimentScore: 0.3, detectedLanguage: "en",
            modelName: "llama3.2", modelVersion: "latest", promptHash: "x",
            rawResponse: "{}", stage: "llm"
        )
        let badge = AnnotationBadge(annotation: annotation)
        XCTAssertEqual(badge.badgeLabelForTest, "● counter")
    }
    func testNeutralBadgeLabel() {
        let annotation = Annotation(
            speechClass: "neutral", sentimentScore: 0.0, detectedLanguage: "en",
            modelName: "llama3.2", modelVersion: "latest", promptHash: "x",
            rawResponse: "{}", stage: "llm"
        )
        let badge = AnnotationBadge(annotation: annotation)
        XCTAssertEqual(badge.badgeLabelForTest, "● neutral")
    }
}
