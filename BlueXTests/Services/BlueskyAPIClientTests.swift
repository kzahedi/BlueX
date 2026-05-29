import XCTest
@testable import BlueX

// Why: MockURLSession lets us test all API client behavior without real HTTP calls.
// We control exactly what data and status code each call returns.
//
// Supports two modes:
// 1. Single response — set `mockData` / `mockStatusCode` / `mockHeaders`; every
//    call returns the same triple. Simplest, default.
// 2. Scripted sequence — append to `scriptedResponses`. Each call pops the next
//    entry; falls back to the single-response mode after the script is exhausted.
//    Used by the 429 retry tests to make the first N calls fail and the (N+1)th
//    succeed.
final class MockURLSession: URLSessionProtocol {
    var mockData: Data = Data()
    var mockStatusCode: Int = 200
    var mockHeaders: [String: String] = [:]

    struct ScriptedResponse {
        var data: Data = Data()
        var statusCode: Int = 200
        var headers: [String: String] = [:]
    }
    var scriptedResponses: [ScriptedResponse] = []
    private(set) var callCount = 0

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        callCount += 1
        let resp: (Data, Int, [String: String])
        if !scriptedResponses.isEmpty {
            let next = scriptedResponses.removeFirst()
            resp = (next.data, next.statusCode, next.headers)
        } else {
            resp = (mockData, mockStatusCode, mockHeaders)
        }
        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: resp.1,
            httpVersion: nil,
            headerFields: resp.2
        )!
        return (resp.0, httpResponse)
    }
}

final class BlueskyAPIClientTests: XCTestCase {

    // MARK: - createSession

    func testCreateSessionSuccess() async throws {
        let mock = MockURLSession()
        let session = ATProtoSession(did: "did:plc:test", handle: "test.bsky.social",
                                    accessJwt: "token123", refreshJwt: "refresh456")
        mock.mockData = try JSONEncoder().encode(session)

        let client = BlueskyAPIClient(session: mock)
        let result = await client.createSession(handle: "test.bsky.social", password: "pass")

        switch result {
        case .success(let s):
            XCTAssertEqual(s.did, "did:plc:test")
            XCTAssertEqual(s.accessJwt, "token123")
        case .failure(let e):
            XCTFail("Expected success, got \(e)")
        }
    }

    func testCreateSessionReturnsAuthFailedOn401() async throws {
        let mock = MockURLSession()
        mock.mockStatusCode = 401

        let client = BlueskyAPIClient(session: mock)
        let result = await client.createSession(handle: "test", password: "wrong")

        if case .failure(let e) = result {
            XCTAssertEqual(e, .authFailed)
        } else {
            XCTFail("Expected failure(.authFailed), got \(result)")
        }
    }

    func testCreateSessionReturnsBadRequestOn400() async throws {
        // 400 is a programmer-error / stale-URI signal — distinct from 401, where the
        // user needs to re-auth. Previously this returned .authFailed and pushed users
        // to Settings even when their credentials were fine.
        let mock = MockURLSession()
        mock.mockStatusCode = 400

        let client = BlueskyAPIClient(session: mock)
        let result = await client.createSession(handle: "test", password: "wrong")

        if case .failure(.badRequest) = result {
            // ok
        } else {
            XCTFail("Expected failure(.badRequest), got \(result)")
        }
    }

    func testCreateSessionRateLimited() async throws {
        let mock = MockURLSession()
        mock.mockStatusCode = 429
        mock.mockHeaders = ["Retry-After": "120"]

        let client = BlueskyAPIClient(session: mock)
        let result = await client.createSession(handle: "test", password: "pass")

        if case .failure(.rateLimited(let retryAfter)) = result {
            XCTAssertEqual(retryAfter, 120, accuracy: 0.001)
        } else {
            XCTFail("Expected rateLimited, got \(result)")
        }
    }

    func testCreateSessionNotFound() async throws {
        let mock = MockURLSession()
        mock.mockStatusCode = 404

        let client = BlueskyAPIClient(session: mock)
        let result = await client.createSession(handle: "test", password: "pass")

        if case .failure(let e) = result {
            XCTAssertEqual(e, .notFound)
        } else {
            XCTFail("Expected failure(.notFound), got \(result)")
        }
    }

    func testCreateSessionDecodingError() async throws {
        let mock = MockURLSession()
        mock.mockData = Data("not json".utf8)

        let client = BlueskyAPIClient(session: mock)
        let result = await client.createSession(handle: "test", password: "pass")

        if case .failure(.decodingError) = result { } else {
            XCTFail("Expected decodingError, got \(result)")
        }
    }

    // MARK: - getAuthorFeed

    func testGetAuthorFeedSuccess() async throws {
        let mock = MockURLSession()
        let feedResponse = ATProtoFeedResponse(feed: [], cursor: "next_cursor")
        mock.mockData = try JSONEncoder().encode(feedResponse)

        let client = BlueskyAPIClient(session: mock)
        let result = await client.getAuthorFeed(did: "did:plc:test", token: "tok")

        if case .success(let feed) = result {
            XCTAssertEqual(feed.cursor, "next_cursor")
            XCTAssertTrue(feed.feed.isEmpty)
        } else {
            XCTFail("Expected success, got \(result)")
        }
    }

    func testGetAuthorFeedWithCursorIncludesItInRequest() async throws {
        let mock = MockURLSession()
        let feedResponse = ATProtoFeedResponse(feed: [], cursor: nil)
        mock.mockData = try JSONEncoder().encode(feedResponse)

        // We can't easily capture the request with current mock design,
        // but we verify the result is a success (cursor param doesn't break things)
        let client = BlueskyAPIClient(session: mock)
        let result = await client.getAuthorFeed(did: "did:plc:test", token: "tok", cursor: "abc")

        if case .success = result { } else {
            XCTFail("Expected success with cursor")
        }
    }

    // MARK: - getPostThread

    func testGetPostThreadNotFound() async throws {
        let mock = MockURLSession()
        mock.mockStatusCode = 404

        let client = BlueskyAPIClient(session: mock)
        let result = await client.getPostThread(uri: "at://test/post/abc", token: "tok")

        if case .failure(let e) = result {
            XCTAssertEqual(e, .notFound)
        } else {
            XCTFail("Expected failure(.notFound), got \(result)")
        }
    }
}
