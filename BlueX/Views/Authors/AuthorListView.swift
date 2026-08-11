// BlueX/Views/Authors/AuthorListView.swift
import SwiftUI

/// The sortable, filterable, capped list of reply authors. The cap is always stated
/// ("Showing N of M matching authors") — hiding how much it hides would misrepresent
/// coverage of the ~207k-person population this dashboard characterises.
struct AuthorListView: View {
    var viewModel: AuthorStatsViewModel
    @State private var selection: String?
    private static let capOptions = [100, 500, 2000]
    private let dateFormat = Date.FormatStyle(date: .abbreviated, time: .omitted)

    /// Typed min/max reply-count drafts, mirroring `AccountContentView`'s
    /// `minRepliesDraft`/`maxRepliesDraft`. Committed into `viewModel.minRepliesText`/
    /// `maxRepliesText` only on `.onSubmit` or focus loss (`commitReplyCountDraft`) —
    /// never per keystroke, since each commit can trigger a multi-second SQL aggregate
    /// against the live store.
    @State private var minRepliesDraft: String = ""
    @State private var maxRepliesDraft: String = ""
    @FocusState private var focusedReplyCountField: ReplyCountField?
    private enum ReplyCountField: Hashable { case min, max }

    /// The most recently started `loadAuthors` call. A synchronous SQL call cannot be
    /// cancelled mid-flight, so a new `reload()` awaits this to finish rather than
    /// starting a second one concurrently — without this, a rapid sequence of filter
    /// changes each spawns its own untracked query, and several multi-second aggregates
    /// running at once is exactly how this dashboard got to 790% CPU.
    @State private var inFlightLoadTask: Task<Void, Never>?

    /// Identifies everything a reload depends on: sort, cap, outlet, and the *committed*
    /// reply-count range (never the in-progress draft text — see `minRepliesDraft`).
    /// `.task(id:)` re-runs `reload()` whenever this changes and cancels any reload still
    /// waiting out its debounce, which is what replaces the untracked `Task { await
    /// reload() }` per `onChange` this view used to spawn one of per filter change.
    private var reloadKey: String {
        "\(viewModel.sort)|\(viewModel.displayCap)|\(viewModel.outletFilter ?? -1)|" +
        "\(viewModel.minRepliesText)|\(viewModel.maxRepliesText)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            Divider()

            switch viewModel.loadState {
            case .failed(let message):
                failureBanner(message)
            case .idle, .loading:
                ProgressView("Loading authors…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .foregroundStyle(Color.secondaryText)
            case .loaded:
                table
                Divider()
                Text(AuthorsFormatting.matchingSummary(shown: viewModel.authors.count,
                                                        total: viewModel.totalMatching))
                    .font(.caption)
                    .foregroundStyle(Color.mutedText)
                    .padding(8)
            }
        }
        .background(Color.appBackground)
        .task(id: reloadKey) { await reload() }
        .onChange(of: selection) { _, newValue in
            Task {
                guard let reader = try? AggregateReader() else { return }
                await viewModel.select(newValue, reader: reader)
            }
        }
    }

    /// Copies the drafts into the view model and clears any stale reload debounce so the
    /// typed range actually takes effect. Called from `.onSubmit` and on focus loss,
    /// never from an `onChange` of the text itself: that's the one thing that must not
    /// happen, or every keystroke would re-run the multi-second aggregate and recreate
    /// the freeze this fix exists for.
    private func commitReplyCountDraft() {
        guard viewModel.minRepliesText != minRepliesDraft ||
              viewModel.maxRepliesText != maxRepliesDraft else { return }
        viewModel.minRepliesText = minRepliesDraft
        viewModel.maxRepliesText = maxRepliesDraft
    }

    /// Debounces, then serializes against any still-running load before starting a new
    /// one. `.task(id: reloadKey)` cancels this call outright whenever `reloadKey`
    /// changes again before it finishes — the `Task.isCancelled` checks below stop it
    /// from doing further work once that happens, but cannot stop a SQL query already in
    /// flight (see `inFlightLoadTask`).
    private func reload() async {
        // A generous debounce: the query behind this is multi-second against the live
        // store (5.2s unjoined / 27.8s joined, measured against 2.16M posts), so a short
        // debounce would still let several fire before the first one lands.
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard !Task.isCancelled else { return }

        // An inverted or unparseable range can only ever match zero rows (or is not yet
        // a valid range at all) — surface the inline message instead of spending seconds
        // to confirm that.
        guard viewModel.rangeError == nil else { return }

        if let prior = inFlightLoadTask {
            _ = await prior.value
        }
        guard !Task.isCancelled else { return }

        // Population is loaded here too (rather than only from AuthorsOverviewView) so
        // the outlet picker below has outlet names even if the overview pane was never
        // visited this session.
        if viewModel.population.outlets.isEmpty {
            await viewModel.loadPopulation(readerFactory: { try AggregateReader() })
        }
        guard let reader = try? AggregateReader() else { return }

        let task = Task { await viewModel.loadAuthors(reader: reader) }
        inFlightLoadTask = task
        await task.value
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Sort", selection: Bindable(viewModel).sort) {
                ForEach(AuthorSort.allCases) { sort in
                    Text(sort.label).tag(sort)
                }
            }
            .frame(width: 160)

            replyCountRangeFields

            Picker("Outlet", selection: Bindable(viewModel).outletFilter) {
                Text("All outlets").tag(Int64?.none)
                ForEach(viewModel.population.outlets) { outlet in
                    Text(outlet.handle).tag(Int64?.some(outlet.accountPK))
                }
            }
            .frame(width: 180)

            Picker("Show", selection: Bindable(viewModel).displayCap) {
                ForEach(Self.capOptions, id: \.self) { cap in
                    Text("\(cap)").tag(cap)
                }
            }
            .frame(width: 100)

            Spacer()
        }
        .padding(10)
        .background(Color.panelBackground)
    }

    /// Typed min/max reply-count fields — replaces the old `Stepper`, which only ever
    /// bounded the *minimum* (1...1000) and offered no way to bound the maximum at all.
    /// Commits only on `.onSubmit` or focus loss (`commitReplyCountDraft`), never per
    /// keystroke: each commit can trigger a multi-second SQL aggregate, so re-running it
    /// per character would recreate the freeze this whole fix exists for.
    private var replyCountRangeFields: some View {
        HStack(spacing: 4) {
            Text("Replies")
                .font(.system(size: 10))
                .foregroundStyle(Color.mutedText)
            TextField("min", text: $minRepliesDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .frame(width: 44)
                .focused($focusedReplyCountField, equals: .min)
                .onSubmit { commitReplyCountDraft() }
            Text("–")
                .font(.system(size: 10))
                .foregroundStyle(Color.mutedText)
            TextField("max", text: $maxRepliesDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .frame(width: 44)
                .focused($focusedReplyCountField, equals: .max)
                .onSubmit { commitReplyCountDraft() }
            if let error = viewModel.rangeError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.hateBorder)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.appBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onChange(of: focusedReplyCountField) { oldValue, newValue in
            // Fires on focus loss (tab away, click elsewhere) as well as focus change
            // between the two fields — `.onSubmit` alone wouldn't catch a plain click-away.
            if oldValue != nil && oldValue != newValue {
                commitReplyCountDraft()
            }
        }
    }

    // MARK: - Table

    private var table: some View {
        Table(viewModel.authors, selection: $selection) {
            TableColumn("Author") { author in
                Text(author.handle ?? author.did)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.primaryText)
                    .lineLimit(1)
            }
            TableColumn("Replies") { author in
                Text("\(author.replyCount)")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondaryText)
            }
            TableColumn("First seen") { author in
                Text(author.firstSeen.formatted(dateFormat))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondaryText)
            }
            TableColumn("Last seen") { author in
                Text(author.lastSeen.formatted(dateFormat))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondaryText)
            }
            TableColumn("Span (days)") { author in
                Text("\(author.spanDays)")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondaryText)
            }
            TableColumn("Outlets") { author in
                Text("\(author.outletCount)")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondaryText)
            }
        }
    }

    private func failureBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.yellow)
                Text("Could not open the store")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.primaryText)
            }
            Text(message)
                .font(.caption)
                .foregroundStyle(Color.secondaryText)
        }
        .padding(12)
        .background(Color.hateBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
