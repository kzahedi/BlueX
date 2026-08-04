// BlueXTests/Services/NLTaggerPassTests.swift
import XCTest
import SwiftData
@testable import BlueX

final class NLTaggerPassTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: Post.self, Annotation.self, TrackedAccount.self, AccountGroup.self,
            ScrapeLog.self, CoordinatorState.self, AccountSnapshot.self, ModelConfig.self,
            configurations: config
        )
    }

    private func insertPosts(_ n: Int, in container: ModelContainer) throws {
        let context = ModelContext(container)
        for i in 0..<n {
            let uri = String(format: "at://test/%03d", i)
            let post = Post(uri: uri,
                            text: "Ein ganz normaler Beitrag Nummer \(i)",
                            createdAt: Date(timeIntervalSince1970: Double(1_700_000_000 + i)),
                            authorDID: "did:test", authorHandle: "test.bsky.social",
                            parentURI: nil, rootURI: uri,
                            isRootPost: true, depth: 0)
            context.insert(post)
        }
        try context.save()
    }

    // batchSize deliberately smaller than the post count: the old implementation
    // never paged, so this is the regression that matters.
    func testAnnotatesEveryPostAcrossPageBoundaries() throws {
        let container = try makeContainer()
        try insertPosts(5, in: container)

        let annotated = try NLTaggerPass(container: container).run(batchSize: 2)

        XCTAssertEqual(annotated, 5)
        let fresh = ModelContext(container)
        let posts = try fresh.fetch(FetchDescriptor<Post>())
        XCTAssertEqual(posts.count, 5)
        for post in posts {
            XCTAssertEqual(post.annotations.filter { $0.stage == "nltagger" }.count, 1,
                           "post \(post.uri) should have exactly one nltagger annotation")
        }
    }

    func testSkipsPostsThatAlreadyHaveAnNLTaggerAnnotation() throws {
        let container = try makeContainer()
        try insertPosts(5, in: container)

        XCTAssertEqual(try NLTaggerPass(container: container).run(batchSize: 2), 5)
        XCTAssertEqual(try NLTaggerPass(container: container).run(batchSize: 2), 0,
                       "a second pass must be a no-op")

        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<Annotation>()).count, 5,
                       "second pass must not duplicate annotations")
    }

    func testRespectsLimit() throws {
        let container = try makeContainer()
        try insertPosts(5, in: container)

        let annotated = try NLTaggerPass(container: container).run(batchSize: 2, limit: 3)

        XCTAssertEqual(annotated, 3)
        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<Annotation>()).count, 3)
    }

    func testReportsProgress() throws {
        let container = try makeContainer()
        try insertPosts(4, in: container)

        var updates: [(Int, Int)] = []
        _ = try NLTaggerPass(container: container).run(batchSize: 2) { done, total in
            updates.append((done, total))
        }

        XCTAssertEqual(updates.first?.0, 0, "should report 0 before any work")
        XCTAssertEqual(updates.last?.0, 4, "should report the final count")
        XCTAssertEqual(updates.last?.1, 4, "estimated total should be the pending count")
    }

    func testStopsWhenCancelled() throws {
        let container = try makeContainer()
        try insertPosts(6, in: container)

        var pages = 0
        let annotated = try NLTaggerPass(container: container).run(
            batchSize: 2,
            isCancelled: { pages >= 1 },
            progress: { _, _ in pages += 1 }
        )

        XCTAssertLessThan(annotated, 6, "cancellation should stop the pass early")
    }
}
