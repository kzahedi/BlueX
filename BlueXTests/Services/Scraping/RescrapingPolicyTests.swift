import XCTest
@testable import BlueX

final class RescrapingPolicyTests: XCTestCase {
    let policy = RescrapingPolicy()

    private func makeRootPost(ageHours: Double, lastCheckedHoursAgo: Double? = nil) -> Post {
        let createdAt = Date().addingTimeInterval(-ageHours * 3600)
        let post = Post(uri: "at://test/\(UUID())", text: "t", createdAt: createdAt,
                       authorDID: "did:test", authorHandle: "test",
                       parentURI: nil, rootURI: "at://test/r",
                       isRootPost: true, depth: 0)
        if let h = lastCheckedHoursAgo {
            post.replyTreeLastChecked = Date().addingTimeInterval(-h * 3600)
        }
        return post
    }

    func testPostUnder48hGets6hInterval() throws {
        let post = makeRootPost(ageHours: 24)
        let interval = try XCTUnwrap(policy.recheckInterval(for: post))
        XCTAssertEqual(interval, 6 * 3600, accuracy: 1)
    }

    func testPost3DaysGets24hInterval() throws {
        let post = makeRootPost(ageHours: 72)
        let interval = try XCTUnwrap(policy.recheckInterval(for: post))
        XCTAssertEqual(interval, 86400, accuracy: 1)
    }

    func testPost14DaysGets3DayInterval() throws {
        let post = makeRootPost(ageHours: 14 * 24)
        let interval = try XCTUnwrap(policy.recheckInterval(for: post))
        XCTAssertEqual(interval, 3 * 86400, accuracy: 1)
    }

    func testPost60DaysGetsWeeklyInterval() throws {
        let post = makeRootPost(ageHours: 60 * 24)
        let interval = try XCTUnwrap(policy.recheckInterval(for: post))
        XCTAssertEqual(interval, 7 * 86400, accuracy: 1)
    }

    func testPostOver90DaysReturnsNil() {
        let post = makeRootPost(ageHours: 91 * 24)
        XCTAssertNil(policy.recheckInterval(for: post))
    }

    func testNonRootPostReturnsNil() {
        let post = Post(uri: "at://test/r", text: "reply", createdAt: Date(),
                       authorDID: "d", authorHandle: "h",
                       parentURI: "at://parent", rootURI: "at://root",
                       isRootPost: false, depth: 1)
        XCTAssertNil(policy.recheckInterval(for: post))
    }

    func testNeedsRescrapeWhenNeverChecked() {
        let post = makeRootPost(ageHours: 1)
        XCTAssertTrue(policy.needsRescrape(post))
    }

    func testDoesNotNeedRescrapeWhenRecentlyChecked() {
        // Post is 1h old (6h interval), checked 30 min ago → NOT due
        let post = makeRootPost(ageHours: 1, lastCheckedHoursAgo: 0.5)
        XCTAssertFalse(policy.needsRescrape(post))
    }

    func testNeedsRescrapeWhenOverdue() {
        // Post is 1h old (6h interval), last checked 7h ago → overdue
        let post = makeRootPost(ageHours: 1, lastCheckedHoursAgo: 7)
        XCTAssertTrue(policy.needsRescrape(post))
    }
}
