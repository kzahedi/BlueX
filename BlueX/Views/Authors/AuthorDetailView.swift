// BlueX/Views/Authors/AuthorDetailView.swift
import SwiftUI
import Charts

/// Per-author detail: identity, headline chips, a weekly reply timeline, and the outlet
/// breakdown for this one author. `ZREPLYAUTHOR` is currently empty, so `handle` is nil for
/// everyone — that is shown as a note that the probe has not run, never as a blank field,
/// which would read as "this author has no handle" rather than "not yet collected".
struct AuthorDetailView: View {
    var viewModel: AuthorStatsViewModel

    var body: some View {
        ScrollView {
            if let author = viewModel.selected {
                VStack(alignment: .leading, spacing: 16) {
                    identityHeader(author)
                    chips(author)
                    timelineChart
                    outletBreakdown
                }
                .padding(.bottom, 16)
            } else {
                emptyState
            }
        }
        .background(Color.appBackground)
    }

    // MARK: - Identity

    private func identityHeader(_ author: AuthorSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(author.handle ?? author.did)
                .font(.title2)
                .foregroundStyle(Color.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)

            if author.handle != nil {
                Text(author.did)
                    .font(.caption)
                    .foregroundStyle(Color.mutedText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                // Handle-not-collected: shown as an explicit note, not an empty field.
                Text(AuthorsFormatting.handleNotCollectedMessage)
                    .font(.caption)
                    .foregroundStyle(Color.mutedText)
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
                    AxisMarks(values: .stride(by: .weekOfYear, count: 4)) {
                        AxisGridLine().foregroundStyle(Color.neutralBorder.opacity(0.3))
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
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
