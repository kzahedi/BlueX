import XCTest
@testable import BlueX

/// Values here are derived from `StoreFixture.make()`'s seven reply authors:
///   did:a (1), did:b (2), did:c (3), did:n9 (9), did:n10 (10), did:n99 (99), did:n100 (100)
/// Ranked by reply count: n100, n99, n10, n9, c, b, a.
@MainActor
final class AuthorStatsViewModelTests: XCTestCase {
    private func makeReader() throws -> AggregateReader {
        try AggregateReader(storeURL: try StoreFixture.make())
    }

    func testLoadsPopulation() async throws {
        let vm = AuthorStatsViewModel()
        await vm.loadPopulation(reader: try makeReader())
        XCTAssertEqual(vm.population.totalAuthors, 7)
        if case .loaded = vm.loadState {} else { XCTFail("expected .loaded") }
    }

    func testLoadsAuthorsRespectingSortAndCap() async throws {
        let vm = AuthorStatsViewModel()
        vm.sort = .replyCount
        vm.displayCap = 2
        await vm.loadAuthors(reader: try makeReader())
        XCTAssertEqual(vm.authors.map(\.did), ["did:n100", "did:n99"])
    }

    /// A cap that hides how much it hides would misrepresent coverage.
    func testTotalMatchingReportsBeyondTheCap() async throws {
        let vm = AuthorStatsViewModel()
        vm.displayCap = 1
        await vm.loadAuthors(reader: try makeReader())
        XCTAssertEqual(vm.authors.count, 1)
        XCTAssertEqual(vm.totalMatching, 7, "all seven authors have at least one reply")
    }

    func testMinRepliesFilterNarrowsBothListAndTotal() async throws {
        let vm = AuthorStatsViewModel()
        vm.minReplies = 2
        await vm.loadAuthors(reader: try makeReader())
        // Excludes only did:a (1 reply): b, c, n9, n10, n99, n100 remain.
        XCTAssertEqual(vm.totalMatching, 6)
        XCTAssertFalse(vm.authors.map(\.did).contains("did:a"))
    }

    func testSelectLoadsPerAuthorDetail() async throws {
        let vm = AuthorStatsViewModel()
        await vm.select("did:c", reader: try makeReader())
        XCTAssertEqual(vm.selected?.replyCount, 3)
        XCTAssertEqual(vm.selectedWeeks.map(\.count).reduce(0, +), 3)
        XCTAssertEqual(vm.selectedOutlets.count, 1)
    }

    func testDeselectClearsDetail() async throws {
        let vm = AuthorStatsViewModel()
        let reader = try makeReader()
        await vm.select("did:c", reader: reader)
        await vm.select(nil, reader: reader)
        XCTAssertNil(vm.selected)
        XCTAssertTrue(vm.selectedWeeks.isEmpty)
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
        let vm = AuthorStatsViewModel()
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
        let vm = AuthorStatsViewModel()
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
        let vm = AuthorStatsViewModel()
        let missing = URL(fileURLWithPath: "/nonexistent/none.store")
        await vm.loadPopulation(readerFactory: { try AggregateReader(storeURL: missing) })
        if case .failed = vm.loadState {} else {
            XCTFail("expected .failed, got \(vm.loadState)")
        }
        XCTAssertEqual(vm.population.totalAuthors, 0)
    }
}
