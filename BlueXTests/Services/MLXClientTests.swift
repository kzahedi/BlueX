import XCTest
@testable import BlueX

final class MLXClientTests: XCTestCase {

    func testClassifyParsesSuccessfulResponse() async throws {
        let mockSession = MockURLSession()
        let innerJSON = #"{"class": "hate", "severity": "mild", "confidence": 0.81, "reasoning": "Targets minority group"}"#
        let responseJSON = """
        {
          "choices": [
            {"message": {"content": "\(innerJSON.replacingOccurrences(of: "\"", with: "\\\""))"}}
          ]
        }
        """
        mockSession.mockData = responseJSON.data(using: .utf8)!
        mockSession.mockStatusCode = 200

        let client = MLXClient(modelName: "mlx-community/llama-3.2-3b", session: mockSession)
        let result = try await client.classify(text: "test text", language: "en")
        XCTAssertEqual(result.speechClass, "hate")
        XCTAssertEqual(result.severity, "mild")
        XCTAssertEqual(result.confidence, 0.81, accuracy: 0.001)
    }

    func testClassifyThrowsOnEmptyChoices() async {
        let mockSession = MockURLSession()
        mockSession.mockData = #"{"choices": []}"#.data(using: .utf8)!
        mockSession.mockStatusCode = 200

        let client = MLXClient(modelName: "mlx-community/llama-3.2-3b", session: mockSession)
        do {
            _ = try await client.classify(text: "test", language: "en")
            XCTFail("Expected error not thrown")
        } catch {
            XCTAssertNotNil(error)
        }
    }

    func testClassifyThrowsOnNon200() async {
        let mockSession = MockURLSession()
        mockSession.mockData = Data()
        mockSession.mockStatusCode = 503

        let client = MLXClient(modelName: "mlx-community/llama-3.2-3b", session: mockSession)
        do {
            _ = try await client.classify(text: "test", language: "en")
            XCTFail("Expected error not thrown")
        } catch {
            XCTAssertNotNil(error)
        }
    }
}
