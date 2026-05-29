// BlueXTests/Services/ScrapeCoordinatorAnnotationTests.swift
import XCTest
import SwiftData
@testable import BlueX

final class ScrapeCoordinatorAnnotationTests: XCTestCase {

    @MainActor
    func testNLTaggerAnnotationCreatesSentimentAnnotation() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Post.self, Annotation.self, TrackedAccount.self, AccountGroup.self,
            ScrapeLog.self, CoordinatorState.self, AccountSnapshot.self, ModelConfig.self,
            configurations: config
        )
        let context = container.mainContext

        let account = TrackedAccount(did: "did:test", handle: "test.bsky.social",
                                     displayName: "Test", startAt: Date())
        let post = Post(uri: "at://test/1", text: "Some interesting news story",
                        createdAt: Date(), authorDID: "did:test", authorHandle: "test.bsky.social",
                        parentURI: nil, rootURI: "at://test/1", isRootPost: false, depth: 1)
        post.account = account
        context.insert(account)
        context.insert(post)
        try context.save()

        let coordinator = ScrapeCoordinator(modelContainer: container)
        try await coordinator.runNLTaggerAnnotation()

        // AnnotationService writes through a detached context; re-fetch via a fresh
        // context to observe what was persisted (the main-context `post` wouldn't see it).
        let fresh = ModelContext(container)
        let reloaded = try XCTUnwrap(
            try fresh.fetch(FetchDescriptor<Post>(
                predicate: #Predicate<Post> { $0.uri == "at://test/1" }
            )).first
        )
        XCTAssertEqual(reloaded.annotations.count, 1)
        let annotation = try XCTUnwrap(reloaded.annotations.first)
        XCTAssertEqual(annotation.stage, "nltagger")
    }
}
