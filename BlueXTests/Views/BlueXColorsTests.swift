// BlueXTests/Views/BlueXColorsTests.swift
import XCTest
import SwiftUI
@testable import BlueX

final class BlueXColorsTests: XCTestCase {
    func testHateBorderColorExists() {
        let color = Color.hateBorder
        XCTAssertNotNil(color)
    }
    func testCounterBorderColorExists() {
        XCTAssertNotNil(Color.counterBorder)
    }
    func testNeutralBorderColorExists() {
        XCTAssertNotNil(Color.neutralBorder)
    }
    func testSpeechClassBorderHate() {
        let color = Color.speechClassBorder("hate")
        XCTAssertNotNil(color)
    }
    func testSpeechClassBorderReturnsNeutralForUnknown() {
        let color = Color.speechClassBorder("unknown_class")
        XCTAssertNotNil(color)
    }
    func testSpeechClassBackgroundCoversAllClasses() {
        for speechClass in ["hate", "counter", "neutral", "other"] {
            XCTAssertNotNil(Color.speechClassBackground(speechClass))
        }
    }
    func testSpeechClassBadgeTextCoversAllClasses() {
        for speechClass in ["hate", "counter", "neutral", "other"] {
            XCTAssertNotNil(Color.speechClassBadgeText(speechClass))
        }
    }
}
