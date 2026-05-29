import XCTest
@testable import BlueX

/// Tests for the auto-retry behavior in `BlueskyAPIClient.perform`. We don't
/// actually sleep — `sleeper` is replaced with a no-op closure that just records
/// the wait. The mock session's scripted-response queue makes the first N calls
/// 429 and the (N+1)th succeed.
final class BlueskyAPIClientRateLimitTests: XCTestCase {

    // MARK: - Helpers

    /// A successful resolveHandle response body, for the success-after-N-429s case.
    private func resolveSuccessBody(did: String = "did:plc:test") -> Data {
        try! JSONEncoder().encode(["did": did])
    }

    private func ratelimited(retryAfter: Int = 1) -> MockURLSession.ScriptedResponse {
        MockURLSession.ScriptedResponse(
            data: Data(),
            statusCode: 429,
            headers: ["Retry-After": String(retryAfter)]
        )
    }

    private func ok(_ data: Data) -> MockURLSession.ScriptedResponse {
        MockURLSession.ScriptedResponse(data: data, statusCode: 200, headers: [:])
    }

    // MARK: - Tests

    func testRetriesOn429ThenSucceeds() async throws {
        let mock = MockURLSession()
        mock.scriptedResponses = [ratelimited(), ratelimited(), ok(resolveSuccessBody())]

        var sleeps: [UInt64] = []
        var observerCalls: [(TimeInterval, Int)] = []
        let client = BlueskyAPIClient(
            session: mock,
            onRateLimited: { delay, attempt in observerCalls.append((delay, attempt)) },
            sleeper: { ns in sleeps.append(ns) }
        )

        let result = await client.resolveHandle("test.bsky.social")
        guard case .success(let did) = result else {
            return XCTFail("expected success after two 429 retries, got \(result)")
        }
        XCTAssertEqual(did, "did:plc:test")
        XCTAssertEqual(mock.callCount, 3, "two 429s + one 200 = three calls")
        XCTAssertEqual(sleeps.count, 2)
        XCTAssertEqual(observerCalls.map(\.0), [1.0, 1.0])
        XCTAssertEqual(observerCalls.map(\.1), [1, 2], "attempts are 1-based")
    }

    func testRetriesExhaustedReturnsRateLimited() async throws {
        let mock = MockURLSession()
        // 6 × 429: 5 retries + the original = 6 attempts. After that, perform gives up.
        mock.scriptedResponses = Array(repeating: ratelimited(retryAfter: 2), count: 10)

        var observerCalls: [(TimeInterval, Int)] = []
        let client = BlueskyAPIClient(
            session: mock,
            onRateLimited: { delay, attempt in observerCalls.append((delay, attempt)) },
            maxRateLimitRetries: 3,
            sleeper: { _ in /* no-op */ }
        )

        let result = await client.resolveHandle("test.bsky.social")
        guard case .failure(let err) = result, case .rateLimited(let after) = err else {
            return XCTFail("expected .rateLimited after exhaustion, got \(result)")
        }
        XCTAssertEqual(after, 2.0)
        // Three retries means: 1st call (429) + retry 1 (429) + retry 2 (429) + retry 3 (429, returns).
        XCTAssertEqual(mock.callCount, 4, "first call + 3 retries before giving up")
        XCTAssertEqual(observerCalls.count, 3, "observer fires once per actual retry (not on the give-up turn)")
    }

    func testHonorsRetryAfterValue() async throws {
        let mock = MockURLSession()
        mock.scriptedResponses = [ratelimited(retryAfter: 17), ok(resolveSuccessBody())]

        var sleeps: [UInt64] = []
        let client = BlueskyAPIClient(
            session: mock,
            sleeper: { ns in sleeps.append(ns) }
        )

        _ = await client.resolveHandle("test.bsky.social")
        XCTAssertEqual(sleeps, [17 * 1_000_000_000])
    }

    /// 200 OK on the first try → no sleeping, no observer call.
    func testFirstResponseSuccessSkipsRetryPath() async throws {
        let mock = MockURLSession()
        mock.mockStatusCode = 200
        mock.mockData = resolveSuccessBody()

        var observerCalls = 0
        var sleeps = 0
        let client = BlueskyAPIClient(
            session: mock,
            onRateLimited: { _, _ in observerCalls += 1 },
            sleeper: { _ in sleeps += 1 }
        )

        let result = await client.resolveHandle("test.bsky.social")
        guard case .success = result else { return XCTFail("expected success") }
        XCTAssertEqual(observerCalls, 0)
        XCTAssertEqual(sleeps, 0)
    }

    /// Non-429 errors (404 etc.) are NOT retried; they surface immediately.
    func testNonRateLimitErrorsBypassRetry() async throws {
        let mock = MockURLSession()
        mock.scriptedResponses = [
            MockURLSession.ScriptedResponse(data: Data(), statusCode: 404, headers: [:])
        ]

        var observerCalls = 0
        let client = BlueskyAPIClient(
            session: mock,
            onRateLimited: { _, _ in observerCalls += 1 }
        )
        let result = await client.resolveHandle("test")
        XCTAssertEqual(observerCalls, 0)
        guard case .failure(let err) = result, err == .notFound else {
            return XCTFail("expected .notFound, got \(result)")
        }
        XCTAssertEqual(mock.callCount, 1)
    }
}
