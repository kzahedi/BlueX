import XCTest
import SwiftData
@testable import BlueX

final class PostAnnotationsTests: XCTestCase {
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

    private func makePost() -> Post {
        let post = Post(
            uri: "at://did/post/1", text: "hi", createdAt: Date(),
            authorDID: "did", authorHandle: "h",
            parentURI: nil, rootURI: "at://did/post/1",
            isRootPost: true, depth: 0
        )
        context.insert(post)
        return post
    }

    private func attach(_ post: Post, speechClass: String, stage: String, createdAt: Date) {
        let annotation = Annotation(
            speechClass: speechClass, sentimentScore: 0, detectedLanguage: "en",
            modelName: "m", modelVersion: "v", promptHash: "h",
            rawResponse: "", stage: stage
        )
        annotation.createdAt = createdAt
        annotation.post = post
        context.insert(annotation)
    }

    func testCurrentLLMAnnotationPicksMostRecentByDate() {
        let post = makePost()
        let now = Date()
        // Insert in an order where the most-recent annotation is NOT last in array order.
        attach(post, speechClass: "hate", stage: "llm", createdAt: now)                       // newest
        attach(post, speechClass: "neutral", stage: "llm", createdAt: now.addingTimeInterval(-3600)) // older

        XCTAssertEqual(post.currentSpeechClass, "hate")
    }

    func testCurrentLLMAnnotationIgnoresNLTaggerStage() {
        let post = makePost()
        let now = Date()
        attach(post, speechClass: "neutral", stage: "nltagger", createdAt: now)  // newer but wrong stage
        attach(post, speechClass: "counter", stage: "llm", createdAt: now.addingTimeInterval(-3600))

        XCTAssertEqual(post.currentSpeechClass, "counter")
    }

    func testPendingWhenNoLLMAnnotation() {
        let post = makePost()
        attach(post, speechClass: "neutral", stage: "nltagger", createdAt: Date())
        XCTAssertFalse(post.hasLLMAnnotation)
        XCTAssertTrue(post.hasNLTaggerAnnotation)
        XCTAssertNil(post.currentSpeechClass)
    }

    func testNLTaggerAnnotationPicksMostRecentByDate() {
        let post = makePost()
        let now = Date()
        attach(post, speechClass: "neutral", stage: "nltagger", createdAt: now.addingTimeInterval(-7200))
        attach(post, speechClass: "neutral", stage: "nltagger", createdAt: now)
        XCTAssertEqual(post.nlTaggerAnnotation?.createdAt, now)
    }
}
