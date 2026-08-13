// BlueX/ViewModels/AuthorStatsViewModel.swift
import Foundation
import Observation

/// Backs the reply-author dashboard: the population summary, the sortable/filterable
/// author list, and the per-author detail pane.
///
/// **Concurrency.** Every load runs its query off the MainActor via `Task.detached`, then
/// checks `Task.isCancelled` immediately before writing state — not once at the top of the
/// function, but right before each assignment, since a check before an `await` proves
/// nothing about what happens after it. `select(_:reader:)` additionally cancels its own
/// previous in-flight load before starting a new one: without that, a slow load for a
/// previously-selected author can complete after a fast switch and overwrite the current
/// selection's state with a different author's data under the current header.
///
/// **Why `@MainActor` on the whole type, not just on the writes.** `select`'s
/// cancel-then-store sequence (`detailTask?.cancel(); ...; detailTask = task`) has to run
/// as one atomic step relative to *other calls to `select`* — two concurrent calls both
/// racing to read-then-write `detailTask` can each see it as `nil`, cancel nothing, and
/// leave both underlying queries free to finish and write in whichever order the SQLite
/// query planner happens to land on, independent of call order. Isolating the type to the
/// MainActor serializes every `select` call's synchronous prefix (through the
/// `detailTask = task` assignment) before the next call's prefix can run, so the *second*
/// call is guaranteed to observe and cancel the *first* call's task. This was caught by
/// `testRapidSelectionSettlesOnTheLastRequest` failing nondeterministically before this
/// annotation was added — not just a style choice.
///
/// **Failure semantics.** A failure to open or query the store surfaces as `.failed` and
/// leaves `population`/`authors` at their empty defaults — never populated with fabricated
/// zeros. "No store" (an unmounted volume, a missing file) and "no authors" (a store that
/// opened fine but matched nothing) are different facts, and conflating them would hide
/// the former.
@Observable
@MainActor
final class AuthorStatsViewModel {
    enum LoadState: Equatable {
        case idle, loading, loaded
        case failed(String)
    }

    /// `UserDefaults` keys for the filter/sort/cap state persisted below. Namespaced
    /// under `authors.` alongside the account dashboard's `account.` keys.
    ///
    /// `outletFilter` is deliberately absent here and never persisted: it stores an
    /// account primary key, and a PK from a previous launch is not guaranteed to still
    /// exist (an outlet can be removed between launches). Restoring a stale PK would
    /// silently filter the list to an outlet that no longer exists and show an empty
    /// table with no explanation — worse than just resetting to "All outlets" every
    /// launch, so it resets every launch instead.
    private enum PersistenceKey {
        static let minReplies = "authors.minReplies"
        /// Set once `minReplies` has ever been written for this `UserDefaults` (by the
        /// user or by the first-run default below) — distinguishes "never set, apply
        /// the default" from "deliberately cleared, restore the empty string."
        static let minRepliesInitialized = "authors.minReplies.initialized"
        static let maxReplies = "authors.maxReplies"
        static let sort = "authors.sort"
        static let displayCap = "authors.displayCap"
    }

    /// Backing store for persistence. Injectable so tests can use an isolated
    /// `UserDefaults(suiteName:)` instead of polluting the real `.standard` domain.
    @ObservationIgnored private let defaults: UserDefaults

    /// Restores persisted sort/cap/filter state in one pass (so the first render already
    /// reflects it — no follow-up write-then-reload) and applies the one-time `"100"`
    /// default to `minRepliesText` on a domain that has never set it before.
    ///
    /// Invalid or corrupt stored values (an unknown sort raw value, a non-positive or
    /// non-numeric display cap) fall back to the compiled-in defaults rather than
    /// trapping — a value written by an older build, or hand-edited, must not crash.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if defaults.bool(forKey: PersistenceKey.minRepliesInitialized) {
            minRepliesText = defaults.string(forKey: PersistenceKey.minReplies) ?? ""
        } else {
            minRepliesText = "100"
            defaults.set("100", forKey: PersistenceKey.minReplies)
            defaults.set(true, forKey: PersistenceKey.minRepliesInitialized)
        }

        maxRepliesText = defaults.string(forKey: PersistenceKey.maxReplies) ?? ""

        if let storedSort = defaults.string(forKey: PersistenceKey.sort),
           let restoredSort = AuthorSort(rawValue: storedSort) {
            sort = restoredSort
        }

        if let storedCap = defaults.object(forKey: PersistenceKey.displayCap) as? Int,
           storedCap > 0 {
            displayCap = storedCap
        }
    }

    var population: PopulationStats = .empty
    /// Whether `StoreIndexPlan.all` was present the last time `loadPopulation`
    /// checked. `AggregateReader` is read-only and cannot repair a missing index —
    /// `IndexReasserter`, run from `BlueXStore.openContainer()`, is what does that —
    /// so this exists purely to surface the fact that repair didn't happen, rather
    /// than silently running unindexed. Defaults to healthy so a view that never
    /// loads (e.g. a unit test of some other property) doesn't render a false alarm.
    var indexHealth: AggregateReader.IndexHealth = .healthy
    var authors: [AuthorSummary] = []
    /// How many authors match the current filters, regardless of `displayCap`. Tracked
    /// separately from the cap so the UI can state what it is *not* showing — a cap that
    /// hides how much it hides misrepresents coverage.
    var totalMatching: Int = 0

    var sort: AuthorSort = .replyCount {
        didSet { defaults.set(sort.rawValue, forKey: PersistenceKey.sort) }
    }
    var displayCap: Int = 500 {
        didSet { defaults.set(displayCap, forKey: PersistenceKey.displayCap) }
    }

    /// Typed reply-count bounds, mirroring `AccountViewModel.minRepliesText`/
    /// `maxRepliesText`. The view commits these on `.onSubmit`/focus-loss only — never
    /// per keystroke, since each change re-runs a multi-second SQL aggregate against the
    /// live store (measured 5.2s unjoined / 27.8s joined against 2.16M posts). Both
    /// independently optional: an empty string means "no bound" in that direction, not
    /// zero, and an absent max must never become a silent cap.
    ///
    /// Persisted across launches (see `PersistenceKey`/`init(defaults:)`). `minRepliesText`
    /// additionally gets a one-time first-run default of `"100"` — measured on the live
    /// corpus, 2,544 of 256,655 authors have ≥100 replies, a useful working set rather
    /// than the full population. That default must apply exactly once: if the user later
    /// clears the field on purpose, `PersistenceKey.minRepliesInitialized` (set the first
    /// time this class ever runs against a given `UserDefaults`) records that the default
    /// has already been applied, so a later empty string is restored as empty rather than
    /// snapping back to `"100"`.
    var minRepliesText: String = "" {
        didSet { defaults.set(minRepliesText, forKey: PersistenceKey.minReplies) }
    }
    var maxRepliesText: String = "" {
        didSet { defaults.set(maxRepliesText, forKey: PersistenceKey.maxReplies) }
    }
    var outletFilter: Int64? = nil

    /// The `(minReplies, maxReplies)` to pass to `AggregateReader.authors`/
    /// `authorCount`. Pure and independently testable — this is the one place that
    /// decides what the typed text means as a SQL range. `minReplies` defaults to `1`
    /// when unset (this dashboard's population is "authors who replied at least once",
    /// not "every DID including those with zero replies") — everything else defaults to
    /// no bound.
    ///
    /// Non-numeric or negative text parses to `nil` (no bound in that direction) rather
    /// than crashing or defaulting to zero; `rangeError` is what tells the view *that*
    /// the text didn't parse, or that the range is inverted, so it can withhold the query
    /// instead of firing one that provably returns nothing. This property itself never
    /// withholds — it always reflects what the text parses to.
    var replyCountBounds: (min: Int, max: Int?) {
        let min = Self.parseNonNegativeInt(minRepliesText) ?? 1
        let max = Self.parseNonNegativeInt(maxRepliesText)
        return (min, max)
    }

    /// Inline validation message for the typed min/max fields, or `nil` if it's safe to
    /// query. Non-nil for: non-numeric text, negative numbers, or `min > max` (a range
    /// that can only ever match zero rows — the view should show this message instead of
    /// firing that query).
    var rangeError: String? {
        let minTrimmed = minRepliesText.trimmingCharacters(in: .whitespacesAndNewlines)
        let maxTrimmed = maxRepliesText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !minTrimmed.isEmpty && Self.parseNonNegativeInt(minTrimmed) == nil {
            return "Min must be a whole number ≥ 0"
        }
        if !maxTrimmed.isEmpty && Self.parseNonNegativeInt(maxTrimmed) == nil {
            return "Max must be a whole number ≥ 0"
        }
        let min = Self.parseNonNegativeInt(minTrimmed)
        let max = Self.parseNonNegativeInt(maxTrimmed)
        if let min, let max, min > max {
            return "Min (\(min)) is greater than max (\(max))"
        }
        return nil
    }

    /// Empty/whitespace-only, non-numeric, or negative text all parse to `nil` — "no
    /// bound in this direction" for the query. `rangeError` is the layer that
    /// distinguishes "empty on purpose" from "typed garbage" for the user.
    private static func parseNonNegativeInt(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = Int(trimmed), value >= 0 else { return nil }
        return value
    }

    var selected: AuthorSummary? = nil
    var selectedWeeks: [WeekCount] = []
    var selectedOutlets: [OutletCount] = []
    /// The handle on `selected`'s most recent reply — see `AggregateReader.mostRecentHandle`
    /// for why this is not the same thing as `selected?.handle`.
    var selectedHandle: String? = nil
    /// Every distinct handle `selected` has used across their replies. More than one entry
    /// is a handle-change — signal, not noise — surfaced rather than collapsed away.
    var selectedHandleHistory: [String] = []
    var selectedReplies: [AuthorReply] = []
    /// How many replies `selected` has in total, regardless of `selectedReplies`'s cap —
    /// tracked separately so the view can say "showing N of M", never a silent cap.
    var selectedReplyTotal: Int = 0

    /// Cap on `selectedReplies`. Always displayed alongside `selectedReplyTotal` — never
    /// a silent cap.
    static let replyDisplayCap = 100

    var loadState: LoadState = .idle

    /// Identifies everything `loadAuthors` depends on: sort, cap, outlet, and the
    /// *committed* reply-count range. `AuthorListView` compares this against
    /// `loadedAuthorsKey` to decide whether a re-appearance (as opposed to a genuine
    /// filter change) needs a fresh query at all — the data for this exact key is
    /// already sitting in `authors`/`totalMatching`.
    var authorsFilterKey: String {
        "\(sort)|\(displayCap)|\(outletFilter ?? -1)|\(minRepliesText)|\(maxRepliesText)"
    }

    /// The `authorsFilterKey` that `authors`/`totalMatching` currently reflect, set only
    /// once `loadAuthors` has *successfully* completed for that key — `nil` beforehand,
    /// and reset to `nil` on failure. Never set optimistically at the start of a load:
    /// a load that fails must not be mistaken for "already loaded" (that would make an
    /// error state permanent, since the caller-side skip would never let a retry fire),
    /// and a load that is merely in flight for the same key must not be mistaken for
    /// done either. A key that loaded to zero matching authors is still a real value
    /// here — an empty result is a legitimate loaded state, not a reason to re-query
    /// forever, so this is not gated on `authors` being non-empty.
    var loadedAuthorsKey: String? = nil

    // MARK: - Population

    func loadPopulation(reader: AggregateReader) async {
        await loadPopulation(readerFactory: { reader })
    }

    /// The factory form exists so a failure to *open* the store is testable, not just a
    /// failure to query an already-open one.
    func loadPopulation(readerFactory: @escaping () throws -> AggregateReader) async {
        loadState = .loading
        do {
            let (stats, health) = try await Task.detached(priority: .userInitiated) {
                let reader = try readerFactory()
                try reader.verifySchema()
                let health = try reader.indexHealth()
                if !health.isHealthy {
                    // The event a human needs to see: re-assertion on open either
                    // didn't run or didn't work, and this dashboard is about to run
                    // unindexed queries. AggregateReader cannot fix this itself — it
                    // is read-only by construction — so logging is the honest thing
                    // to do, alongside the visible banner `loadPopulation`'s caller
                    // renders from `indexHealth`.
                    print("AuthorStatsViewModel: degraded — missing index(es): " +
                          health.missing.joined(separator: ", "))
                }
                return (try reader.populationStats(), health)
            }.value
            guard !Task.isCancelled else { return }
            population = stats
            indexHealth = health
            loadState = .loaded
        } catch {
            guard !Task.isCancelled else { return }
            population = .empty
            loadState = .failed(String(describing: error))
        }
    }

    // MARK: - Author list

    /// Loads the author list, then separately loads how many authors match beyond the
    /// cap. Split into two awaits rather than one `Task.detached` doing both, so rows
    /// publish (and `loadState` becomes `.loaded`) as soon as they arrive instead of
    /// waiting on the count too: `authors(...)` is `LIMIT`-ed, but `authorCount(...)`
    /// must scan every matching author, which roughly doubles the wait if bundled
    /// together — and with multi-second queries against the live store, that's the
    /// difference between "rows appear" and "still nothing after twice as long."
    func loadAuthors(reader: AggregateReader) async {
        loadState = .loading
        let sort = self.sort, cap = self.displayCap
        let bounds = self.replyCountBounds, outlet = self.outletFilter
        // Captured before either `await` below: the key this call's result will belong
        // to once it lands, regardless of whatever `authorsFilterKey` reads as by then.
        let key = authorsFilterKey
        do {
            let rows = try await Task.detached(priority: .userInitiated) {
                try reader.authors(sort: sort, limit: cap, minReplies: bounds.min,
                                    maxReplies: bounds.max, outletPK: outlet)
            }.value
            guard !Task.isCancelled else { return }
            authors = rows
            loadState = .loaded

            let total = try await Task.detached(priority: .userInitiated) {
                try reader.authorCount(minReplies: bounds.min, maxReplies: bounds.max, outletPK: outlet)
            }.value
            guard !Task.isCancelled else { return }
            totalMatching = total
            // Only a fully-succeeded round trip (rows *and* the total) marks this key as
            // loaded — a zero-row result still lands here and is a legitimate loaded
            // state, never mistaken for "never queried."
            loadedAuthorsKey = key
        } catch {
            guard !Task.isCancelled else { return }
            authors = []
            totalMatching = 0
            loadState = .failed(String(describing: error))
            // A failure must never look like "already loaded" to the caller-side skip —
            // otherwise the error state becomes permanent and the user can never retry.
            loadedAuthorsKey = nil
        }
    }

    // MARK: - Selection / detail

    /// In-flight detail load, cancelled whenever a new selection arrives so a slow earlier
    /// query cannot land after a newer one and leave the pane showing the wrong author.
    @ObservationIgnored private var detailTask: Task<Void, Never>?

    func select(_ did: String?, reader: AggregateReader) async {
        detailTask?.cancel()
        guard let did else {
            selected = nil
            selectedWeeks = []
            selectedOutlets = []
            selectedHandle = nil
            selectedHandleHistory = []
            selectedReplies = []
            selectedReplyTotal = 0
            return
        }
        let cap = Self.replyDisplayCap
        let task = Task { @MainActor [weak self] in
            do {
                let detail = try await Task.detached(priority: .userInitiated) {
                    (try reader.authorDetail(did: did),
                     try reader.repliesPerWeek(did: did),
                     try reader.outletBreakdown(did: did),
                     try reader.mostRecentHandle(did: did),
                     try reader.distinctHandles(did: did),
                     try reader.authorReplies(did: did, limit: cap),
                     try reader.authorReplyCount(did: did))
                }.value
                // A cancelled load must publish nothing — the newer selection owns state.
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.selected = detail.0
                self.selectedWeeks = Decimator.downsample(detail.1, to: 400)
                self.selectedOutlets = detail.2
                self.selectedHandle = detail.3
                self.selectedHandleHistory = detail.4
                self.selectedReplies = detail.5
                self.selectedReplyTotal = detail.6
            } catch {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.loadState = .failed(String(describing: error))
            }
        }
        detailTask = task
        await task.value
    }
}
