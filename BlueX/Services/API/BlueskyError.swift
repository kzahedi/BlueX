import Foundation

// Why: Typed errors give the compiler and caller a complete picture of what can go wrong.
// This is better than throwing raw Error or String — callers switch on BlueskyError
// and handle each case explicitly, without string matching.
enum BlueskyError: Error {
    case authFailed                          // 401 — token expired or wrong credentials; the user needs to re-auth
    case badRequest(message: String)         // 400 — malformed request; programmer error or stale URI we shouldn't retry
    case rateLimited(retryAfter: TimeInterval)
    case networkError(underlying: String)   // String (not Error) so we can conform to Equatable
    case decodingError(underlying: String)
    case notFound
}

// Why: Equatable lets us use XCTAssertEqual in tests.
// We implement manually because associated values need custom comparison.
extension BlueskyError: Equatable {
    static func == (lhs: BlueskyError, rhs: BlueskyError) -> Bool {
        switch (lhs, rhs) {
        case (.authFailed, .authFailed): return true
        case (.notFound, .notFound): return true
        case let (.rateLimited(a), .rateLimited(b)): return a == b
        case let (.networkError(a), .networkError(b)): return a == b
        case let (.decodingError(a), .decodingError(b)): return a == b
        case let (.badRequest(a), .badRequest(b)): return a == b
        default: return false
        }
    }
}

extension BlueskyError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .authFailed:
            return "Bluesky authentication failed. Check credentials in Settings."
        case .badRequest(let message):
            return "Bluesky API rejected request: \(message)"
        case .rateLimited(let retryAfter):
            return "Rate limited. Retry in \(Int(retryAfter))s."
        case .networkError(let msg):
            return "Network error: \(msg)"
        case .decodingError(let msg):
            return "Response parsing failed: \(msg)"
        case .notFound:
            return "Resource not found on Bluesky."
        }
    }
}
