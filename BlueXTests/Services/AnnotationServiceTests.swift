import XCTest
import SwiftData
@testable import BlueX

final class AnnotationServiceTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!

    @MainActor
    override func setUpWithError() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: Post.self, Annotation.self, TrackedAccount.self, AccountGroup.self,
            configurations: config
        )
        // Why: use mainContext so test objects and service objects share the same context.
        // AnnotationService.runNLTaggerPass() is @MainActor and uses mainContext.
        // Using a separate ModelContext(container) would cause cross-context relationship
        // visibility issues where post.annotations would not reflect service-added annotations.
        context = container.mainContext
    }

    override func tearDownWithError() throws {
        container = nil
        context = nil
    }

    func testNLTaggerPassCreatesAnnotations() async throws {
        let account = TrackedAccount(did: "did:1", handle: "test.bsky.social", displayName: "Test", startAt: Date())
        let post1 = Post(uri: "at://1", text: "Hello world", createdAt: Date(), authorDID: "did:1",
                         authorHandle: "user1", parentURI: nil, rootURI: "at://1", isRootPost: false, depth: 1)
        let post2 = Post(uri: "at://2", text: "Terrible news today", createdAt: Date(), authorDID: "did:2",
                         authorHandle: "user2", parentURI: nil, rootURI: "at://2", isRootPost: false, depth: 1)
        post1.account = account
        post2.account = account
        context.insert(account)
        context.insert(post1)
        context.insert(post2)
        try context.save()

        let service = AnnotationService(modelContainer: container)
        try await service.runNLTaggerPass()

        XCTAssertEqual(post1.annotations.count, 1)
        XCTAssertEqual(post1.annotations[0].stage, "nltagger")
        XCTAssertEqual(post2.annotations.count, 1)
        XCTAssertEqual(service.processedCount, 2)
    }

    func testNLTaggerPassSkipsAlreadyAnnotatedPosts() async throws {
        let account = TrackedAccount(did: "did:1", handle: "test.bsky.social", displayName: "Test", startAt: Date())
        let post = Post(uri: "at://1", text: "Hello", createdAt: Date(), authorDID: "did:1",
                        authorHandle: "user1", parentURI: nil, rootURI: "at://1", isRootPost: false, depth: 1)
        post.account = account
        let existing = Annotation(
            speechClass: "neutral", sentimentScore: 0.0, detectedLanguage: "en",
            modelName: "apple-nltagger", modelVersion: "v1", promptHash: "x",
            rawResponse: "x", stage: "nltagger"
        )
        existing.post = post
        context.insert(account)
        context.insert(post)
        context.insert(existing)
        try context.save()

        let service = AnnotationService(modelContainer: container)
        try await service.runNLTaggerPass()

        XCTAssertEqual(post.annotations.count, 1)
    }

    func testQueueSizeReflectsUnannotatedCount() async throws {
        let account = TrackedAccount(did: "did:1", handle: "test.bsky.social", displayName: "Test", startAt: Date())
        for i in 1...5 {
            let post = Post(uri: "at://\(i)", text: "Post \(i)", createdAt: Date(), authorDID: "did:1",
                            authorHandle: "user\(i)", parentURI: nil, rootURI: "at://\(i)", isRootPost: false, depth: 1)
            post.account = account
            context.insert(post)
        }
        context.insert(account)
        try context.save()

        let service = AnnotationService(modelContainer: container)
        try await service.runNLTaggerPass()
        XCTAssertEqual(service.processedCount, 5)
    }
}
