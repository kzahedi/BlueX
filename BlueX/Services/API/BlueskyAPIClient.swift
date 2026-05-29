import Foundation

// Why: URLSessionProtocol lets tests inject a MockURLSession without making real HTTP calls.
// URLSession already implements data(for:) — we just expose it via protocol.
protocol URLSessionProtocol {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: URLSessionProtocol {}

// Why: A struct is ideal for a stateless HTTP client — no stored mutable state,
// no lifecycle management. The token is passed in per-call; ScrapeCoordinator owns it.
struct BlueskyAPIClient {
    private let baseURL: URL
    private let session: URLSessionProtocol

    init(baseURL: URL = URL(string: "https://bsky.social/xrpc")!,
         session: URLSessionProtocol = URLSession.shared) {
        self.baseURL = baseURL
        self.session = session
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

    private func perform<T: Codable>(request: URLRequest, as type: T.Type) async -> Result<T, BlueskyError> {
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
                // Bluesky returns 400 for malformed requests, deleted/blocked posts, or
                // unknown DIDs. Surfacing it as authFailed sent the user to Settings
                // even when their credentials were fine. Keep the body text so the
                // caller can decide whether to skip or escalate.
                let body = String(data: data, encoding: .utf8) ?? "<unparseable>"
                return .failure(.badRequest(message: body))
            case 401:
                return .failure(.authFailed)
            case 404:
                return .failure(.notFound)
            case 429:
                let retryAfter = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "60") ?? 60
                return .failure(.rateLimited(retryAfter: retryAfter))
            default:
                return .failure(.networkError(underlying: "HTTP \(http.statusCode)"))
            }
        } catch {
            return .failure(.networkError(underlying: error.localizedDescription))
        }
    }
}
