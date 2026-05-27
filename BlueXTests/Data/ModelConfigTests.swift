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
