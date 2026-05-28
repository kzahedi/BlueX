// BlueX/Views/Account/AccountChartsView.swift
import SwiftUI
import Charts
import SwiftData

struct AccountChartsView: View {
    let account: TrackedAccount

    @State private var viewModel = ChartsViewModel()
    @State private var recomputeTask: Task<Void, Never>?
    @Environment(\.modelContext) private var modelContext
    @Query private var posts: [Post]      // account's authored root posts

    init(account: TrackedAccount) {
        self.account = account
        let did = account.did
        self._posts = Query(
            filter: #Predicate<Post> { $0.account?.did == did },
            sort: \Post.createdAt
        )
    }

    /// Recompute the chart's buckets. Fetches only the replies that belong to this
    /// account's root posts (replies have no account relationship, so this is the only
    /// way to scope them). Called via `scheduleRecompute()` which debounces rapid scrape
    /// saves to keep the main thread responsive.
    private func recompute() {
        let rootURIs = Set(posts.map { $0.uri })
        let replies = (try? modelContext.fetch(FetchDescriptor<Post>(
            predicate: #Predicate<Post> { !$0.isRootPost && rootURIs.contains($0.rootURI) }
        ))) ?? []
        viewModel.computeBuckets(from: posts + replies)
    }

    private func scheduleRecompute() {
        recomputeTask?.cancel()
        recomputeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)  // 300 ms
            guard !Task.isCancelled else { return }
            recompute()
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("Analytics")
                        .font(.title2)
                        .foregroundStyle(Color.primaryText)
                    Text("@\(account.handle) · last \(viewModel.windowWeeks) weeks")
                        .font(.caption)
                        .foregroundStyle(Color.secondaryText)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)

                // Summary chips
                summaryRow
                    .padding(.horizontal, 16)

                // Stacked area chart — root posts
                stackedAreaChart
                    .padding(.horizontal, 16)

                // Stacked area chart — replies
                repliesPerWeekChart
                    .padding(.horizontal, 16)

                // Hate ratio chart
                hateRatioChart
                    .padding(.horizontal, 16)

                // Window selector
                windowSelector
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
        }
        .background(Color.appBackground)
        .onAppear { recompute() }
        .onChange(of: posts) { _, _ in scheduleRecompute() }
        .onDisappear { recomputeTask?.cancel() }
    }

    // MARK: - Summary Row

    private var summaryRow: some View {
        HStack(spacing: 12) {
            summaryChip(
                label: "Hate",
                value: "\(viewModel.totalHate)",
                sub: String(format: "%.0f%%", viewModel.overallHateRatio * 100),
                color: .hateBorder
            )
            summaryChip(
                label: "Counter",
                value: "\(viewModel.totalCounter)",
                sub: String(format: "%.0f%%", viewModel.overallCounterRatio * 100),
                color: .counterBorder
            )
            summaryChip(
                label: "Posts",
                value: "\(viewModel.totalPosts)",
                sub: "\(viewModel.visibleBuckets.count) weeks",
                color: .neutralBorder
            )
            summaryChip(
                label: "Replies",
                value: "\(viewModel.totalReplies)",
                sub: String(format: "%.0f%% hate", viewModel.totalReplies > 0 ? Double(viewModel.totalReplyHate) / Double(viewModel.totalReplies) * 100 : 0),
                color: .secondaryText
            )
            if abs(viewModel.hateTrend) > 0.01 {
                summaryChip(
                    label: "Trend",
                    value: String(format: "%+.0f%%", viewModel.hateTrend * 100),
                    sub: "hate last week",
                    color: viewModel.hateTrend > 0 ? .hateBorder : .counterBorder
                )
            }
        }
    }

    private func summaryChip(label: String, value: String, sub: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Color.secondaryText)
            Text(value)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(color)
            Text(sub)
                .font(.system(size: 10))
                .foregroundStyle(Color.mutedText)
        }
        .padding(10)
        .background(Color.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Stacked Area Chart

    private var stackedAreaChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Posts by week")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.secondaryText)

            if viewModel.visibleBuckets.isEmpty {
                noDataPlaceholder(height: 180)
            } else {
                Chart {
                    ForEach(viewModel.visibleBuckets) { bucket in
                        AreaMark(
                            x: .value("Week", bucket.weekStart),
                            y: .value("Pending", bucket.pendingCount)
                        )
                        .foregroundStyle(Color.pendingBackground)
                        .interpolationMethod(.catmullRom)

                        AreaMark(
                            x: .value("Week", bucket.weekStart),
                            y: .value("Neutral", bucket.pendingCount + bucket.neutralCount)
                        )
                        .foregroundStyle(Color.neutralBackground)
                        .interpolationMethod(.catmullRom)

                        AreaMark(
                            x: .value("Week", bucket.weekStart),
                            y: .value("Counter", bucket.pendingCount + bucket.neutralCount + bucket.counterCount)
                        )
                        .foregroundStyle(Color.counterBackground)
                        .interpolationMethod(.catmullRom)

                        AreaMark(
                            x: .value("Week", bucket.weekStart),
                            y: .value("Hate", bucket.pendingCount + bucket.neutralCount + bucket.counterCount + bucket.hateCount)
                        )
                        .foregroundStyle(Color.hateBackground)
                        .interpolationMethod(.catmullRom)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .weekOfYear, count: 2)) {
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
                .frame(height: 180)

                HStack(spacing: 12) {
                    legendDot(color: .hateBackground, label: "Hate")
                    legendDot(color: .counterBackground, label: "Counter")
                    legendDot(color: .neutralBackground, label: "Neutral")
                    legendDot(color: .pendingBackground, label: "Pending")
                    Spacer()
                }
            }
        }
        .padding(12)
        .background(Color.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Replies per Week Chart

    private var repliesPerWeekChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Replies by week")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.secondaryText)
                Spacer()
                Text("Responses to tracked posts")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.mutedText)
            }

            if viewModel.visibleBuckets.isEmpty || viewModel.visibleBuckets.allSatisfy({ $0.replyTotal == 0 }) {
                noDataPlaceholder(height: 180)
            } else {
                Chart {
                    ForEach(viewModel.visibleBuckets) { bucket in
                        // Stacked bottom → top: pending → neutral → counter → hate.
                        AreaMark(
                            x: .value("Week", bucket.weekStart),
                            y: .value("Pending", bucket.replyPendingCount)
                        )
                        .foregroundStyle(Color.pendingBackground)
                        .interpolationMethod(.catmullRom)

                        AreaMark(
                            x: .value("Week", bucket.weekStart),
                            y: .value("Neutral", bucket.replyPendingCount + bucket.replyNeutralCount)
                        )
                        .foregroundStyle(Color.neutralBackground)
                        .interpolationMethod(.catmullRom)

                        AreaMark(
                            x: .value("Week", bucket.weekStart),
                            y: .value("Counter", bucket.replyPendingCount + bucket.replyNeutralCount + bucket.replyCounterCount)
                        )
                        .foregroundStyle(Color.counterBackground)
                        .interpolationMethod(.catmullRom)

                        AreaMark(
                            x: .value("Week", bucket.weekStart),
                            y: .value("Hate", bucket.replyPendingCount + bucket.replyNeutralCount + bucket.replyCounterCount + bucket.replyHateCount)
                        )
                        .foregroundStyle(Color.hateBackground)
                        .interpolationMethod(.catmullRom)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .weekOfYear, count: 2)) {
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
                .frame(height: 180)

                HStack(spacing: 12) {
                    legendDot(color: .hateBackground, label: "Hate")
                    legendDot(color: .counterBackground, label: "Counter")
                    legendDot(color: .neutralBackground, label: "Neutral")
                    legendDot(color: .pendingBackground, label: "Pending")
                    Spacer()
                }
            }
        }
        .padding(12)
        .background(Color.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.system(size: 10)).foregroundStyle(Color.secondaryText)
        }
    }

    // MARK: - Hate Ratio Chart

    private var hateRatioChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Hate ratio per week")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.secondaryText)

            if viewModel.visibleBuckets.isEmpty {
                noDataPlaceholder(height: 120)
            } else {
                Chart {
                    ForEach(viewModel.visibleBuckets) { bucket in
                        LineMark(
                            x: .value("Week", bucket.weekStart),
                            y: .value("Hate %", bucket.hateRatio * 100)
                        )
                        .foregroundStyle(Color.hateBorder)
                        .interpolationMethod(.catmullRom)

                        AreaMark(
                            x: .value("Week", bucket.weekStart),
                            y: .value("Hate %", bucket.hateRatio * 100)
                        )
                        .foregroundStyle(Color.hateBackground.opacity(0.5))
                        .interpolationMethod(.catmullRom)
                    }
                    RuleMark(y: .value("Reference", 10))
                        .foregroundStyle(Color.neutralBorder.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .weekOfYear, count: 2)) {
                        AxisGridLine().foregroundStyle(Color.neutralBorder.opacity(0.3))
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                            .foregroundStyle(Color.mutedText)
                    }
                }
                .chartYAxis {
                    AxisMarks {
                        AxisGridLine().foregroundStyle(Color.neutralBorder.opacity(0.3))
                        AxisValueLabel()
                            .foregroundStyle(Color.mutedText)
                    }
                }
                .frame(height: 120)
            }
        }
        .padding(12)
        .background(Color.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Window Selector

    private var windowSelector: some View {
        HStack(spacing: 8) {
            Text("Window:")
                .font(.system(size: 11))
                .foregroundStyle(Color.secondaryText)
            ForEach([4, 8, 12, 24, 52], id: \.self) { weeks in
                Button("\(weeks)w") {
                    viewModel.windowWeeks = weeks
                }
                .font(.system(size: 11))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(viewModel.windowWeeks == weeks ? Color.selectedBackground : Color.panelBackground)
                .foregroundStyle(viewModel.windowWeeks == weeks ? Color.primaryText : Color.secondaryText)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Helpers

    private func noDataPlaceholder(height: CGFloat) -> some View {
        Text("No data yet")
            .font(.system(size: 12))
            .foregroundStyle(Color.mutedText)
            .frame(maxWidth: .infinity, minHeight: height)
    }
}
