import XCTest
import SwiftData
@testable import BlueX

final class FeedScraperTests: XCTestCase {
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

    // Helper: build a fake ATProtoFeedResponse with N posts for the given DID
    private func makeFeedJSON(did: String, count: Int, cursor: String? = nil) throws -> Data {
        var feedPosts: [[String: Any]] = []
        for i in 0..<count {
            feedPosts.append([
                "post": [
                    "uri": "at://\(did)/app.bsky.feed.post/post\(i)",
                    "cid": "cid\(i)",
                    "author": ["did": did, "handle": "test.de"],
                    "record": [
                        "text": "Post \(i)",
                        "createdAt": "2024-06-01T10:00:00.000Z"
                    ],
                    "indexedAt": "2024-06-01T10:00:00.000Z"
                ]
            ])
        }
        var response: [String: Any] = ["feed": feedPosts]
        if let cursor = cursor { response["cursor"] = cursor }
        return try JSONSerialization.data(withJSONObject: response)
    }

    func testScrapeSavesNewPosts() async throws {
        let did = "did:plc:testaccount"
        mockSession.mockData = try makeFeedJSON(did: did, count: 3)

        let account = TrackedAccount(did: did, handle: "test.de", displayName: "Test",
                                     startAt: Date(timeIntervalSince1970: 0))
        context.insert(account)
        try context.save()

        let client = BlueskyAPIClient(session: mockSession)
        let scraper = FeedScraper(api: client, context: context)
        let newCount = try await scraper.scrape(account: account, token: "tok")

        XCTAssertEqual(newCount, 3)
        let posts = try context.fetch(FetchDescriptor<Post>())
        XCTAssertEqual(posts.count, 3)
    }

    func testScrapeSkipsDuplicates() async throws {
        let did = "did:plc:testaccount"
        mockSession.mockData = try makeFeedJSON(did: did, count: 2)

        let account = TrackedAccount(did: did, handle: "test.de", displayName: "Test",
                                     startAt: Date(timeIntervalSince1970: 0))
        context.insert(account)

        // Pre-insert one of the posts as a duplicate
        let existing = Post(uri: "at://\(did)/app.bsky.feed.post/post0",
                           text: "Already stored", createdAt: Date(),
                           authorDID: did, authorHandle: "test.de",
                           parentURI: nil, rootURI: "at://\(did)/app.bsky.feed.post/post0",
                           isRootPost: true, depth: 0)
        context.insert(existing)
        try context.save()

        let client = BlueskyAPIClient(session: mockSession)
        let scraper = FeedScraper(api: client, context: context)
        let newCount = try await scraper.scrape(account: account, token: "tok")

        XCTAssertEqual(newCount, 1)  // only post1 is new
        let posts = try context.fetch(FetchDescriptor<Post>())
        XCTAssertEqual(posts.count, 2)  // existing + 1 new
    }

    func testScrapeCreatesCompleteLog() async throws {
        let did = "did:plc:testaccount"
        mockSession.mockData = try makeFeedJSON(did: did, count: 1)

        let account = TrackedAccount(did: did, handle: "test.de", displayName: "Test",
                                     startAt: Date(timeIntervalSince1970: 0))
        context.insert(account)
        try context.save()

        let client = BlueskyAPIClient(session: mockSession)
        let scraper = FeedScraper(api: client, context: context)
        _ = try await scraper.scrape(account: account, token: "tok")

        let logs = try context.fetch(FetchDescriptor<ScrapeLog>())
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs[0].status, "complete")
        XCTAssertNil(logs[0].resumeCursor)
        XCTAssertEqual(logs[0].postCount, 1)
    }

    func testScrapeCallsOnNewRootPostOncePerNewPost() async throws {
        let did = "did:plc:testaccount"
        mockSession.mockData = try makeFeedJSON(did: did, count: 3)

        let account = TrackedAccount(did: did, handle: "test.de", displayName: "Test",
                                     startAt: Date(timeIntervalSince1970: 0))
        context.insert(account)
        try context.save()

        let client = BlueskyAPIClient(session: mockSession)
        let scraper = FeedScraper(api: client, context: context)

        var callbackURIs: [String] = []
        let newCount = try await scraper.scrape(account: account, token: "tok") { post in
            callbackURIs.append(post.uri)
        }

        XCTAssertEqual(newCount, 3)
        XCTAssertEqual(callbackURIs.count, 3, "callback should fire once per new post (depth-first hook)")
        XCTAssertEqual(Set(callbackURIs).count, 3, "each new post delivered exactly once")
    }

    func testScrapeFiltersPostsByStartDate() async throws {
        let did = "did:plc:testaccount"
        // Feed has 1 post at 2024-06-01, account starts at 2025-01-01 → should be filtered
        mockSession.mockData = try makeFeedJSON(did: did, count: 1)

        let startDate = ISO8601DateFormatter().date(from: "2025-01-01T00:00:00Z")!
        let account = TrackedAccount(did: did, handle: "test.de", displayName: "Test", startAt: startDate)
        context.insert(account)
        try context.save()

        let client = BlueskyAPIClient(session: mockSession)
        let scraper = FeedScraper(api: client, context: context)
        let newCount = try await scraper.scrape(account: account, token: "tok")

        XCTAssertEqual(newCount, 0)  // post is before startDate
    }
}
