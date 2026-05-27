// BlueXTests/Services/ScrapeCoordinatorAnnotationTests.swift
import XCTest
import SwiftData
@testable import BlueX

final class ScrapeCoordinatorAnnotationTests: XCTestCase {

    func testAnnotationRunsAfterScrapePhaseCompletes() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Post.self, Annotation.self, TrackedAccount.self, AccountGroup.self,
            ScrapeLog.self, CoordinatorState.self, AccountSnapshot.self, ModelConfig.self,
            configurations: config
        )
        let context = ModelContext(container)

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

        XCTAssertEqual(post.annotations.count, 1)
        XCTAssertEqual(post.annotations[0].stage, "nltagger")
    }
}
