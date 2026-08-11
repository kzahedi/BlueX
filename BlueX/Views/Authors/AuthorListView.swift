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
        .task { await reload() }
        .onChange(of: viewModel.sort) { _, _ in Task { await reload() } }
        .onChange(of: viewModel.minReplies) { _, _ in Task { await reload() } }
        .onChange(of: viewModel.outletFilter) { _, _ in Task { await reload() } }
        .onChange(of: viewModel.displayCap) { _, _ in Task { await reload() } }
        .onChange(of: selection) { _, newValue in
            Task {
                guard let reader = try? AggregateReader() else { return }
                await viewModel.select(newValue, reader: reader)
            }
        }
    }

    private func reload() async {
        // Population is loaded here too (rather than only from AuthorsOverviewView) so
        // the outlet picker below has outlet names even if the overview pane was never
        // visited this session.
        if viewModel.population.outlets.isEmpty {
            await viewModel.loadPopulation(readerFactory: { try AggregateReader() })
        }
        guard let reader = try? AggregateReader() else { return }
        await viewModel.loadAuthors(reader: reader)
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

            Stepper("Min replies: \(viewModel.minReplies)",
                    value: Bindable(viewModel).minReplies, in: 1...1000)
                .frame(width: 200)

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
