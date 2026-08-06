import XCTest
import SwiftData
@testable import BlueX

/// Regression cover for the 2026-08-04 truncation: the CLI allowed exactly ONE
/// re-authentication per account phase, so the second token expiry inside a
/// multi-hour account abandoned the feed mid-scrape and marked the run failed.
final class ScrapeSessionTests: XCTestCase {

    // MARK: - Helpers

    /// Builds a session whose createSession returns "tokN" and records its calls.
    private func makeSession(
        startToken: String = "tok0",
        issuedAt: Date = Date(),
        refreshAfter: TimeInterval = ScrapeSession.defaultRefreshAfter,
        maxReauths: Int = ScrapeSession.defaultMaxReauths,
        now: @escaping () -> Date = Date.init,
        authResults: [Result<String, BlueskyError>]? = nil,
        counter: AuthCounter = AuthCounter()
    ) -> (ScrapeSession, AuthCounter) {
        var scripted = authResults
        let session = ScrapeSession(
            token: startToken,
            issuedAt: issuedAt,
            refreshAfter: refreshAfter,
            maxReauths: maxReauths,
            now: now,
            onReauth: { counter.reasons.append($0) },
            authenticate: {
                counter.calls += 1
                if var s = scripted, !s.isEmpty {
                    let next = s.removeFirst()
                    scripted = s
                    return next
                }
                return .success("tok\(counter.calls)")
            }
        )
        return (session, counter)
    }

    /// Reference box so the escaping authenticate closure can record state.
    final class AuthCounter {
        var calls = 0
        var reasons: [ScrapeSession.RefreshReason] = []
    }

    // MARK: - The bug

    func testTwoConsecutiveTokenExpiriesBothRecover() async throws {
        // THE regression test. Against the old `for attempt in 0...1` CLI loop the
        // second .authFailed fell through to the generic catch and killed the phase.
        let (session, counter) = makeSession()

        var attempt = 0
        var tokensSeen: [String] = []
        let result = try await session.withToken { token -> Int in
            attempt += 1
            tokensSeen.append(token)
            if attempt <= 2 { throw BlueskyError.authFailed }
            return 42
        }

        XCTAssertEqual(result, 42, "operation must complete after two expiries")
        XCTAssertEqual(attempt, 3, "one initial try plus one retry per expiry")
        XCTAssertEqual(counter.calls, 2, "createSession called once per expiry")
        XCTAssertEqual(tokensSeen, ["tok0", "tok1", "tok2"],
                       "each retry must use the freshly issued token")
        XCTAssertEqual(counter.reasons, [.expired, .expired])
    }

    func testManySequentialExpiriesWithinBudgetAllRecover() async throws {
        // A 12-hour account phase crosses the ~2 h boundary several times.
        let (session, counter) = makeSession()
        var attempt = 0
        let result = try await session.withToken { _ -> String in
            attempt += 1
            if attempt <= 6 { throw BlueskyError.authFailed }
            return "done"
        }
        XCTAssertEqual(result, "done")
        XCTAssertEqual(counter.calls, 6)
    }

    // MARK: - Fatal: bad credentials

    func testCreateSessionFailureIsFatalAndNotRetried() async {
        let (session, counter) = makeSession(authResults: [.failure(.authFailed)])

        var attempt = 0
        do {
            _ = try await session.withToken { _ -> Int in
                attempt += 1
                throw BlueskyError.authFailed
            }
            XCTFail("expected ReauthenticationFailed")
        } catch let error as ReauthenticationFailed {
            XCTAssertEqual(error.underlying, .authFailed)
        } catch {
            XCTFail("wrong error: \(error)")
        }

        XCTAssertEqual(attempt, 1, "operation must not be retried after dead credentials")
        XCTAssertEqual(counter.calls, 1, "createSession must not be hammered")
    }

    // MARK: - The bound

    func testEndlessAuthFailureTerminatesAtTheBudget() async {
        // createSession keeps succeeding, the API keeps rejecting the token. Must
        // terminate, not hang.
        let (session, counter) = makeSession(maxReauths: 4)

        var attempt = 0
        do {
            _ = try await session.withToken { _ -> Int in
                attempt += 1
                throw BlueskyError.authFailed
            }
            XCTFail("expected AuthRetryBudgetExhausted")
        } catch let error as AuthRetryBudgetExhausted {
            XCTAssertEqual(error.limit, 4)
        } catch {
            XCTFail("wrong error: \(error)")
        }

        XCTAssertEqual(counter.calls, 4, "exactly maxReauths re-auths, then give up")
        XCTAssertEqual(attempt, 5, "initial try plus one per re-auth")
    }

    func testSpuriousRefreshSignalsAlsoTerminateAtTheBudget() async {
        // An operation that keeps asking for a proactive refresh even though the
        // session is fresh must not be able to restart forever either.
        let (session, _) = makeSession(maxReauths: 3)
        do {
            _ = try await session.withToken { _ -> Int in throw TokenRefreshDue() }
            XCTFail("expected AuthRetryBudgetExhausted")
        } catch is AuthRetryBudgetExhausted {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - Proactive refresh

    func testProactiveRefreshFiresWhenSessionIsOlderThanThreshold() async throws {
        // Injected clock — no sleeping. Session issued 80 min ago, threshold 75 min.
        let issued = Date(timeIntervalSince1970: 0)
        let clock = Box(issued.addingTimeInterval(80 * 60))
        let (session, counter) = makeSession(
            issuedAt: issued, refreshAfter: 75 * 60, now: { clock.value }
        )

        XCTAssertTrue(session.isRefreshDue)

        var tokenSeen: String?
        _ = try await session.withToken { token -> Int in
            tokenSeen = token
            return 1
        }

        XCTAssertEqual(counter.calls, 1, "refreshed before running, without any failure")
        XCTAssertEqual(counter.reasons, [.scheduled])
        XCTAssertEqual(tokenSeen, "tok1")
        XCTAssertFalse(session.isRefreshDue, "clock restarts at the new session")
    }

    func testFreshSessionDoesNotRefresh() async throws {
        let issued = Date(timeIntervalSince1970: 0)
        let clock = Box(issued.addingTimeInterval(10 * 60))
        let (session, counter) = makeSession(
            issuedAt: issued, refreshAfter: 75 * 60, now: { clock.value }
        )
        var tokenSeen: String?
        _ = try await session.withToken { token -> Int in tokenSeen = token; return 1 }
        XCTAssertEqual(counter.calls, 0)
        XCTAssertEqual(tokenSeen, "tok0")
    }

    func testRefreshDueSignalFromInsideOperationRestartsWithFreshToken() async throws {
        // This is what the CLI's per-post callback does: at a safe boundary it
        // throws TokenRefreshDue rather than waiting for the token to fail.
        let issued = Date(timeIntervalSince1970: 0)
        let clock = Box(issued)
        let (session, counter) = makeSession(
            issuedAt: issued, refreshAfter: 75 * 60, now: { clock.value }
        )

        var attempt = 0
        var tokensSeen: [String] = []
        let result = try await session.withToken { token -> Int in
            attempt += 1
            tokensSeen.append(token)
            if attempt == 1 {
                clock.value = issued.addingTimeInterval(76 * 60)   // session aged mid-flight
                throw TokenRefreshDue()
            }
            return 7
        }

        XCTAssertEqual(result, 7)
        XCTAssertEqual(counter.calls, 1)
        XCTAssertEqual(counter.reasons, [.scheduled])
        XCTAssertEqual(tokensSeen, ["tok0", "tok1"])
    }

    // MARK: - Everything else must pass through untouched

    func testUnrelatedErrorsPropagateWithoutReauth() async {
        let (session, counter) = makeSession()
        do {
            _ = try await session.withToken { _ -> Int in
                throw BlueskyError.networkError(underlying: "offline")
            }
            XCTFail("expected the network error to propagate")
        } catch let error as BlueskyError {
            XCTAssertEqual(error, .networkError(underlying: "offline"))
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertEqual(counter.calls, 0, "a network failure is not an auth failure")
    }

    func testCancellationPropagatesCleanly() async {
        let (session, counter) = makeSession()
        do {
            _ = try await session.withToken { _ -> Int in throw CancellationError() }
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // expected — Ctrl-C stays an exit-0 path in the CLI
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertEqual(counter.calls, 0)
    }

    // MARK: - End-to-end through the real FeedScraper + API client

    /// The double expiry as the CLI actually meets it: a real FeedScraper over a
    /// MockURLSession that returns 400/ExpiredToken twice, with the resumeCursor
    /// carrying the scrape forward each time.
    func testFeedScrapeSurvivesTwoExpiriesEndToEnd() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: TrackedAccount.self, AccountGroup.self,
            Post.self, Annotation.self, AccountSnapshot.self,
            ScrapeLog.self, ModelConfig.self, CoordinatorState.self,
            configurations: config
        )
        let context = ModelContext(container)

        let did = "did:plc:expiry"
        let account = TrackedAccount(did: did, handle: "test.de", displayName: "Test",
                                     startAt: Date(timeIntervalSince1970: 0))
        context.insert(account)
        try context.save()

        let expired = try JSONSerialization.data(withJSONObject: [
            "error": "ExpiredToken", "message": "Token has expired"
        ])
        let mock = MockURLSession()
        mock.scriptedResponses = [
            // page 1 → two posts, cursor set
            .init(data: try feedJSON(did: did, ids: [0, 1], cursor: "c1")),
            // page 2 → token expired
            .init(data: expired, statusCode: 400),
            // retry after re-auth: page 1 again (resume cursor), then expired again
            .init(data: try feedJSON(did: did, ids: [2, 3], cursor: "c2")),
            .init(data: expired, statusCode: 400),
            // second re-auth: final page, no cursor → scrape completes
            .init(data: try feedJSON(did: did, ids: [4], cursor: nil))
        ]

        let client = BlueskyAPIClient(session: mock)
        let scraper = FeedScraper(api: client, context: context)
        var authCalls = 0
        let session = ScrapeSession(
            token: "tok0", issuedAt: Date(),
            authenticate: { authCalls += 1; return .success("tok\(authCalls)") }
        )

        let stored = try await session.withToken { token in
            try await scraper.scrape(account: account, token: token)
        }

        XCTAssertEqual(authCalls, 2, "one re-auth per expiry")
        XCTAssertEqual(stored, 1, "the final attempt resumed at the cursor, so it stores only the last page")
        let posts = try context.fetch(FetchDescriptor<Post>())
        XCTAssertEqual(Set(posts.map(\.uri)).count, 5, "all five posts survived the expiries")
        let logs = try context.fetch(FetchDescriptor<ScrapeLog>())
        XCTAssertTrue(logs.contains { $0.status == "complete" },
                      "the feed scrape ran to completion instead of being abandoned")
    }

    private func feedJSON(did: String, ids: [Int], cursor: String?) throws -> Data {
        var feed: [[String: Any]] = []
        for i in ids {
            feed.append([
                "post": [
                    "uri": "at://\(did)/app.bsky.feed.post/post\(i)",
                    "cid": "cid\(i)",
                    "author": ["did": did, "handle": "test.de"],
                    "record": ["text": "Post \(i)", "createdAt": "2024-06-01T10:00:00.000Z"],
                    "indexedAt": "2024-06-01T10:00:00.000Z"
                ]
            ])
        }
        var response: [String: Any] = ["feed": feed]
        if let cursor { response["cursor"] = cursor }
        return try JSONSerialization.data(withJSONObject: response)
    }
}

/// Minimal mutable box so escaping test closures can share a clock.
private final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}
