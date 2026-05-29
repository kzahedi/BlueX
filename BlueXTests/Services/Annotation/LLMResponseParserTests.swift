import XCTest
@testable import BlueX

final class LLMResponseParserTests: XCTestCase {

    // MARK: - Happy path

    func testParsesMinimalValidJSON() throws {
        let raw = #"{"class": "neutral", "severity": null, "confidence": 0.9}"#
        let result = try LLMResponseParser.parse(raw)
        XCTAssertEqual(result.speechClass, "neutral")
        XCTAssertNil(result.severity)
        XCTAssertEqual(result.confidence, 0.9, accuracy: 0.0001)
    }

    func testParsesHateWithSeverityAndReasoning() throws {
        let raw = """
        {
          "class": "hate",
          "severity": "moderate",
          "confidence": 0.83,
          "reasoning": "Targets a protected group with dehumanising language"
        }
        """
        let result = try LLMResponseParser.parse(raw)
        XCTAssertEqual(result.speechClass, "hate")
        XCTAssertEqual(result.severity, "moderate")
        XCTAssertEqual(result.confidence, 0.83, accuracy: 0.0001)
        XCTAssertEqual(result.reasoning, "Targets a protected group with dehumanising language")
    }

    // MARK: - Tolerance

    func testStripsLeadingProse() throws {
        let raw = "Here is my analysis: " +
                  #"{"class": "counter", "severity": null, "confidence": 0.7}"#
        let result = try LLMResponseParser.parse(raw)
        XCTAssertEqual(result.speechClass, "counter")
    }

    func testStripsCodeFence() throws {
        let raw = """
        ```json
        {"class": "neutral", "severity": null, "confidence": 0.5}
        ```
        """
        let result = try LLMResponseParser.parse(raw)
        XCTAssertEqual(result.speechClass, "neutral")
    }

    /// The old naive first-`{` / last-`}` slicer collapsed two separate JSON objects
    /// in the response (e.g. tool-call frame + classification) into one ill-formed
    /// blob spanning both. Balanced extraction recovers the classification object
    /// when it appears first, even with a partial second object trailing.
    func testHandlesTrailingJSONLikeNoise() throws {
        let raw = #"{"class": "neutral", "severity": null, "confidence": 0.6} trailing: {"step": 1"#
        let result = try LLMResponseParser.parse(raw)
        XCTAssertEqual(result.speechClass, "neutral")
    }

    /// Braces inside string literals MUST NOT change the brace-depth counter.
    func testIgnoresBracesInStringLiterals() throws {
        let raw = #"{"class": "hate", "severity": null, "confidence": 0.5, "reasoning": "user wrote {literal braces}"}"#
        let result = try LLMResponseParser.parse(raw)
        XCTAssertEqual(result.speechClass, "hate")
        XCTAssertEqual(result.reasoning, "user wrote {literal braces}")
    }

    func testNormalisesNullSeverityString() throws {
        let raw = #"{"class": "neutral", "severity": "null", "confidence": 0.5}"#
        let result = try LLMResponseParser.parse(raw)
        XCTAssertNil(result.severity)
    }

    func testClampsConfidenceToZeroOne() throws {
        let high = try LLMResponseParser.parse(#"{"class": "neutral", "confidence": 1.7}"#)
        XCTAssertEqual(high.confidence, 1.0, accuracy: 0.0001)
        let low = try LLMResponseParser.parse(#"{"class": "neutral", "confidence": -0.3}"#)
        XCTAssertEqual(low.confidence, 0.0, accuracy: 0.0001)
    }

    // MARK: - Failure modes

    func testRejectsInvalidClass() {
        XCTAssertThrowsError(try LLMResponseParser.parse(
            #"{"class": "spam", "severity": null, "confidence": 0.9}"#
        ))
    }

    /// Sentiment pass uses a different class set than the hate/counter pass.
    /// Passing the positive/neutral/negative set should accept "negative" and
    /// reject "hate" (the latter would otherwise pass the default validator).
    func testAcceptsPositiveNeutralNegativeWhenConfigured() throws {
        let raw = #"{"class": "negative", "severity": null, "confidence": 0.85, "reasoning": "sarcastic praise"}"#
        let result = try LLMResponseParser.parse(raw, validClasses: LLMResponseParser.positiveNeutralNegative)
        XCTAssertEqual(result.speechClass, "negative")
    }

    func testRejectsHateInSentimentMode() {
        // "hate" is valid for the default set but NOT for sentiment — this guards
        // against accidentally routing a HICC output through the sentiment pass.
        let raw = #"{"class": "hate", "severity": "mild", "confidence": 0.9}"#
        XCTAssertThrowsError(try LLMResponseParser.parse(raw, validClasses: LLMResponseParser.positiveNeutralNegative))
    }

    func testRejectsNoJSON() {
        XCTAssertThrowsError(try LLMResponseParser.parse("I cannot classify this"))
    }

    func testRejectsTruncatedJSON() {
        XCTAssertThrowsError(try LLMResponseParser.parse(
            #"{"class": "neutral", "severity": null, "confidence":"#
        ))
    }

    // MARK: - Brace extractor directly

    func testExtractorFindsFirstBalancedObject() {
        let raw = #"prefix {"a":1} suffix {"b":2}"#
        let extracted = LLMResponseParser.extractBalancedJSONObject(from: raw)
        XCTAssertEqual(extracted, #"{"a":1}"#)
    }

    func testExtractorHandlesNestedObjects() {
        let raw = #"{"outer": {"inner": {"deep": true}}}"#
        let extracted = LLMResponseParser.extractBalancedJSONObject(from: raw)
        XCTAssertEqual(extracted, raw)
    }

    func testExtractorReturnsNilOnNoObject() {
        XCTAssertNil(LLMResponseParser.extractBalancedJSONObject(from: "no object here"))
    }

    func testExtractorHandlesEscapedQuotesInsideStrings() {
        let raw = #"{"text": "He said \"hi {there}\" loudly"}"#
        let extracted = LLMResponseParser.extractBalancedJSONObject(from: raw)
        XCTAssertEqual(extracted, raw)
    }
}
