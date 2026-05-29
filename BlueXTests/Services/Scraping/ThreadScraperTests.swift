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

    // MARK: - Per-post failure handling

    func testTerminalFailureMarksPostCompleteAndDoesNotThrow() async throws {
        // A 400 (deleted/blocked post) should freeze the root in .complete + lastChecked
        // so it never gets retried again — without throwing out of the batch.
        let rootURI = "at://did:plc:test/post/gone"
        mockSession.mockStatusCode = 400
        mockSession.mockData = Data("post not found".utf8)

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
        let summary = try await scraper.scrapeAllThreadsDetailed(for: account, token: "tok")

        XCTAssertEqual(summary.postsTerminalFailure, 1)
        XCTAssertEqual(summary.postsScrapedOK, 0)
        XCTAssertEqual(summary.postsTransientFailure, 0)
        XCTAssertEqual(rootPost.replyTreeStatus, .complete, "dead URI must be frozen so we stop retrying")
        XCTAssertNotNil(rootPost.replyTreeLastChecked)
    }

    func testTransientFailureLeavesPostInProgressForNextRun() async throws {
        // A network error (or 429-after-retries) leaves the post .inProgress so the
        // next run picks it up — the "all posts complete at least once" guarantee.
        let rootURI = "at://did:plc:test/post/transient"
        mockSession.mockStatusCode = 500  // generic networkError path

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
        let summary = try await scraper.scrapeAllThreadsDetailed(for: account, token: "tok")

        XCTAssertEqual(summary.postsTransientFailure, 1)
        XCTAssertEqual(rootPost.replyTreeStatus, .inProgress)
        XCTAssertNotNil(summary.firstTransientError)
    }

    func testOneBadPostDoesNotBlockOtherPostsInTheBatch() async throws {
        // First post 400s, second post returns a clean thread. The batch must continue
        // and report 1 terminal + 1 OK rather than aborting after the first failure.
        let goodRoot = "at://did:plc:test/post/good"
        let badRoot = "at://did:plc:test/post/gone"

        mockSession.scriptedResponses = [
            // bad post (created NEWER so it sorts first under .reverse createdAt) → 400
            MockURLSession.ScriptedResponse(data: Data("gone".utf8), statusCode: 400, headers: [:]),
            // good post → 200 with a tree containing 1 reply
            MockURLSession.ScriptedResponse(
                data: try makeThreadJSON(rootURI: goodRoot, replyURIs: ["at://reply/1"]),
                statusCode: 200, headers: [:]
            )
        ]

        let account = TrackedAccount(did: "did:plc:test", handle: "test.de",
                                     displayName: "Test", startAt: Date(timeIntervalSince1970: 0))
        let newer = Post(uri: badRoot, text: "Newer", createdAt: Date(),
                         authorDID: "did:plc:test", authorHandle: "test.de",
                         parentURI: nil, rootURI: badRoot, isRootPost: true, depth: 0)
        let older = Post(uri: goodRoot, text: "Older",
                         createdAt: Date().addingTimeInterval(-3600),
                         authorDID: "did:plc:test", authorHandle: "test.de",
                         parentURI: nil, rootURI: goodRoot, isRootPost: true, depth: 0)
        newer.account = account
        older.account = account
        context.insert(account)
        context.insert(newer)
        context.insert(older)
        try context.save()

        let client = BlueskyAPIClient(session: mockSession)
        let scraper = ThreadScraper(api: client, context: context)
        let summary = try await scraper.scrapeAllThreadsDetailed(for: account, token: "tok")

        XCTAssertEqual(summary.postsTerminalFailure, 1)
        XCTAssertEqual(summary.postsScrapedOK, 1)
        XCTAssertEqual(summary.repliesStored, 1)
        XCTAssertEqual(newer.replyTreeStatus, .complete) // terminal, frozen
        XCTAssertEqual(older.replyTreeStatus, .complete) // success
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
