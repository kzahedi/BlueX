import XCTest
import SwiftData
@testable import BlueX

final class PostTests: XCTestCase {
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

    override func tearDownWithError() throws {
        container = nil; context = nil
    }

    func testCreateRootPost() throws {
        let post = Post(uri: "at://did:plc:test/app.bsky.feed.post/abc123",
                        text: "Hello world", createdAt: Date(),
                        authorDID: "did:plc:test", authorHandle: "spiegel.de",
                        parentURI: nil, rootURI: "at://did:plc:test/app.bsky.feed.post/abc123",
                        isRootPost: true, depth: 0)
        context.insert(post)
        try context.save()

        let posts = try context.fetch(FetchDescriptor<Post>())
        XCTAssertEqual(posts.count, 1)
        XCTAssertNil(posts[0].parentURI)
        XCTAssertEqual(posts[0].depth, 0)
        XCTAssertTrue(posts[0].isRootPost)
        XCTAssertEqual(posts[0].replyTreeStatus, .pending)
        XCTAssertFalse(posts[0].needsReAnnotation)
    }

    func testCreateReply() throws {
        let reply = Post(uri: "at://did:plc:user/post/reply1",
                         text: "A reply", createdAt: Date(),
                         authorDID: "did:plc:user", authorHandle: "user.bsky.social",
                         parentURI: "at://did:plc:test/post/root",
                         rootURI: "at://did:plc:test/post/root",
                         isRootPost: false, depth: 1)
        context.insert(reply)
        try context.save()

        let posts = try context.fetch(FetchDescriptor<Post>())
        XCTAssertEqual(posts[0].parentURI, "at://did:plc:test/post/root")
        XCTAssertEqual(posts[0].depth, 1)
        XCTAssertFalse(posts[0].isRootPost)
    }

    func testReplyTreeStatusTransitions() throws {
        let post = Post(uri: "at://test", text: "t", createdAt: Date(),
                        authorDID: "d", authorHandle: "h",
                        parentURI: nil, rootURI: "at://test",
                        isRootPost: true, depth: 0)
        context.insert(post)
        XCTAssertEqual(post.replyTreeStatus, .pending)
        post.replyTreeStatus = .inProgress
        XCTAssertEqual(post.replyTreeStatus, .inProgress)
        post.replyTreeStatus = .complete
        XCTAssertEqual(post.replyTreeStatus, .complete)
    }
}
