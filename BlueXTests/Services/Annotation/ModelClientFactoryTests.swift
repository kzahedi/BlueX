import XCTest
@testable import BlueX

final class ModelClientFactoryTests: XCTestCase {

    func testOllamaEndpointConstructsOllamaClient() throws {
        let cfg = ModelConfig(
            name: "Qwen 3 8B",
            endpoint: "http://localhost:11434",
            modelID: "qwen3:8b",
            promptTemplate: ModelConfig.defaultPromptTemplate
        )
        let client = try ModelClientFactory.make(from: cfg)
        // The concrete OllamaClient surfaces the modelID it was constructed with.
        XCTAssertEqual(client.modelName, "qwen3:8b")
        XCTAssertTrue(client is OllamaClient)
    }

    func testCustomOllamaEndpointPassesThrough() throws {
        // Any non-sentinel endpoint string should route to OllamaClient (e.g. a
        // remote Ollama box, or LM Studio's OpenAI-compatible server later).
        let cfg = ModelConfig(
            name: "Remote",
            endpoint: "http://other-host:11434",
            modelID: "phi4:14b",
            promptTemplate: ModelConfig.defaultPromptTemplate
        )
        let client = try ModelClientFactory.make(from: cfg)
        XCTAssertEqual(client.modelName, "phi4:14b")
        XCTAssertTrue(client is OllamaClient)
    }

    /// On macOS 26+ the Apple Foundation Models endpoint dispatches to the Apple
    /// client; below that, we throw a clear error rather than silently constructing
    /// an OllamaClient pointed at the non-existent host.
    @available(macOS 26.0, *)
    func testAppleFoundationEndpointConstructsAppleClient() throws {
        let cfg = ModelConfig(
            name: "Apple",
            endpoint: ModelClientFactory.appleFoundationEndpoint,
            modelID: "apple-foundation",
            promptTemplate: ModelConfig.defaultPromptTemplate
        )
        // If Apple Intelligence is disabled on the CI machine, this throws — that's
        // the right behaviour. We only assert success vs typed error here.
        do {
            let client = try ModelClientFactory.make(from: cfg)
            XCTAssertEqual(client.modelName, "apple-foundation")
        } catch let error as ModelClientFactory.FactoryError {
            switch error {
            case .appleFoundationUnavailable:
                throw XCTSkip("Apple Foundation Models not available on this machine — skipping")
            }
        }
    }

    func testFactoryErrorHasUsefulMessage() {
        let err = ModelClientFactory.FactoryError.appleFoundationUnavailable(reason: "test reason")
        XCTAssertTrue(err.localizedDescription.contains("test reason"))
        XCTAssertTrue(err.localizedDescription.contains("macOS 26"))
    }
}
