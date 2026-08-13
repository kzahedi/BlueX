// BlueX/Views/Authors/AuthorsOverviewView.swift
import SwiftUI
import Charts

/// The population-level summary for the ~207k people who reply to the five tracked
/// outlets: headline chips, a reply-count histogram, an outlet chart, and an account-status
/// panel. Three facts are stated in-line rather than implied, per the dashboard brief:
/// outlet author counts overlap and sum above the population total; cross-outlet
/// comparison is confounded while one outlet dominates the corpus; and account status has
/// not been collected yet, so it must never render as a zeroed chart.
struct AuthorsOverviewView: View {
    var viewModel: AuthorStatsViewModel
    @Binding var selection: SidebarItem?

    var body: some View {
        // Selecting a row in `AuthorListView` populates `viewModel.selected`; this pane
        // then swaps from the population summary to that author's detail. Deselecting
        // (via `AuthorListView`'s selection binding going back to nil) swaps it back.
        if viewModel.selected != nil {
            AuthorDetailView(viewModel: viewModel, selection: $selection)
        } else {
            overview
        }
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                switch viewModel.loadState {
                case .failed(let message):
                    // A failure to open the store (e.g. an unmounted Eregion volume) must
                    // never look like "the population is empty" — that is a different,
                    // much less alarming fact.
                    failureBanner(message)
                case .idle, .loading:
                    ProgressView("Loading population…")
                        .frame(maxWidth: .infinity, minHeight: 200)
                        .foregroundStyle(Color.secondaryText)
                case .loaded:
                    if !viewModel.indexHealth.isHealthy {
                        degradedIndexBanner(viewModel.indexHealth.missing)
                    }
                    summaryChips
                    histogramSection
                    outletSection
                    statusSection
                }
            }
            .padding(.bottom, 16)
        }
        .background(Color.appBackground)
        .task { await load() }
    }

    private func load() async {
        // The factory form is used (rather than opening the reader here first) so a
        // failure to *open* the store — e.g. an unmounted Eregion volume — surfaces
        // through the same `.failed` path `loadPopulation` already guarantees, instead
        // of a second, view-local error state that could disagree with it.
        await viewModel.loadPopulation(readerFactory: { try AggregateReader() })
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Reply Author Population")
                .font(.title2)
                .foregroundStyle(Color.primaryText)
            Text("Everyone who has replied to a tracked outlet")
                .font(.caption)
                .foregroundStyle(Color.secondaryText)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
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
        .padding(.horizontal, 16)
    }

    /// Visible when `AggregateReader.indexHealth()` finds one of `StoreIndexPlan.all`
    /// missing — meaning `IndexReasserter` (run from `BlueXStore.openContainer()`
    /// before this view ever queries) either didn't run for this store or didn't
    /// succeed. This dashboard is a read-only consumer and cannot repair the index
    /// itself, so it says so rather than quietly eating a 27-second query.
    private func degradedIndexBanner(_ missing: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.yellow)
                Text("Missing index — queries may be slow")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.primaryText)
            }
            Text("Not present: \(missing.joined(separator: ", ")). " +
                 "Re-open the store (relaunch, or run any BlueX CLI) to repair it.")
                .font(.caption)
                .foregroundStyle(Color.secondaryText)
        }
        .padding(12)
        .background(Color.hateBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
    }

    // MARK: - Summary chips

    private var summaryChips: some View {
        HStack(spacing: 12) {
            chip(label: "Authors", value: "\(viewModel.population.totalAuthors)", color: .primaryText)
            chip(label: "Replies", value: "\(viewModel.population.totalReplies)", color: .secondaryText)
            chip(label: "Median replies / author", value: "\(viewModel.population.medianRepliesPerAuthor)", color: .neutralBorder)
            chip(label: "Active last 30 days", value: "\(viewModel.population.activeLast30Days)", color: .counterBorder)
        }
        .padding(.horizontal, 16)
    }

    private func chip(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Color.secondaryText)
            Text(value)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(color)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Histogram

    private var histogramSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Replies per author")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.secondaryText)

            if viewModel.population.bins.isEmpty {
                noDataPlaceholder(height: 180)
            } else {
                Chart(viewModel.population.bins) { bin in
                    BarMark(
                        x: .value("Replies", bin.label),
                        y: .value("Authors", bin.authors)
                    )
                    .foregroundStyle(Color.selectedBackground)
                }
                .chartXAxis {
                    AxisMarks {
                        AxisValueLabel().foregroundStyle(Color.mutedText)
                    }
                }
                .chartYAxis {
                    AxisMarks {
                        AxisGridLine().foregroundStyle(Color.neutralBorder.opacity(0.3))
                        AxisValueLabel().foregroundStyle(Color.mutedText)
                    }
                }
                .frame(height: 180)
            }
        }
        .padding(12)
        .background(Color.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
    }

    // MARK: - Outlets

    private var outletSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Authors by outlet")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.secondaryText)

            if viewModel.population.outlets.isEmpty {
                noDataPlaceholder(height: 160)
            } else {
                Chart(viewModel.population.outlets) { outlet in
                    BarMark(
                        x: .value("Authors", outlet.authors),
                        y: .value("Outlet", outlet.handle)
                    )
                    .foregroundStyle(Color.neutralBorder)
                }
                .chartXAxis {
                    AxisMarks {
                        AxisGridLine().foregroundStyle(Color.neutralBorder.opacity(0.3))
                        AxisValueLabel().foregroundStyle(Color.mutedText)
                    }
                }
                .chartYAxis {
                    AxisMarks { AxisValueLabel().foregroundStyle(Color.mutedText) }
                }
                .frame(height: CGFloat(max(120, viewModel.population.outlets.count * 28)))
            }

            // Honesty label 1: overlap is the cross-outlet signal, not double-counting.
            Text(AuthorsFormatting.outletOverlapNote(totalAuthors: viewModel.population.totalAuthors))
                .font(.caption)
                .foregroundStyle(Color.mutedText)
            // Honesty label 2: do not present outlet differences as findings yet.
            Text(AuthorsFormatting.confoundedOutletNote)
                .font(.caption)
                .foregroundStyle(Color.mutedText)
        }
        .padding(12)
        .background(Color.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
    }

    // MARK: - Status

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Account status")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.secondaryText)

            if AuthorsFormatting.statusIsCollected(viewModel.population.statusCounts) {
                ForEach(AuthorsFormatting.sortedStatusRows(viewModel.population.statusCounts), id: \.status) { row in
                    HStack {
                        Text(row.status)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.primaryText)
                        Spacer()
                        Text("\(row.count)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.secondaryText)
                    }
                }
            } else {
                // Honesty label 3: an empty statusCounts must read as "not measured", never
                // as a zeroed chart — a zeroed chart would falsely imply "no takedowns".
                HStack(spacing: 6) {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(Color.mutedText)
                    Text(AuthorsFormatting.statusNotCollectedMessage)
                        .font(.caption)
                        .foregroundStyle(Color.mutedText)
                }
            }
        }
        .padding(12)
        .background(Color.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
    }

    private func noDataPlaceholder(height: CGFloat) -> some View {
        Text("No data yet")
            .font(.system(size: 12))
            .foregroundStyle(Color.mutedText)
            .frame(maxWidth: .infinity, minHeight: height)
    }
}
