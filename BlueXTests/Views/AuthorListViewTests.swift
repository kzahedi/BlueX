// BlueXTests/Views/AuthorListViewTests.swift
import XCTest
@testable import BlueX

/// Covers `AuthorListView.shouldSkipReload` — the pure decision behind the fix for
/// "everytime I look at a message and go back, the authors list is regenerated."
/// `.task(id:)` re-runs on every re-appearance of the view, not only on a genuine filter
/// change, so this is the one place that tells a harmless re-appearance apart from work
/// that actually needs to happen. Each of the four cases below is exactly where a
/// plausible implementation goes subtly wrong.
final class AuthorListViewTests: XCTestCase {

    /// Same key, data already present (`.loaded`) — a bare re-appearance must skip.
    func testSkipsWhenSameKeyAlreadyLoaded() {
        let skip = AuthorListView.shouldSkipReload(
            force: false, loadedKey: "k", currentKey: "k", loadState: .loaded)
        XCTAssertTrue(skip, "re-appearing with an unchanged filter must not re-query")
    }

    /// A genuine filter change (different key) must still reload, even though something
    /// was loaded before.
    func testReloadsWhenKeyChanges() {
        let skip = AuthorListView.shouldSkipReload(
            force: false, loadedKey: "old", currentKey: "new", loadState: .loaded)
        XCTAssertFalse(skip, "a changed filter must never be swallowed by the skip")
    }

    /// A previous load that *failed* must not be treated as loaded — otherwise the error
    /// state becomes permanent and the user can never retry. Exercised both with a key
    /// that still happens to equal `loadedKey` (as it would right after
    /// `AuthorStatsViewModel.loadAuthors` fails without having cleared it) and with the
    /// view-model's actual contract, where a failure clears `loadedAuthorsKey` to `nil`.
    func testDoesNotSkipAfterAFailedLoadEvenIfKeyStillMatches() {
        let skip = AuthorListView.shouldSkipReload(
            force: false, loadedKey: "k", currentKey: "k", loadState: .failed("boom"))
        XCTAssertFalse(skip, "a failed load must always allow a retry")
    }

    func testDoesNotSkipAfterAFailedLoadWithClearedKey() {
        let skip = AuthorListView.shouldSkipReload(
            force: false, loadedKey: nil, currentKey: "k", loadState: .failed("boom"))
        XCTAssertFalse(skip)
    }

    /// An empty result for a filter is a legitimate loaded state — it must skip exactly
    /// like a non-empty one, not be treated as "never loaded" and re-queried forever.
    /// (Nothing here differs by row count: the decision only ever sees the key and
    /// `loadState`, which is what makes "loaded, zero matches" indistinguishable from
    /// "loaded, many matches" — and correctly so.)
    func testSkipsOnALegitimateZeroResultLoad() {
        let skip = AuthorListView.shouldSkipReload(
            force: false, loadedKey: "k", currentKey: "k", loadState: .loaded)
        XCTAssertTrue(skip, "a zero-match load is still a loaded state, not 'never loaded'")
    }

    /// Never queried at all (`loadedKey == nil`) must never skip.
    func testDoesNotSkipWhenNeverLoaded() {
        let skip = AuthorListView.shouldSkipReload(
            force: false, loadedKey: nil, currentKey: "k", loadState: .idle)
        XCTAssertFalse(skip)
    }

    /// The manual refresh control must force a reload, bypassing the skip — even for the
    /// exact case that would otherwise skip (same key, already loaded).
    func testForceAlwaysReloadsEvenWhenSameKeyAlreadyLoaded() {
        let skip = AuthorListView.shouldSkipReload(
            force: true, loadedKey: "k", currentKey: "k", loadState: .loaded)
        XCTAssertFalse(skip, "force must bypass the skip unconditionally")
    }
}
