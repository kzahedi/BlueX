import XCTest
import SwiftData
@testable import BlueX

final class AnnotationDedupTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!

    override func setUpWithError() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: Post.self, Annotation.self, TrackedAccount.self, AccountGroup.self,
            configurations: config
        )
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        container = nil
        context = nil
    }

    private func makePost(uri: String) -> Post {
        let post = Post(uri: uri, text: "t", createdAt: Date(),
                        authorDID: "did", authorHandle: "h",
                        parentURI: nil, rootURI: uri, isRootPost: true, depth: 0)
        context.insert(post)
        return post
    }

    private func makeAnnotation(post: Post, modelName: String, createdAt: Date,
                                stage: String = "llm") -> Annotation {
        let ann = Annotation(
            speechClass: "neutral", sentimentScore: 0.0, detectedLanguage: "en",
            modelName: modelName, modelVersion: "v1", promptHash: "h",
            rawResponse: "r", stage: stage
        )
        ann.createdAt = createdAt
        ann.post = post
        context.insert(ann)
        return ann
    }

    func testKeepsNewestPerModel() throws {
        let post = makePost(uri: "at://1")
        let old = makeAnnotation(post: post, modelName: "qwen2.5:7b",
                                 createdAt: Date(timeIntervalSince1970: 1000))
        let newer = makeAnnotation(post: post, modelName: "qwen2.5:7b",
                                   createdAt: Date(timeIntervalSince1970: 2000))
        try context.save()

        let deleted = try AnnotationDedup.dedupLLM(in: context)
        XCTAssertEqual(deleted, 1)

        let remaining = try context.fetch(FetchDescriptor<Annotation>())
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.createdAt, newer.createdAt)
        XCTAssertFalse(remaining.contains(where: { $0.createdAt == old.createdAt }))
    }

    func testDoesNotMergeAcrossDifferentModels() throws {
        let post = makePost(uri: "at://1")
        _ = makeAnnotation(post: post, modelName: "qwen2.5:7b",
                           createdAt: Date(timeIntervalSince1970: 1000))
        _ = makeAnnotation(post: post, modelName: "qwen3.6:27b",
                           createdAt: Date(timeIntervalSince1970: 2000))
        try context.save()

        let deleted = try AnnotationDedup.dedupLLM(in: context)
        XCTAssertEqual(deleted, 0)

        let remaining = try context.fetch(FetchDescriptor<Annotation>())
        XCTAssertEqual(remaining.count, 2)
    }

    func testIgnoresNLTaggerStage() throws {
        let post = makePost(uri: "at://1")
        _ = makeAnnotation(post: post, modelName: "apple-nltagger",
                           createdAt: Date(timeIntervalSince1970: 1000),
                           stage: "nltagger")
        _ = makeAnnotation(post: post, modelName: "apple-nltagger",
                           createdAt: Date(timeIntervalSince1970: 2000),
                           stage: "nltagger")
        try context.save()

        let deleted = try AnnotationDedup.dedupLLM(in: context)
        XCTAssertEqual(deleted, 0, "nltagger annotations are out of scope for LLM dedup")
    }

    func testNoDuplicatesIsNoop() throws {
        let post = makePost(uri: "at://1")
        _ = makeAnnotation(post: post, modelName: "qwen2.5:7b",
                           createdAt: Date(timeIntervalSince1970: 1000))
        _ = makeAnnotation(post: post, modelName: "qwen3.6:27b",
                           createdAt: Date(timeIntervalSince1970: 1000))
        try context.save()

        let deleted = try AnnotationDedup.dedupLLM(in: context)
        XCTAssertEqual(deleted, 0)
    }

    func testDedupsAcrossMultiplePosts() throws {
        let p1 = makePost(uri: "at://1")
        let p2 = makePost(uri: "at://2")
        _ = makeAnnotation(post: p1, modelName: "qwen2.5:7b",
                           createdAt: Date(timeIntervalSince1970: 1000))
        _ = makeAnnotation(post: p1, modelName: "qwen2.5:7b",
                           createdAt: Date(timeIntervalSince1970: 2000))
        _ = makeAnnotation(post: p2, modelName: "qwen2.5:7b",
                           createdAt: Date(timeIntervalSince1970: 1000))
        _ = makeAnnotation(post: p2, modelName: "qwen2.5:7b",
                           createdAt: Date(timeIntervalSince1970: 2000))
        _ = makeAnnotation(post: p2, modelName: "qwen2.5:7b",
                           createdAt: Date(timeIntervalSince1970: 3000))
        try context.save()

        let deleted = try AnnotationDedup.dedupLLM(in: context)
        XCTAssertEqual(deleted, 3, "p1 keeps 1 of 2, p2 keeps 1 of 3 → 3 deletions")

        let remaining = try context.fetch(FetchDescriptor<Annotation>())
        XCTAssertEqual(remaining.count, 2)
    }
}
