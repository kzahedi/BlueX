import Foundation

// Why: URLSessionProtocol lets tests inject a MockURLSession without making real HTTP calls.
// URLSession already implements data(for:) — we just expose it via protocol.
protocol URLSessionProtocol {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: URLSessionProtocol {}

/// Shape of the JSON body Bluesky returns on 4xx errors. Both `error` (the code
/// like "ExpiredToken" / "RecordNotFound") and `message` (free-form text) may be
/// absent; we treat all fields as optional.
private struct BlueskyAPIErrorBody: Decodable {
    let error: String?
    let message: String?
}

/// Called when the client receives a 429 and is about to sleep before retrying.
/// `retryAfter` is the seconds to wait; `attempt` is the 1-based retry attempt.
/// Used by the CLI to print a "rate-limited, waiting Ns" notice and by the GUI
/// to surface a `rateLimitWaiting` state to the sidebar. Synchronous because the
/// observer's job is to record state, not to do work; the sleep happens in `perform`.
typealias RateLimitObserver = @Sendable (TimeInterval, Int) -> Void

// Why: A struct is ideal for a stateless HTTP client — no stored mutable state,
// no lifecycle management. The token is passed in per-call; ScrapeCoordinator owns it.
struct BlueskyAPIClient {
    private let baseURL: URL
    private let session: URLSessionProtocol
    private let onRateLimited: RateLimitObserver?
    private let sleeper: @Sendable (UInt64) async -> Void
    /// Hard ceiling on consecutive 429s before we give up and surface the failure to
    /// the caller. Five attempts at the default ~60s Retry-After buys ~5 minutes
    /// of patience; beyond that, something is wrong (token-level throttle, etc.).
    private let maxRateLimitRetries: Int

    init(baseURL: URL = URL(string: "https://bsky.social/xrpc")!,
         session: URLSessionProtocol = URLSession.shared,
         onRateLimited: RateLimitObserver? = nil,
         maxRateLimitRetries: Int = 5,
         sleeper: @escaping @Sendable (UInt64) async -> Void = { ns in
             try? await Task.sleep(nanoseconds: ns)
         }) {
        self.baseURL = baseURL
        self.session = session
        self.onRateLimited = onRateLimited
        self.maxRateLimitRetries = maxRateLimitRetries
        self.sleeper = sleeper
    }

    // MARK: - Auth

    func createSession(handle: String, password: String) async -> Result<ATProtoSession, BlueskyError> {
        let url = baseURL.appendingPathComponent("com.atproto.server.createSession")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["identifier": handle, "password": password]
        guard let bodyData = try? JSONEncoder().encode(body) else {
            return .failure(.decodingError(underlying: "Failed to encode credentials"))
        }
        request.httpBody = bodyData

        return await perform(request: request, as: ATProtoSession.self)
    }

    // MARK: - DID Resolution

    func resolveHandle(_ handle: String) async -> Result<String, BlueskyError> {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("com.atproto.identity.resolveHandle"),
            resolvingAgainstBaseURL: false
        ) else {
            return .failure(.networkError(underlying: "Invalid base URL"))
        }
        components.queryItems = [URLQueryItem(name: "handle", value: handle)]

        guard let url = components.url else {
            return .failure(.networkError(underlying: "Could not build resolve URL for handle: \(handle)"))
        }

        struct ResolveResponse: Codable { let did: String }
        let result = await perform(request: URLRequest(url: url), as: ResolveResponse.self)
        return result.map { $0.did }
    }

    // MARK: - Profile

    func getProfile(did: String, token: String) async -> Result<ATProtoProfile, BlueskyError> {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("app.bsky.actor.getProfile"),
            resolvingAgainstBaseURL: false
        ) else {
            return .failure(.networkError(underlying: "Invalid base URL"))
        }
        components.queryItems = [URLQueryItem(name: "actor", value: did)]

        guard let url = components.url else {
            return .failure(.networkError(underlying: "Could not build profile URL"))
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return await perform(request: request, as: ATProtoProfile.self)
    }

    // MARK: - Feed

    func getAuthorFeed(did: String, token: String, cursor: String? = nil, limit: Int = 100) async -> Result<ATProtoFeedResponse, BlueskyError> {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("app.bsky.feed.getAuthorFeed"),
            resolvingAgainstBaseURL: false
        ) else {
            return .failure(.networkError(underlying: "Invalid base URL"))
        }
        var queryItems = [
            URLQueryItem(name: "actor", value: did),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "filter", value: "posts_no_replies")
        ]
        if let cursor = cursor {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            return .failure(.networkError(underlying: "Could not build feed URL"))
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return await perform(request: request, as: ATProtoFeedResponse.self)
    }

    // MARK: - Thread

    func getPostThread(uri: String, token: String, depth: Int = 10) async -> Result<ATProtoThreadResponse, BlueskyError> {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("app.bsky.feed.getPostThread"),
            resolvingAgainstBaseURL: false
        ) else {
            return .failure(.networkError(underlying: "Invalid base URL"))
        }
        components.queryItems = [
            URLQueryItem(name: "uri", value: uri),
            URLQueryItem(name: "depth", value: String(depth))
        ]

        guard let url = components.url else {
            return .failure(.networkError(underlying: "Could not build thread URL"))
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return await perform(request: request, as: ATProtoThreadResponse.self)
    }

    // MARK: - Private

    /// Executes one request with transparent 429 retry.
    ///
    /// On 429 we read `Retry-After`, notify `onRateLimited`, sleep, and re-issue the
    /// same request — up to `maxRateLimitRetries` times. The caller never sees a
    /// retryable 429; only an exhausted-retry 429 surfaces as `.rateLimited`. This
    /// is what makes long-running scrapes (NYT-class accounts) traverse the full
    /// history without losing their place: a hit on the 3,000-req/hr budget pauses
    /// at exactly this method, not several layers up where un-visited posts would
    /// be silently abandoned.
    private func perform<T: Codable>(request: URLRequest, as type: T.Type) async -> Result<T, BlueskyError> {
        var attempt = 0
        while true {
            do {
                let (data, response) = try await session.data(for: request)

                // Why: URLResponse is the base class; we cast to HTTPURLResponse to read status code.
                // For HTTP URLs this cast is always safe.
                guard let http = response as? HTTPURLResponse else {
                    return .failure(.networkError(underlying: "Non-HTTP response"))
                }

                switch http.statusCode {
                case 200...299:
                    do {
                        let decoded = try JSONDecoder().decode(T.self, from: data)
                        return .success(decoded)
                    } catch {
                        return .failure(.decodingError(underlying: error.localizedDescription))
                    }
                case 400:
                    // Bluesky returns 400 for several distinct conditions, and the
                    // error code in the JSON body is the distinguishing signal:
                    //   {"error": "ExpiredToken", …} — session JWT timed out (~2 h),
                    //       must re-auth and retry. Same recovery as 401.
                    //   {"error": "InvalidToken", …} — same.
                    //   {"error": "RecordNotFound" / "NotFound", …} — deleted post.
                    //   anything else — malformed request, treat as terminal.
                    let body = String(data: data, encoding: .utf8) ?? "<unparseable>"
                    let parsed = try? JSONDecoder().decode(BlueskyAPIErrorBody.self, from: data)
                    switch parsed?.error {
                    case "ExpiredToken", "InvalidToken":
                        return .failure(.authFailed)
                    case "RecordNotFound", "NotFound":
                        return .failure(.notFound)
                    default:
                        return .failure(.badRequest(message: body))
                    }
                case 401:
                    return .failure(.authFailed)
                case 404:
                    return .failure(.notFound)
                case 429:
                    let retryAfter = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "60") ?? 60
                    attempt += 1
                    if attempt > maxRateLimitRetries {
                        return .failure(.rateLimited(retryAfter: retryAfter))
                    }
                    onRateLimited?(retryAfter, attempt)
                    await sleeper(UInt64(max(retryAfter, 0) * 1_000_000_000))
                    continue   // retry the same request
                default:
                    return .failure(.networkError(underlying: "HTTP \(http.statusCode)"))
                }
            } catch {
                return .failure(.networkError(underlying: error.localizedDescription))
            }
        }
    }
}
