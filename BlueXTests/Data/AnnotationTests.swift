import XCTest
import SwiftData
@testable import BlueX

final class AnnotationTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!

    override func setUpWithError() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: TrackedAccount.self, AccountGroup.self,
            Post.self, Annotation.self, AccountSnapshot.self,
            ScrapeLog.self, ModelConfig.self, CoordinatorState.self,
            configurations: config
        )
        context = ModelContext(container)
    }

    override func tearDownWithError() throws { container = nil; context = nil }

    func testCreateAnnotation() throws {
        let annotation = Annotation(
            speechClass: "hate", sentimentScore: -0.8, detectedLanguage: "de",
            modelName: "llama3.2", modelVersion: "latest", promptHash: "abc123",
            rawResponse: "{\"class\":\"hate\"}", stage: "llm",
            severity: "moderate", confidence: 0.92
        )
        context.insert(annotation)
        try context.save()

        let annotations = try context.fetch(FetchDescriptor<Annotation>())
        XCTAssertEqual(annotations.count, 1)
        XCTAssertEqual(annotations[0].speechClass, "hate")
        XCTAssertEqual(annotations[0].severity, "moderate")
        XCTAssertEqual(annotations[0].confidence, 0.92, accuracy: 0.001)
        XCTAssertEqual(annotations[0].detectedLanguage, "de")
    }

    func testMultipleAnnotationsPerPost() throws {
        let post = Post(uri: "at://test", text: "test", createdAt: Date(),
                        authorDID: "d", authorHandle: "h",
                        parentURI: nil, rootURI: "at://test",
                        isRootPost: false, depth: 1)
        let a1 = Annotation(speechClass: "neutral", sentimentScore: 0.0, detectedLanguage: "en",
                            modelName: "apple-nltagger", modelVersion: "2024", promptHash: "x",
                            rawResponse: "s=0,l=en", stage: "nltagger")
        let a2 = Annotation(speechClass: "hate", sentimentScore: -0.7, detectedLanguage: "en",
                            modelName: "llama3.2", modelVersion: "latest", promptHash: "y",
                            rawResponse: "{}", stage: "llm", severity: "mild", confidence: 0.75)
        a1.post = post
        a2.post = post
        post.annotations = [a1, a2]
        context.insert(post)
        context.insert(a1)
        context.insert(a2)
        try context.save()

        let posts = try context.fetch(FetchDescriptor<Post>())
        XCTAssertEqual(posts[0].annotations.count, 2)
        // Different models — both preserved
        let stages = Set(posts[0].annotations.map { $0.stage })
        XCTAssertTrue(stages.contains("nltagger"))
        XCTAssertTrue(stages.contains("llm"))
    }

    func testNLTaggerAnnotationHasNoSeverity() throws {
        let annotation = Annotation(
            speechClass: "neutral", sentimentScore: 0.1, detectedLanguage: "en",
            modelName: "apple-nltagger", modelVersion: "2024",
            promptHash: "nltagger-no-prompt", rawResponse: "s=0.1,l=en",
            stage: "nltagger"
        )
        XCTAssertNil(annotation.severity)
        XCTAssertEqual(annotation.stage, "nltagger")
    }
}
