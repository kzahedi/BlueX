import XCTest
@testable import BlueX

/// The shared session must leave **nothing** on the internal disk. Two separate
/// stores are at stake and they are easy to confuse:
///
/// * `~/Library/Caches/<tool>` — the response body cache (`urlCache`). It grew ~1 MB
///   per minute of scraping and filled the internal disk on 2026-08-04.
/// * `~/Library/HTTPStorages/<tool>/httpstorages.sqlite` (+ `-wal`, `-shm`) — the
///   cookie / credential / HSTS store. Measured at 232 KB and not growing, so not a
///   space risk; it is simply the last internal-disk write surface.
///
/// `.ephemeral` removes both. Asserted rather than commented because switching back
/// to `.default` or `URLSession.shared` is a one-line regression.
final class EphemeralHTTPSessionTests: XCTestCase {

    func testSharedSessionHasNoResponseCache() {
        XCTAssertNil(EphemeralHTTPSession.shared.configuration.urlCache,
                     "shared session must have no URL cache at all, on disk or in memory")
    }

    /// Even with no cache installed, the policy must forbid cache *reads*: a
    /// `getPostThread` refresh exists to discover NEW replies, so a hit would return
    /// the reply set we already have and silently under-collect.
    func testSharedSessionIgnoresLocalCacheData() {
        XCTAssertEqual(EphemeralHTTPSession.shared.configuration.requestCachePolicy,
                       .reloadIgnoringLocalCacheData)
    }

    /// Ephemeral cookie storage is in-memory and per-session; the process-wide
    /// `HTTPCookieStorage.shared` is the one backed by `HTTPStorages` on disk.
    func testSharedSessionDoesNotUsePersistentCookieStorage() {
        XCTAssertFalse(EphemeralHTTPSession.shared.configuration.httpCookieStorage
                       === HTTPCookieStorage.shared,
                       "must not use the on-disk shared cookie jar")
    }

    /// Same for credentials — all three endpoints authenticate with a bearer token or
    /// nothing, so nothing needs to survive the process.
    func testSharedSessionDoesNotUsePersistentCredentialStorage() {
        XCTAssertFalse(EphemeralHTTPSession.shared.configuration.urlCredentialStorage
                       === URLCredentialStorage.shared,
                       "must not use the on-disk shared credential store")
    }

    func testSharedSessionIsNotTheProcessSharedSession() {
        XCTAssertFalse(EphemeralHTTPSession.shared === URLSession.shared)
    }

    /// One session, not three: `BlueskyAPIClient.uncachedSession` must be an alias, so
    /// a single connection pool serves the scraper and both annotation clients.
    func testAllClientsShareOneSession() {
        XCTAssertTrue(BlueskyAPIClient.uncachedSession === EphemeralHTTPSession.shared)
    }
}
