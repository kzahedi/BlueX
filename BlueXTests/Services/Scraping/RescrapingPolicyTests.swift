import XCTest
@testable import BlueX

final class RescrapingPolicyTests: XCTestCase {
    let policy = RescrapingPolicy()
    let twoWeeks: TimeInterval = 14 * 86400

    private func makeRootPost(createdDaysAgo: Double, lastCheckedDaysAgo: Double? = nil) -> Post {
        let createdAt = Date().addingTimeInterval(-createdDaysAgo * 86400)
        let post = Post(uri: "at://test/\(UUID())", text: "t", createdAt: createdAt,
                       authorDID: "did:test", authorHandle: "test",
                       parentURI: nil, rootURI: "at://test/r",
                       isRootPost: true, depth: 0)
        if let d = lastCheckedDaysAgo {
            post.replyTreeLastChecked = Date().addingTimeInterval(-d * 86400)
        }
        return post
    }

    func testNeverScrapedAlwaysScrapesEvenWhenOld() {
        // Discovered long after posting (60 days) but never scraped → scrape once.
        let post = makeRootPost(createdDaysAgo: 60)
        XCTAssertTrue(policy.needsRescrape(post, window: twoWeeks))
    }

    func testRescrapesWhenLastScrapeWasInsideWindow() {
        // Created 25 days ago, last scraped 13 days after creation (inside the 14-day
        // window) → the user's example: this run should still update the tree.
        let post = makeRootPost(createdDaysAgo: 25, lastCheckedDaysAgo: 12)
        XCTAssertTrue(policy.needsRescrape(post, window: twoWeeks))
    }

    func testDoesNotRescrapeOnceLastScrapeIsPastWindow() {
        // Last scraped 20 days after a post created 25 days ago → past the 14-day window.
        let post = makeRootPost(createdDaysAgo: 25, lastCheckedDaysAgo: 5)
        XCTAssertFalse(policy.needsRescrape(post, window: twoWeeks))
    }

    func testBoundaryLastScrapeExactlyAtWindowEdgeStillScrapes() {
        // lastChecked == createdAt + window → still allowed (<=). Set relative to the
        // post's own createdAt so the boundary is exact (not subject to clock drift).
        let post = makeRootPost(createdDaysAgo: 28)
        post.replyTreeLastChecked = post.createdAt.addingTimeInterval(twoWeeks)
        XCTAssertTrue(policy.needsRescrape(post, window: twoWeeks))
    }

    func testNonRootPostNeverRescrapes() {
        let post = Post(uri: "at://test/r", text: "reply", createdAt: Date(),
                       authorDID: "d", authorHandle: "h",
                       parentURI: "at://parent", rootURI: "at://root",
                       isRootPost: false, depth: 1)
        XCTAssertFalse(policy.needsRescrape(post, window: twoWeeks))
    }

    func testRecentlyScrapedWithinWindowKeepsScraping() {
        // Fresh post, scraped an hour ago → still inside window, keep refreshing.
        let post = makeRootPost(createdDaysAgo: 1, lastCheckedDaysAgo: 0.04)
        XCTAssertTrue(policy.needsRescrape(post, window: twoWeeks))
    }
}
