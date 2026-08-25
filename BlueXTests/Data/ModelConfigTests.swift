import XCTest
import SwiftData
@testable import BlueX

final class ModelConfigTests: XCTestCase {
    func testDefaultPromptContainsPlaceholders() {
        XCTAssertTrue(ModelConfig.defaultPromptTemplate.contains("{{text}}"))
        XCTAssertTrue(ModelConfig.defaultPromptTemplate.contains("{{language}}"))
    }

    func testDefaultPromptContainsAllThreeClasses() {
        let template = ModelConfig.defaultPromptTemplate
        XCTAssertTrue(template.contains("hate"))
        XCTAssertTrue(template.contains("counter"))
        XCTAssertTrue(template.contains("neutral"))
    }

    func testDefaultPromptRequestsJSONResponse() {
        XCTAssertTrue(ModelConfig.defaultPromptTemplate.contains("JSON"))
    }

    /// The composed LLM prompt must be judged against the SAME canonical definitions
    /// as a human label — not a paraphrase of them — and must carry the definition
    /// version so a definition change is visible in recorded provenance (the prompt
    /// hash covers this text, see `MLXClientTests`).
    func testDefaultPromptContainsVerbatimHateAndCounterDefinitionsAndVersion() {
        let template = ModelConfig.defaultPromptTemplate
        XCTAssertTrue(template.contains(LabellingDefinitions.hate.definition))
        XCTAssertTrue(template.contains(LabellingDefinitions.counter.definition))
        XCTAssertTrue(template.contains("definitionVersion \(LabellingDefinitions.version)"))
    }

    /// The recorded `promptHash` is SHA256 of the whole template, so a definition
    /// change (which lands in this same template via `LabellingDefinitions.promptSummary`)
    /// necessarily changes the hash — the provenance record can't silently miss it.
    func testPromptHashCoversTheEmbeddedDefinitionText() {
        let withDefinitions = ModelConfig.defaultPromptTemplate
        let withoutDefinitions = withDefinitions.replacingOccurrences(
            of: LabellingDefinitions.promptSummary, with: "")
        XCTAssertNotEqual(withDefinitions, withoutDefinitions)
        XCTAssertNotEqual(
            ModelConfig.promptHash(of: withDefinitions),
            ModelConfig.promptHash(of: withoutDefinitions)
        )
    }

    func testModelConfigInit() throws {
        let config = ModelConfig(
            name: "Llama 3.2 (Ollama)",
            endpoint: "http://localhost:11434",
            modelID: "llama3.2",
            promptTemplate: ModelConfig.defaultPromptTemplate,
            isDefault: true
        )
        XCTAssertEqual(config.endpoint, "http://localhost:11434")
        XCTAssertTrue(config.isDefault)
    }
}
