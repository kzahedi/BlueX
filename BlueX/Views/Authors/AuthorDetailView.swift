// BlueX/Views/Authors/AuthorDetailView.swift
import SwiftUI
import SwiftData
import Charts

/// Per-author detail: identity, headline chips, a weekly reply timeline, the outlet
/// breakdown, and the author's reply list, for this one author.
///
/// **Identity.** The pane's title is the handle on the author's *most recent reply*
/// (`AuthorStatsViewModel.selectedHandle`, backed by `ZPOST.ZAUTHORHANDLE` — populated on
/// every reply row already) — not `AuthorSummary.handle`, which comes from the
/// still-empty `ZREPLYAUTHOR.ZCURRENTHANDLE` and is nil for everyone until the profile
/// probe runs. The DID stays visible underneath, always: it is the stable research
/// identifier, and handles are reused/changed — exactly why the identity model is
/// DID-keyed in the first place. When an author's replies carry more than one distinct
/// handle, that is shown too — a handle change is an evasion indicator, not noise.
struct AuthorDetailView: View {
    var viewModel: AuthorStatsViewModel
    @Binding var selection: SidebarItem?

    @Environment(\.modelContext) private var modelContext

    /// Only `repliesSection`'s row list scrolls independently. Everything above it
    /// (identity, chips, chart, outlet breakdown) sits in its own `ScrollView` rather than
    /// a plain `VStack` — not because it is expected to scroll in ordinary use, but so
    /// that on a short window it can, instead of either clipping silently or squeezing the
    /// reply list toward zero height. `repliesSection` below carries a `minHeight` floor
    /// for exactly that reason: whichever section runs out of room first, the reply list —
    /// the pane's primary navigation surface — always keeps a usable minimum, and it is
    /// the fixed section that yields by becoming scrollable instead.
    ///
    /// This is two independent, vertically-stacked scroll regions, not one nested inside
    /// the other — nesting (a `ScrollView` inside another `ScrollView` on the same axis)
    /// is what behaves badly on macOS; siblings do not.
    var body: some View {
        Group {
            if let author = viewModel.selected {
                VStack(alignment: .leading, spacing: 16) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            identityHeader(author)
                            chips(author)
                            timelineChart
                            outletBreakdown
                        }
                    }
                    repliesSection
                        .frame(minHeight: 150, maxHeight: .infinity)
                }
                .padding(.bottom, 16)
            } else {
                ScrollView {
                    emptyState
                }
            }
        }
        .background(Color.appBackground)
    }

    // MARK: - Identity

    private func identityHeader(_ author: AuthorSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(viewModel.selectedHandle ?? author.did)
                .font(.title2)
                .foregroundStyle(Color.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)

            // The DID is always shown, and always secondary — it is the stable research
            // identifier, never replaced by the handle even when one is available.
            Text(author.did)
                .font(.caption)
                .foregroundStyle(Color.mutedText)
                .lineLimit(1)
                .truncationMode(.middle)

            if viewModel.selectedHandle != nil {
                // The handle is honestly labelled as of the most recent reply, not
                // implied to be the author's handle today.
                Text(AuthorsFormatting.mostRecentHandleCaption)
                    .font(.caption2)
                    .foregroundStyle(Color.mutedText)
            } else {
                // Handle-not-collected: shown as an explicit note, not an empty field.
                Text(AuthorsFormatting.handleNotCollectedMessage)
                    .font(.caption)
                    .foregroundStyle(Color.mutedText)
            }

            if viewModel.selectedHandleHistory.count > 1 {
                Text(AuthorsFormatting.multipleHandlesNote(viewModel.selectedHandleHistory))
                    .font(.caption2)
                    .foregroundStyle(Color.counterBorder)
                    .lineLimit(2)
            }

            // No per-author status exists in the data model yet (ZREPLYAUTHOR is empty),
            // so this states the same fact rather than fabricating a per-row value.
            Text(AuthorsFormatting.perAuthorStatusNotCollectedMessage)
                .font(.caption)
                .foregroundStyle(Color.mutedText)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    // MARK: - Chips

    private func chips(_ author: AuthorSummary) -> some View {
        HStack(spacing: 12) {
            chip(label: "Replies", value: "\(author.replyCount)", color: .primaryText)
            chip(label: "First seen", value: author.firstSeen.formatted(date: .abbreviated, time: .omitted), color: .secondaryText)
            chip(label: "Last seen", value: author.lastSeen.formatted(date: .abbreviated, time: .omitted), color: .secondaryText)
            chip(label: "Span (days)", value: "\(author.spanDays)", color: .neutralBorder)
            chip(label: "Outlets", value: "\(author.outletCount)", color: .counterBorder)
        }
        .padding(.horizontal, 16)
    }

    private func chip(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Color.secondaryText)
            Text(value)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Timeline

    private var timelineChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Replies per week")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.secondaryText)

            if viewModel.selectedWeeks.isEmpty {
                noDataPlaceholder(height: 160)
            } else {
                Chart(viewModel.selectedWeeks) { week in
                    LineMark(
                        x: .value("Week", week.weekStart),
                        y: .value("Replies", week.count)
                    )
                    .foregroundStyle(Color.selectedBackground)
                    .interpolationMethod(.catmullRom)
                }
                .chartXAxis {
                    let spanDays = ChartAxisFormatting.spanDays(viewModel.selectedWeeks.map(\.weekStart))
                    AxisMarks(values: .automatic(desiredCount: ChartAxisFormatting.desiredTickCount)) {
                        AxisGridLine().foregroundStyle(Color.neutralBorder.opacity(0.3))
                        AxisValueLabel(format: ChartAxisFormatting.dateFormat(spanDays: spanDays))
                            .foregroundStyle(Color.mutedText)
                    }
                }
                .chartYAxis {
                    AxisMarks {
                        AxisGridLine().foregroundStyle(Color.neutralBorder.opacity(0.3))
                        AxisValueLabel().foregroundStyle(Color.mutedText)
                    }
                }
                .frame(height: 160)
            }
        }
        .padding(12)
        .background(Color.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
    }

    // MARK: - Outlet breakdown

    private var outletBreakdown: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Outlet breakdown")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.secondaryText)

            if viewModel.selectedOutlets.isEmpty {
                noDataPlaceholder(height: 60)
            } else {
                ForEach(viewModel.selectedOutlets) { outlet in
                    HStack {
                        Text(outlet.handle)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.primaryText)
                        Spacer()
                        Text("\(outlet.replies) replies")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.secondaryText)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
    }

    // MARK: - Replies

    /// This author's replies, newest first, capped at
    /// `AuthorStatsViewModel.replyDisplayCap`. The cap is always stated next to the list
    /// ("Showing N of M replies") — never silent, per the dashboard's recurring bug class.
    ///
    /// The "Replies" label and the "Showing N of M" cap sit outside the inner `ScrollView`
    /// below, so they stay visible above the row list rather than scrolling away with it.
    private var repliesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Replies")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.secondaryText)
                Spacer()
                if viewModel.selectedReplyTotal > 0 {
                    Text(AuthorsFormatting.repliesShownSummary(
                        shown: viewModel.selectedReplies.count,
                        total: viewModel.selectedReplyTotal))
                        .font(.caption2)
                        .foregroundStyle(Color.mutedText)
                }
            }

            if viewModel.selectedReplies.isEmpty {
                noDataPlaceholder(height: 60)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(viewModel.selectedReplies) { reply in
                            AuthorReplyRow(reply: reply) {
                                selectReplyRoot(reply)
                            }
                            if reply.id != viewModel.selectedReplies.last?.id {
                                Divider().background(Color.neutralBorder)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Color.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
    }

    /// Fetches exactly the one `Post` this reply's root URI names — never materialising
    /// anything broader — and navigates into its thread, mirroring
    /// `AccountContentView.selectRoot`.
    private func selectReplyRoot(_ reply: AuthorReply) {
        let rootURI = reply.rootURI
        let descriptor = FetchDescriptor<Post>(predicate: #Predicate<Post> { $0.uri == rootURI })
        if let post = try? modelContext.fetch(descriptor).first {
            selection = .post(post)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 32))
                .foregroundStyle(Color.mutedText)
            Text("Select an author from the list")
                .font(.callout)
                .foregroundStyle(Color.secondaryText)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    private func noDataPlaceholder(height: CGFloat) -> some View {
        Text("No data yet")
            .font(.system(size: 12))
            .foregroundStyle(Color.mutedText)
            .frame(maxWidth: .infinity, minHeight: height)
    }
}

/// One reply row: text, relative timestamp, and a tap target into its thread. Mirrors
/// `RootPostSummaryRow`'s (`AccountContentView.swift`) layout, minus the per-tree status
/// stripe/badge that has no equivalent on a single reply.
private struct AuthorReplyRow: View {
    let reply: AuthorReply
    let onSelect: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(reply.text)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.primaryText)
                    .lineLimit(2)
                Text(reply.createdAt, style: .relative)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.mutedText)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 10))
                .foregroundStyle(Color.mutedText)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }
}
