import XCTest
@testable import BlueX

final class RescrapingPolicyTests: XCTestCase {
    let policy = RescrapingPolicy()
    let twoWeeks: TimeInterval = 14 * 86400

    /// Builds a post in a realistic state: passing `lastCheckedDaysAgo` implies
    /// the scrape succeeded, so `replyTreeStatus = .complete`. The policy uses
    /// the status as the "scraped at least once" signal — `lastChecked` alone
    /// isn't enough since incomplete trees may still carry a probe timestamp.
    private func makeRootPost(createdDaysAgo: Double,
                              lastCheckedDaysAgo: Double? = nil,
                              status: ReplyTreeStatus = .pending) -> Post {
        let createdAt = Date().addingTimeInterval(-createdDaysAgo * 86400)
        let post = Post(uri: "at://test/\(UUID())", text: "t", createdAt: createdAt,
                       authorDID: "did:test", authorHandle: "test",
                       parentURI: nil, rootURI: "at://test/r",
                       isRootPost: true, depth: 0)
        if let d = lastCheckedDaysAgo {
            post.replyTreeLastChecked = Date().addingTimeInterval(-d * 86400)
            post.replyTreeStatus = .complete   // .complete is the post-success default
        } else {
            post.replyTreeStatus = status
        }
        return post
    }

    // MARK: - Completed scrapes — window applies

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
        post.replyTreeStatus = .complete
        post.replyTreeLastChecked = post.createdAt.addingTimeInterval(twoWeeks)
        XCTAssertTrue(policy.needsRescrape(post, window: twoWeeks))
    }

    func testRecentlyScrapedWithinWindowKeepsScraping() {
        // Fresh post, scraped an hour ago → still inside window, keep refreshing.
        let post = makeRootPost(createdDaysAgo: 1, lastCheckedDaysAgo: 0.04)
        XCTAssertTrue(policy.needsRescrape(post, window: twoWeeks))
    }

    // MARK: - Incomplete trees — always scraped, age ignored

    func testNeverScrapedAlwaysScrapesEvenWhenOld() {
        // The "all posts complete at least once" guarantee: a 60-day-old post that's
        // never been scraped must be picked up. Age doesn't gate the first scrape.
        let post = makeRootPost(createdDaysAgo: 60, status: .pending)
        XCTAssertTrue(policy.needsRescrape(post, window: twoWeeks))
    }

    func testInProgressIsAlwaysRescrapedEvenPastWindow() {
        // A post left in `.inProgress` from a partial / failed earlier scrape MUST be
        // retried, even though it's now well past its window. This is what allows long
        // backfills to be split across many runs (rate-limit interruptions etc.).
        let post = makeRootPost(createdDaysAgo: 90, status: .inProgress)
        post.replyTreeLastChecked = Date().addingTimeInterval(-89 * 86400) // touched once long ago
        XCTAssertTrue(policy.needsRescrape(post, window: twoWeeks))
    }

    func testCompleteButMissingTimestampGetsRepaired() {
        // Degenerate state: status .complete but lastChecked nil. Surface as due so
        // the next pass repairs it.
        let post = makeRootPost(createdDaysAgo: 5, status: .complete)
        XCTAssertNil(post.replyTreeLastChecked)
        XCTAssertTrue(policy.needsRescrape(post, window: twoWeeks))
    }

    // MARK: - Structural guards

    func testNonRootPostNeverRescrapes() {
        let post = Post(uri: "at://test/r", text: "reply", createdAt: Date(),
                       authorDID: "d", authorHandle: "h",
                       parentURI: "at://parent", rootURI: "at://root",
                       isRootPost: false, depth: 1)
        XCTAssertFalse(policy.needsRescrape(post, window: twoWeeks))
    }
}
