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
        context = container.mainContext
    }

    override func tearDownWithError() throws {
        container = nil
        context = nil
    }

    /// AnnotationService writes annotations on a detached Task with its own
    /// `ModelContext(container)`. Those rows hit the store, but the test's main-context
    /// Post instance doesn't auto-fault them in — so we re-fetch through a fresh
    /// context to observe what was actually persisted. Older versions of these tests
    /// read `post.annotations` from the captured instance and silently saw 0.
    private func annotations(forURI uri: String) throws -> [Annotation] {
        let fresh = ModelContext(container)
        let posts = try fresh.fetch(FetchDescriptor<Post>(
            predicate: #Predicate<Post> { $0.uri == uri }
        ))
        guard let post = posts.first else { return [] }
        return post.annotations
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

        let post1Annotations = try annotations(forURI: "at://1")
        XCTAssertEqual(post1Annotations.count, 1)
        let firstAnnotation = try XCTUnwrap(post1Annotations.first)
        XCTAssertEqual(firstAnnotation.stage, "nltagger")
        XCTAssertEqual(try annotations(forURI: "at://2").count, 1)
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

        XCTAssertEqual(try annotations(forURI: "at://1").count, 1)
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

    /// The GUI's Stop button calls `cancel()`, which cancels `runningTask`. That must
    /// propagate all the way into `NLTaggerPass.run`'s `isCancelled` polling — this is
    /// the wiring that was previously missing (the capability existed on
    /// `NLTaggerPass` but had no caller passing `isCancelled`).
    ///
    /// Rather than race a wall-clock sleep against the pass, this waits for the
    /// deterministic hand-off point: `runNLTaggerPass` publishes the initial
    /// `queueSize` (from `NLTaggerPass`'s `progress(0, estimatedTotal)` call) before
    /// any page is fetched. Once that's observed, cancel() is guaranteed to race
    /// against real per-page work (context creation + save), not against pass setup,
    /// which is enough margin with a large post count and a small batchSize.
    func testCancelStopsTheNLTaggerPass() async throws {
        let account = TrackedAccount(did: "did:1", handle: "test.bsky.social", displayName: "Test", startAt: Date())
        let total = 400
        for i in 0..<total {
            let uri = "at://cancel/\(i)"
            let post = Post(uri: uri, text: "Post number \(i)", createdAt: Date(), authorDID: "did:1",
                            authorHandle: "user", parentURI: nil, rootURI: uri, isRootPost: false, depth: 1)
            post.account = account
            context.insert(post)
        }
        context.insert(account)
        try context.save()

        let service = AnnotationService(modelContainer: container)

        let runTask = Task {
            try await service.runNLTaggerPass(batchSize: 5)
        }

        while service.queueSize == 0 {
            await Task.yield()
        }
        service.cancel()

        try await runTask.value

        XCTAssertFalse(service.isRunning)
        XCTAssertLessThan(service.processedCount, total,
                          "cancel() should stop the pass before it finishes the full backlog")
    }
}
