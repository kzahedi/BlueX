import XCTest
@testable import BlueX

final class BlueskyErrorTests: XCTestCase {
    func testEquatableAuthFailed() {
        XCTAssertEqual(BlueskyError.authFailed, BlueskyError.authFailed)
    }

    func testEquatableNotFound() {
        XCTAssertEqual(BlueskyError.notFound, BlueskyError.notFound)
    }

    func testEquatableRateLimited() {
        XCTAssertEqual(BlueskyError.rateLimited(retryAfter: 60), BlueskyError.rateLimited(retryAfter: 60))
        XCTAssertNotEqual(BlueskyError.rateLimited(retryAfter: 60), BlueskyError.rateLimited(retryAfter: 30))
    }

    func testEquatableNetworkError() {
        XCTAssertEqual(BlueskyError.networkError(underlying: "timeout"), BlueskyError.networkError(underlying: "timeout"))
        XCTAssertNotEqual(BlueskyError.networkError(underlying: "a"), BlueskyError.networkError(underlying: "b"))
    }

    func testErrorDescriptionAuthFailed() {
        let error = BlueskyError.authFailed
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("auth") ||
                      error.errorDescription!.lowercased().contains("credential"))
    }

    func testErrorDescriptionRateLimited() {
        let error = BlueskyError.rateLimited(retryAfter: 120)
        XCTAssertTrue(error.errorDescription!.contains("120"))
    }

    func testDifferentCasesNotEqual() {
        XCTAssertNotEqual(BlueskyError.authFailed, BlueskyError.notFound)
        XCTAssertNotEqual(BlueskyError.authFailed, BlueskyError.networkError(underlying: "x"))
    }
}
