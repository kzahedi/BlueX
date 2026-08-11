import XCTest
@testable import BlueX

/// Values here are derived from `StoreFixture.make()`'s seven reply authors:
///   did:a (1), did:b (2), did:c (3), did:n9 (9), did:n10 (10), did:n99 (99), did:n100 (100)
/// Ranked by reply count: n100, n99, n10, n9, c, b, a.
@MainActor
final class AuthorStatsViewModelTests: XCTestCase {
    // Every test gets its own `UserDefaults` suite so persistence (first-run default,
    // restore, clear-survives-reload) never touches — or is polluted by — the real
    // `.standard` domain or another test's leftovers.
    private var defaultsSuiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "AuthorStatsViewModelTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaults = nil
        super.tearDown()
    }

    private func makeVM() -> AuthorStatsViewModel {
        AuthorStatsViewModel(defaults: defaults)
    }

    private func makeReader() throws -> AggregateReader {
        try AggregateReader(storeURL: try StoreFixture.make())
    }

    func testLoadsPopulation() async throws {
        let vm = makeVM()
        await vm.loadPopulation(reader: try makeReader())
        XCTAssertEqual(vm.population.totalAuthors, 7)
        if case .loaded = vm.loadState {} else { XCTFail("expected .loaded") }
    }

    func testLoadsAuthorsRespectingSortAndCap() async throws {
        let vm = makeVM()
        vm.minRepliesText = ""  // this test exercises sort/cap, not the min-replies default
        vm.sort = .replyCount
        vm.displayCap = 2
        await vm.loadAuthors(reader: try makeReader())
        XCTAssertEqual(vm.authors.map(\.did), ["did:n100", "did:n99"])
    }

    /// A cap that hides how much it hides would misrepresent coverage.
    func testTotalMatchingReportsBeyondTheCap() async throws {
        let vm = makeVM()
        vm.minRepliesText = ""  // this test exercises the cap, not the min-replies default
        vm.displayCap = 1
        await vm.loadAuthors(reader: try makeReader())
        XCTAssertEqual(vm.authors.count, 1)
        XCTAssertEqual(vm.totalMatching, 7, "all seven authors have at least one reply")
    }

    func testMinRepliesFilterNarrowsBothListAndTotal() async throws {
        let vm = makeVM()
        vm.minRepliesText = "2"
        await vm.loadAuthors(reader: try makeReader())
        // Excludes only did:a (1 reply): b, c, n9, n10, n99, n100 remain.
        XCTAssertEqual(vm.totalMatching, 6)
        XCTAssertFalse(vm.authors.map(\.did).contains("did:a"))
    }

    func testMaxRepliesFilterNarrowsBothListAndTotal() async throws {
        let vm = makeVM()
        vm.minRepliesText = ""  // isolate this test to the max bound; the default min is covered elsewhere
        vm.maxRepliesText = "9"
        await vm.loadAuthors(reader: try makeReader())
        // Excludes n10(10), n99(99), n100(100): a, b, c, n9 remain.
        XCTAssertEqual(vm.totalMatching, 4)
        XCTAssertFalse(vm.authors.map(\.did).contains("did:n10"))
    }

    func testMinAndMaxTogetherNarrowToOneAuthor() async throws {
        let vm = makeVM()
        vm.minRepliesText = "2"
        vm.maxRepliesText = "9"
        await vm.loadAuthors(reader: try makeReader())
        XCTAssertEqual(vm.authors.map(\.did), ["did:n9", "did:c", "did:b"])
    }

    func testSelectLoadsPerAuthorDetail() async throws {
        let vm = makeVM()
        await vm.select("did:c", reader: try makeReader())
        XCTAssertEqual(vm.selected?.replyCount, 3)
        XCTAssertEqual(vm.selectedWeeks.map(\.count).reduce(0, +), 3)
        XCTAssertEqual(vm.selectedOutlets.count, 1)
    }

    func testDeselectClearsDetail() async throws {
        let vm = makeVM()
        let reader = try makeReader()
        await vm.select("did:c", reader: reader)
        await vm.select(nil, reader: reader)
        XCTAssertNil(vm.selected)
        XCTAssertTrue(vm.selectedWeeks.isEmpty)
        XCTAssertNil(vm.selectedHandle)
        XCTAssertTrue(vm.selectedHandleHistory.isEmpty)
        XCTAssertTrue(vm.selectedReplies.isEmpty)
        XCTAssertEqual(vm.selectedReplyTotal, 0)
    }

    /// `select` also loads the most-recent-reply handle and the full reply list —
    /// did:c's three replies all carry the same handle ("carol.test"), newest first.
    func testSelectLoadsHandleAndReplies() async throws {
        let vm = makeVM()
        await vm.select("did:c", reader: try makeReader())
        XCTAssertEqual(vm.selectedHandle, "carol.test")
        XCTAssertEqual(vm.selectedHandleHistory, ["carol.test"])
        XCTAssertEqual(vm.selectedReplies.map(\.uri), ["at://c3", "at://c2", "at://c1"])
        XCTAssertEqual(vm.selectedReplyTotal, 3)
    }

    /// A handle-changing author's most recent handle wins the title, but every handle
    /// they've used is still surfaced — a handle change is signal, not noise.
    func testSelectSurfacesMultipleHandles() async throws {
        let vm = makeVM()
        let reader = try AggregateReader(storeURL: try StoreFixture.makeAuthorHandleHistory())
        await vm.select("did:multi", reader: reader)
        XCTAssertEqual(vm.selectedHandle, "new.test", "the most recent reply's handle wins")
        XCTAssertEqual(vm.selectedHandleHistory, ["new.test", "old.test"])
    }

    /// The reply list is capped, and the cap must never silently hide how much it hides —
    /// did:n100 has 100 replies, more than `AuthorStatsViewModel.replyDisplayCap` (100 by
    /// default, but this pins the relationship rather than assuming the constant's value).
    func testSelectRepliesAreCappedButTotalReflectsEverything() async throws {
        let vm = makeVM()
        await vm.select("did:n100", reader: try makeReader())
        XCTAssertEqual(vm.selectedReplyTotal, 100)
        XCTAssertLessThanOrEqual(vm.selectedReplies.count, AuthorStatsViewModel.replyDisplayCap)
        XCTAssertEqual(vm.selectedReplies.count, min(100, AuthorStatsViewModel.replyDisplayCap))
    }

    /// Rapid selection must not leave a slower earlier load overwriting a newer one.
    ///
    /// Two truly-simultaneous `async let` calls into a `@MainActor`-isolated method race
    /// to be the first onto the actor's queue — that race is real but says nothing about
    /// cancellation correctness, so it is deliberately not what this test exercises (an
    /// earlier draft used bare `async let` on the small default fixture and flaked in
    /// roughly 1 of 4 runs for exactly this reason: whichever call happened to reach the
    /// actor first became the uncancelled "winner", regardless of program order).
    ///
    /// Instead this reproduces the real failure mode directly: `did:slow` has 20,000
    /// replies spread one-per-day (so `repliesPerWeek`'s per-row `Calendar` bucketing has
    /// real, measurable work), and is selected *first* as an unstructured `Task` that is
    /// still genuinely mid-flight — not just "started" — when `did:fast` (1 reply) is
    /// selected second and awaited to completion. Only then is the first selection awaited.
    /// If `did:slow`'s query finished before `did:fast`'s ran, this test would prove
    /// nothing; `testFirstSelectionIsStillInFlightWhenSecondCompletes` below pins down
    /// that precondition so a change to the fixture or the query can't silently make this
    /// test vacuous.
    ///
    /// Verified this discriminates: temporarily deleting the `guard !Task.isCancelled`
    /// line before the `self.selected = detail.0` assignment in `select` makes this test
    /// fail deterministically (selected settles on did:slow, the stale first request,
    /// instead of did:fast) — run 8/8 times, not just once.
    func testRapidSelectionSettlesOnTheLastRequest() async throws {
        let vm = makeVM()
        let reader = try AggregateReader(storeURL: try StoreFixture.makeAuthorRace())

        let firstTask = Task { await vm.select("did:slow", reader: reader) }
        try await Task.sleep(nanoseconds: 2_000_000)  // let the first selection begin
        await vm.select("did:fast", reader: reader)
        _ = await firstTask.value

        XCTAssertEqual(vm.selected?.did, "did:fast")
        XCTAssertEqual(vm.selectedWeeks.map(\.count).reduce(0, +), 1,
                       "detail must belong to did:fast, which has one reply")
    }

    /// Pins down the precondition `testRapidSelectionSettlesOnTheLastRequest` depends on:
    /// selecting the 20,000-reply author is slow enough that it is still running well
    /// after selecting the 1-reply author has already completed. Without this, a future
    /// speed-up of `repliesPerWeek`/`outletBreakdown` (or a faster machine) could make the
    /// race test pass vacuously — both selections would complete before either write
    /// mattered, and the cancellation guard would never be exercised.
    func testFirstSelectionIsStillInFlightWhenSecondCompletes() async throws {
        let vm = makeVM()
        let reader = try AggregateReader(storeURL: try StoreFixture.makeAuthorRace())

        let firstTask = Task { await vm.select("did:slow", reader: reader) }
        try await Task.sleep(nanoseconds: 2_000_000)
        let start = DispatchTime.now()
        await vm.select("did:fast", reader: reader)
        let fastElapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds

        XCTAssertFalse(firstTask.isCancelled)
        // The detached query behind `firstTask` is still running: awaiting it now takes
        // meaningfully longer than the fast selection just did. If this ever fails, the
        // fixture or the query got faster and the race test above needs a bigger fixture.
        let awaitStart = DispatchTime.now()
        _ = await firstTask.value
        let firstAwaitElapsed = DispatchTime.now().uptimeNanoseconds - awaitStart.uptimeNanoseconds
        XCTAssertGreaterThan(firstAwaitElapsed, fastElapsed,
                              "the slow selection should still have work left after the " +
                              "fast one completes — otherwise the race test is vacuous")
    }

    /// An unreadable store must not look like an empty one — "no store" and "no authors"
    /// are different facts, and conflating them hides an unmounted Eregion volume.
    func testUnreadableStoreSurfacesFailure() async throws {
        let vm = makeVM()
        let missing = URL(fileURLWithPath: "/nonexistent/none.store")
        await vm.loadPopulation(readerFactory: { try AggregateReader(storeURL: missing) })
        if case .failed = vm.loadState {} else {
            XCTFail("expected .failed, got \(vm.loadState)")
        }
        XCTAssertEqual(vm.population.totalAuthors, 0)
    }

    // MARK: - replyCountBounds / rangeError mapping
    //
    // Pure, synchronous, and independently testable — this is the one place that
    // decides what typed min/max text means as a SQL range. No reader, no store,
    // no async: these exercise `AuthorStatsViewModel.replyCountBounds`/`rangeError`
    // directly in isolation.

    func testBoundsDefaultToMinOneMaxUnboundedWhenBothEmpty() {
        let vm = makeVM()
        vm.minRepliesText = ""  // this test is about the bounds mapping, not the first-run "100" default
        let bounds = vm.replyCountBounds
        XCTAssertEqual(bounds.min, 1, "empty min means 'at least one reply', not zero")
        XCTAssertNil(bounds.max, "empty max must mean unbounded, never a silent cap")
        XCTAssertNil(vm.rangeError)
    }

    func testBoundsWithMinOnly() {
        let vm = makeVM()
        vm.minRepliesText = "5"
        let bounds = vm.replyCountBounds
        XCTAssertEqual(bounds.min, 5)
        XCTAssertNil(bounds.max)
        XCTAssertNil(vm.rangeError)
    }

    func testBoundsWithMaxOnly() {
        let vm = makeVM()
        vm.minRepliesText = ""  // this test is about the bounds mapping, not the first-run "100" default
        vm.maxRepliesText = "50"
        let bounds = vm.replyCountBounds
        XCTAssertEqual(bounds.min, 1, "no typed min still defaults to 1, not 0")
        XCTAssertEqual(bounds.max, 50)
        XCTAssertNil(vm.rangeError)
    }

    func testBoundsWithBothMinAndMax() {
        let vm = makeVM()
        vm.minRepliesText = "5"
        vm.maxRepliesText = "50"
        let bounds = vm.replyCountBounds
        XCTAssertEqual(bounds.min, 5)
        XCTAssertEqual(bounds.max, 50)
        XCTAssertNil(vm.rangeError)
    }

    func testMinGreaterThanMaxProducesInlineErrorInsteadOfAQuery() {
        let vm = makeVM()
        vm.minRepliesText = "50"
        vm.maxRepliesText = "5"
        XCTAssertNotNil(vm.rangeError, "an inverted range can only ever match zero rows")
        XCTAssertTrue(vm.rangeError?.contains("50") == true)
        XCTAssertTrue(vm.rangeError?.contains("5") == true)
    }

    func testNonNumericTextParsesToNoBoundButSurfacesAnError() {
        let vm = makeVM()
        vm.minRepliesText = "abc"
        XCTAssertEqual(vm.replyCountBounds.min, 1, "junk text must not become a numeric bound — it falls back to the no-bound default of 1")
        XCTAssertNotNil(vm.rangeError, "junk text must be flagged, not silently ignored")
    }

    func testNegativeTextParsesToNoBoundButSurfacesAnError() {
        let vm = makeVM()
        vm.maxRepliesText = "-3"
        XCTAssertNil(vm.replyCountBounds.max, "a negative bound must not be passed to the query")
        XCTAssertNotNil(vm.rangeError, "a negative number must be flagged, not silently dropped")
    }

    // MARK: - loadedAuthorsKey / authorsFilterKey
    //
    // Back `AuthorListView.shouldSkipReload`'s re-appearance skip. These exercise the
    // view-model side of that contract: a successful load (including a zero-match one)
    // records the key it answered; a failed one must not.

    func testSuccessfulLoadRecordsTheKeyItAnswered() async throws {
        let vm = AuthorStatsViewModel()
        let key = vm.authorsFilterKey
        await vm.loadAuthors(reader: try makeReader())
        XCTAssertEqual(vm.loadedAuthorsKey, key)
        if case .loaded = vm.loadState {} else { XCTFail("expected .loaded") }
    }

    /// A filter matching nothing is still a real, loaded answer — `loadedAuthorsKey` must
    /// record it exactly like a non-empty result, not leave it looking "never loaded."
    func testZeroMatchLoadStillRecordsTheKeyAsLoaded() async throws {
        let vm = AuthorStatsViewModel()
        vm.minRepliesText = "99999"
        let key = vm.authorsFilterKey
        await vm.loadAuthors(reader: try makeReader())
        XCTAssertEqual(vm.authors.count, 0)
        XCTAssertEqual(vm.totalMatching, 0)
        XCTAssertEqual(vm.loadedAuthorsKey, key,
                       "a legitimate zero-match result must still count as loaded")
        if case .loaded = vm.loadState {} else { XCTFail("expected .loaded") }
    }

    /// A failed load must clear `loadedAuthorsKey` rather than leaving a stale value that
    /// happens to still equal the current key — otherwise the caller-side skip could
    /// mistake a failure for "already loaded" and never let the user retry.
    func testFailedLoadClearsLoadedAuthorsKey() async throws {
        let vm = AuthorStatsViewModel()
        await vm.loadAuthors(reader: try makeReader())
        XCTAssertNotNil(vm.loadedAuthorsKey, "sanity: a real load did record a key")

        // A file that opens (so `AggregateReader.init` succeeds — SQLite's read-only open
        // is lazy) but is not a valid database, so the query itself inside `loadAuthors`
        // fails. This is what actually exercises the "must not look like already loaded"
        // guard, as opposed to a store that never opens at all.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let garbage = dir.appendingPathComponent("not-a-database.sqlite")
        try Data("not a sqlite file".utf8).write(to: garbage)
        let badReader = try AggregateReader(storeURL: garbage)

        await vm.loadAuthors(reader: badReader)
        XCTAssertNil(vm.loadedAuthorsKey, "a failed load must not look like 'already loaded'")
        if case .failed = vm.loadState {} else { XCTFail("expected .failed") }
    }

    /// A genuine filter change produces a different key — the view-model side of "a
    /// genuine filter change must still reload."
    func testChangingAFilterChangesTheKey() {
        let vm = AuthorStatsViewModel()
        let before = vm.authorsFilterKey
        vm.minRepliesText = "42"
        XCTAssertNotEqual(vm.authorsFilterKey, before)
    }

    func testWhitespaceOnlyTextBehavesLikeEmpty() {
        let vm = makeVM()
        vm.minRepliesText = "   "
        vm.maxRepliesText = "  "
        XCTAssertEqual(vm.replyCountBounds.min, 1)
        XCTAssertNil(vm.replyCountBounds.max)
        XCTAssertNil(vm.rangeError, "whitespace-only text is 'empty on purpose', not garbage")
    }

    // MARK: - Persistence
    //
    // Each test gets a fresh `UserDefaults(suiteName:)` (see `setUp`/`tearDown`), so
    // "first run" here really means first run — no leftover state from another test or
    // from the real `.standard` domain.

    func testFirstRunDefaultsMinRepliesTo100() {
        let vm = makeVM()
        XCTAssertEqual(vm.minRepliesText, "100",
                       "a fresh domain has never set a value, so the working default applies")
    }

    func testStoredValuesAreRestoredOnNextLaunch() {
        let first = makeVM()
        first.minRepliesText = "37"
        first.maxRepliesText = "9000"
        first.sort = .lastSeen
        first.displayCap = 2000

        let second = makeVM()
        XCTAssertEqual(second.minRepliesText, "37")
        XCTAssertEqual(second.maxRepliesText, "9000")
        XCTAssertEqual(second.sort, .lastSeen)
        XCTAssertEqual(second.displayCap, 2000)
    }

    /// The one subtle bug this feature has to avoid: emptying the min field on purpose
    /// must survive a relaunch as empty, never snap back to the "100" default. That
    /// requires distinguishing "never set" from "deliberately cleared", which is exactly
    /// what `PersistenceKey.minRepliesInitialized` is for.
    func testDeliberatelyClearedMinRepliesStaysClearedAcrossReload() {
        let first = makeVM()
        XCTAssertEqual(first.minRepliesText, "100", "sanity: first run applied the default")
        first.minRepliesText = ""

        let second = makeVM()
        XCTAssertEqual(second.minRepliesText, "",
                       "a deliberate clear must not be resurrected as \"100\" on the next launch")

        // And it keeps staying cleared on a third launch, too — not just "not yet
        // re-defaulted once."
        let third = makeVM()
        XCTAssertEqual(third.minRepliesText, "")
    }

    /// A stored raw value that doesn't match any current `AuthorSort` case (an older or
    /// newer build, or a hand-edited default) must fall back to `.replyCount` rather than
    /// trapping.
    func testCorruptSortRawValueFallsBackToReplyCount() {
        defaults.set("not-a-real-sort-case", forKey: "authors.sort")
        let vm = makeVM()
        XCTAssertEqual(vm.sort, .replyCount)
    }

    /// A non-numeric, zero, or negative stored display cap must fall back to the
    /// compiled-in default rather than trapping or applying a cap of zero/negative.
    func testCorruptDisplayCapFallsBackToDefault() {
        defaults.set("not-a-number", forKey: "authors.displayCap")
        let vm = makeVM()
        XCTAssertEqual(vm.displayCap, 500)
    }

    func testNonPositiveDisplayCapFallsBackToDefault() {
        defaults.set(0, forKey: "authors.displayCap")
        let vm = makeVM()
        XCTAssertEqual(vm.displayCap, 500)
    }

    func testChangingMinRepliesPersistsImmediately() {
        let vm = makeVM()
        vm.minRepliesText = "42"
        XCTAssertEqual(defaults.string(forKey: "authors.minReplies"), "42")
    }
}
