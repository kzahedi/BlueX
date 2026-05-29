import XCTest
import SwiftData
@testable import BlueX

final class ThreadScraperTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!
    var mockSession: MockURLSession!

    override func setUpWithError() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: TrackedAccount.self, AccountGroup.self,
            Post.self, Annotation.self, AccountSnapshot.self,
            ScrapeLog.self, ModelConfig.self, CoordinatorState.self,
            configurations: config
        )
        context = ModelContext(container)
        mockSession = MockURLSession()
    }

    override func tearDownWithError() throws { container = nil; context = nil; mockSession = nil }

    private func makeThreadJSON(rootURI: String, replyURIs: [String]) throws -> Data {
        func makePost(_ uri: String, _ parentURI: String? = nil) -> [String: Any] {
            var record: [String: Any] = ["text": "post text", "createdAt": "2024-06-01T10:00:00.000Z"]
            if let p = parentURI {
                record["reply"] = ["parent": ["uri": p, "cid": "cid"], "root": ["uri": rootURI, "cid": "cid"]]
            }
            return [
                "uri": uri, "cid": "cid",
                "author": ["did": "did:public", "handle": "user.bsky.social"],
                "record": record,
                "indexedAt": "2024-06-01T10:00:00.000Z"
            ]
        }

        let replies: [[String: Any]] = replyURIs.map { uri in
            ["$type": "app.bsky.feed.defs#threadViewPost",
             "post": makePost(uri, rootURI),
             "replies": []] as [String : Any]
        }

        let rootThread: [String: Any] = [
            "thread": [
                "$type": "app.bsky.feed.defs#threadViewPost",
                "post": makePost(rootURI),
                "replies": replies
            ]
        ]
        return try JSONSerialization.data(withJSONObject: rootThread)
    }

    func testScrapeThreadStoresReplies() async throws {
        let rootURI = "at://did:plc:test/post/root"
        mockSession.mockData = try makeThreadJSON(rootURI: rootURI, replyURIs: [
            "at://did:public/post/r1",
            "at://did:public/post/r2"
        ])

        let account = TrackedAccount(did: "did:plc:test", handle: "test.de",
                                     displayName: "Test", startAt: Date(timeIntervalSince1970: 0))
        let rootPost = Post(uri: rootURI, text: "Root", createdAt: Date(),
                           authorDID: "did:plc:test", authorHandle: "test.de",
                           parentURI: nil, rootURI: rootURI, isRootPost: true, depth: 0)
        rootPost.account = account
        context.insert(account)
        context.insert(rootPost)
        try context.save()

        let client = BlueskyAPIClient(session: mockSession)
        let scraper = ThreadScraper(api: client, context: context)
        let count = try await scraper.scrapeAllThreads(for: account, token: "tok")

        XCTAssertEqual(count, 2)
        let allPosts = try context.fetch(FetchDescriptor<Post>())
        XCTAssertEqual(allPosts.count, 3)  // root + 2 replies
    }

    func testScrapeThreadSetsStatusComplete() async throws {
        let rootURI = "at://did:plc:test/post/root"
        mockSession.mockData = try makeThreadJSON(rootURI: rootURI, replyURIs: [])

        let account = TrackedAccount(did: "did:plc:test", handle: "test.de",
                                     displayName: "Test", startAt: Date(timeIntervalSince1970: 0))
        let rootPost = Post(uri: rootURI, text: "Root", createdAt: Date(),
                           authorDID: "did:plc:test", authorHandle: "test.de",
                           parentURI: nil, rootURI: rootURI, isRootPost: true, depth: 0)
        rootPost.account = account
        context.insert(account)
        context.insert(rootPost)
        try context.save()

        let client = BlueskyAPIClient(session: mockSession)
        let scraper = ThreadScraper(api: client, context: context)
        _ = try await scraper.scrapeAllThreads(for: account, token: "tok")

        XCTAssertEqual(rootPost.replyTreeStatus, .complete)
        XCTAssertNotNil(rootPost.replyTreeLastChecked)
    }

    func testScrapeThreadRepliesHaveCorrectDepth() async throws {
        let rootURI = "at://did:plc:test/post/root"
        mockSession.mockData = try makeThreadJSON(rootURI: rootURI, replyURIs: ["at://public/post/r1"])

        let account = TrackedAccount(did: "did:plc:test", handle: "test.de",
                                     displayName: "Test", startAt: Date(timeIntervalSince1970: 0))
        let rootPost = Post(uri: rootURI, text: "Root", createdAt: Date(),
                           authorDID: "did:plc:test", authorHandle: "test.de",
                           parentURI: nil, rootURI: rootURI, isRootPost: true, depth: 0)
        rootPost.account = account
        context.insert(account)
        context.insert(rootPost)
        try context.save()

        let client = BlueskyAPIClient(session: mockSession)
        let scraper = ThreadScraper(api: client, context: context)
        _ = try await scraper.scrapeAllThreads(for: account, token: "tok")

        let replies = try context.fetch(FetchDescriptor<Post>(
            predicate: #Predicate { !$0.isRootPost }
        ))
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies[0].depth, 1)
        XCTAssertEqual(replies[0].parentURI, rootURI)
    }
}
