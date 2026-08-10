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

    var population: PopulationStats = .empty
    var authors: [AuthorSummary] = []
    /// How many authors match the current filters, regardless of `displayCap`. Tracked
    /// separately from the cap so the UI can state what it is *not* showing — a cap that
    /// hides how much it hides misrepresents coverage.
    var totalMatching: Int = 0

    var sort: AuthorSort = .replyCount
    var displayCap: Int = 500
    var minReplies: Int = 1
    var outletFilter: Int64? = nil

    var selected: AuthorSummary? = nil
    var selectedWeeks: [WeekCount] = []
    var selectedOutlets: [OutletCount] = []

    var loadState: LoadState = .idle

    // MARK: - Population

    func loadPopulation(reader: AggregateReader) async {
        await loadPopulation(readerFactory: { reader })
    }

    /// The factory form exists so a failure to *open* the store is testable, not just a
    /// failure to query an already-open one.
    func loadPopulation(readerFactory: @escaping () throws -> AggregateReader) async {
        loadState = .loading
        do {
            let stats = try await Task.detached(priority: .userInitiated) {
                let reader = try readerFactory()
                try reader.verifySchema()
                return try reader.populationStats()
            }.value
            guard !Task.isCancelled else { return }
            population = stats
            loadState = .loaded
        } catch {
            guard !Task.isCancelled else { return }
            population = .empty
            loadState = .failed(String(describing: error))
        }
    }

    // MARK: - Author list

    func loadAuthors(reader: AggregateReader) async {
        loadState = .loading
        let sort = self.sort, cap = self.displayCap
        let minReplies = self.minReplies, outlet = self.outletFilter
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let rows = try reader.authors(sort: sort, limit: cap,
                                               minReplies: minReplies, outletPK: outlet)
                let total = try reader.authorCount(minReplies: minReplies, outletPK: outlet)
                return (rows, total)
            }.value
            guard !Task.isCancelled else { return }
            authors = result.0
            totalMatching = result.1
            loadState = .loaded
        } catch {
            guard !Task.isCancelled else { return }
            authors = []
            totalMatching = 0
            loadState = .failed(String(describing: error))
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
            return
        }
        let task = Task { @MainActor [weak self] in
            do {
                let detail = try await Task.detached(priority: .userInitiated) {
                    (try reader.authorDetail(did: did),
                     try reader.repliesPerWeek(did: did),
                     try reader.outletBreakdown(did: did))
                }.value
                // A cancelled load must publish nothing — the newer selection owns state.
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.selected = detail.0
                self.selectedWeeks = Decimator.downsample(detail.1, to: 400)
                self.selectedOutlets = detail.2
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
