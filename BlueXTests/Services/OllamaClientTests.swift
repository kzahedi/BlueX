import XCTest
@testable import BlueX

final class OllamaClientTests: XCTestCase {

    func testParseValidHateResponse() throws {
        let client = OllamaClient(modelName: "llama3.2")
        let raw = """
        {"class": "hate", "severity": "moderate", "confidence": 0.87, "reasoning": "Contains slur targeting ethnic group"}
        """
        let annotation = try client.parseLLMResponse(raw)
        XCTAssertEqual(annotation.speechClass, "hate")
        XCTAssertEqual(annotation.severity, "moderate")
        XCTAssertEqual(annotation.confidence, 0.87, accuracy: 0.001)
    }

    func testParseCounterResponse() throws {
        let client = OllamaClient(modelName: "llama3.2")
        let raw = """
        {"class": "counter", "severity": null, "confidence": 0.92, "reasoning": "Directly challenges hate speech with facts"}
        """
        let annotation = try client.parseLLMResponse(raw)
        XCTAssertEqual(annotation.speechClass, "counter")
        XCTAssertNil(annotation.severity)
    }

    func testParseResponseWithLeadingText() throws {
        let client = OllamaClient(modelName: "llama3.2")
        let raw = """
        Here is my classification:
        {"class": "neutral", "severity": null, "confidence": 0.78, "reasoning": "Factual comment"}
        """
        let annotation = try client.parseLLMResponse(raw)
        XCTAssertEqual(annotation.speechClass, "neutral")
    }

    func testInvalidClassThrows() {
        let client = OllamaClient(modelName: "llama3.2")
        let raw = """
        {"class": "spam", "severity": null, "confidence": 0.5, "reasoning": "test"}
        """
        XCTAssertThrowsError(try client.parseLLMResponse(raw))
    }

    func testPromptHashIsDeterministic() {
        let client1 = OllamaClient(modelName: "llama3.2", promptTemplate: "same template")
        let client2 = OllamaClient(modelName: "llama3.2", promptTemplate: "same template")
        XCTAssertEqual(client1.promptHash, client2.promptHash)
    }

    func testDifferentTemplatesProduceDifferentHashes() {
        let client1 = OllamaClient(modelName: "llama3.2", promptTemplate: "template A")
        let client2 = OllamaClient(modelName: "llama3.2", promptTemplate: "template B")
        XCTAssertNotEqual(client1.promptHash, client2.promptHash)
    }
}
