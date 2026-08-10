// BlueX/Views/Account/AccountChartsView.swift
import SwiftUI
import Charts

struct AccountChartsView: View {
    let account: TrackedAccount

    @State private var viewModel = ChartsViewModel()
    @State private var reader: AggregateReader?
    @State private var loadError: String?

    private var sortedSnapshots: [AccountSnapshot] {
        account.snapshots.sorted { $0.timestamp < $1.timestamp }
    }

    /// Resolves this account's `Z_PK` (SwiftData does not expose it) and loads its
    /// weekly buckets from the SQL aggregates — off the main actor. Replaces a `@Query`
    /// over every root post plus a `Set`-predicate fetch of every reply, which together
    /// materialised up to ~874k `Post` objects per account click.
    private func load() async {
        do {
            let reader = try self.reader ?? AggregateReader()
            self.reader = reader
            guard let pk = try reader.accountPK(did: account.did) else {
                guard !Task.isCancelled else { return }
                loadError = "Account not found in the store (did: \(account.did))"
                return
            }
            // `viewModel.load` itself guards its own publish against cancellation; this
            // guard covers `loadError` below, which is set outside that call.
            await viewModel.load(accountPKs: [pk], reader: reader)
            guard !Task.isCancelled else { return }
            loadError = nil
        } catch {
            guard !Task.isCancelled else { return }
            loadError = error.localizedDescription
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

                if let loadError {
                    Text(loadError)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.hateBorder)
                        .padding(.horizontal, 16)
                }

                // Summary chips
                summaryRow
                    .padding(.horizontal, 16)

                // Stacked area chart — root posts
                stackedAreaChart
                    .padding(.horizontal, 16)

                // Stacked area chart — replies
                repliesPerWeekChart
                    .padding(.horizontal, 16)

                // Apple sentiment trend
                sentimentChart
                    .padding(.horizontal, 16)

                // Hate ratio chart
                hateRatioChart
                    .padding(.horizontal, 16)

                // Account growth (followers / following / posts over time)
                accountGrowthChart
                    .padding(.horizontal, 16)

                // Engagement totals (likes / replies / reposts / quotes over time)
                engagementTotalsChart
                    .padding(.horizontal, 16)

                // Window selector
                windowSelector
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
        }
        .background(Color.appBackground)
        .task(id: account.did) { await load() }
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
                        // Charts auto-stacks AreaMarks sharing the same y-label when
                        // they're distinguished by .foregroundStyle(by:); each stage
                        // is then a continuous series across the weeks, not 10 disconnected
                        // shapes — which is what produced the sawtooth before.
                        AreaMark(x: .value("Week", bucket.weekStart),
                                 y: .value("Count", bucket.pendingCount))
                            .foregroundStyle(by: .value("Stage", "Pending"))
                            .interpolationMethod(.catmullRom)
                        AreaMark(x: .value("Week", bucket.weekStart),
                                 y: .value("Count", bucket.neutralCount))
                            .foregroundStyle(by: .value("Stage", "Neutral"))
                            .interpolationMethod(.catmullRom)
                        AreaMark(x: .value("Week", bucket.weekStart),
                                 y: .value("Count", bucket.counterCount))
                            .foregroundStyle(by: .value("Stage", "Counter"))
                            .interpolationMethod(.catmullRom)
                        AreaMark(x: .value("Week", bucket.weekStart),
                                 y: .value("Count", bucket.hateCount))
                            .foregroundStyle(by: .value("Stage", "Hate"))
                            .interpolationMethod(.catmullRom)
                    }
                }
                .chartForegroundStyleScale([
                    "Pending": Color.pendingBackground,
                    "Neutral": Color.neutralBackground,
                    "Counter": Color.counterBackground,
                    "Hate":    Color.hateBackground,
                ])
                .chartLegend(.hidden)
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
                        AreaMark(x: .value("Week", bucket.weekStart),
                                 y: .value("Count", bucket.replyPendingCount))
                            .foregroundStyle(by: .value("Stage", "Pending"))
                            .interpolationMethod(.catmullRom)
                        AreaMark(x: .value("Week", bucket.weekStart),
                                 y: .value("Count", bucket.replyNeutralCount))
                            .foregroundStyle(by: .value("Stage", "Neutral"))
                            .interpolationMethod(.catmullRom)
                        AreaMark(x: .value("Week", bucket.weekStart),
                                 y: .value("Count", bucket.replyCounterCount))
                            .foregroundStyle(by: .value("Stage", "Counter"))
                            .interpolationMethod(.catmullRom)
                        AreaMark(x: .value("Week", bucket.weekStart),
                                 y: .value("Count", bucket.replyHateCount))
                            .foregroundStyle(by: .value("Stage", "Hate"))
                            .interpolationMethod(.catmullRom)
                    }
                }
                .chartForegroundStyleScale([
                    "Pending": Color.pendingBackground,
                    "Neutral": Color.neutralBackground,
                    "Counter": Color.counterBackground,
                    "Hate":    Color.hateBackground,
                ])
                .chartLegend(.hidden)
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

    // MARK: - Sentiment Chart (Apple NLTagger)

    private var sentimentChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Sentiment per week")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.secondaryText)
                Spacer()
                Text("Apple NLTagger · −1 to +1")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.mutedText)
            }

            if viewModel.visibleBuckets.allSatisfy({ $0.sentimentSampleCount == 0 }) {
                noDataPlaceholder(height: 120)
            } else {
                Chart {
                    ForEach(viewModel.visibleBuckets) { bucket in
                        if bucket.sentimentSampleCount > 0 {
                            AreaMark(
                                x: .value("Week", bucket.weekStart),
                                y: .value("Sentiment", bucket.avgSentiment)
                            )
                            .foregroundStyle(
                                Gradient(colors: [
                                    Color.counterBackground.opacity(0.55),
                                    Color.hateBackground.opacity(0.55),
                                ])
                            )
                            .interpolationMethod(.catmullRom)

                            LineMark(
                                x: .value("Week", bucket.weekStart),
                                y: .value("Sentiment", bucket.avgSentiment)
                            )
                            .foregroundStyle(Color.primaryText.opacity(0.85))
                            .interpolationMethod(.catmullRom)
                        }
                    }
                    RuleMark(y: .value("Zero", 0))
                        .foregroundStyle(Color.mutedText.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                }
                .chartYScale(domain: -1...1)
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
                .frame(height: 120)
            }
        }
        .padding(12)
        .background(Color.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
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

    // MARK: - Account Growth Chart

    // Why: snapshot charts show full history — weekly window would defeat the
    // purpose of a long-horizon growth trend.
    private var accountGrowthChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Account growth")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.secondaryText)

            if sortedSnapshots.count < 2 {
                noDataPlaceholder(height: 150)
            } else {
                Chart {
                    ForEach(sortedSnapshots) { snap in
                        LineMark(
                            x: .value("Date", snap.timestamp),
                            y: .value("Count", snap.followerCount)
                        )
                        .foregroundStyle(by: .value("Metric", "Followers"))

                        LineMark(
                            x: .value("Date", snap.timestamp),
                            y: .value("Count", snap.followingCount)
                        )
                        .foregroundStyle(by: .value("Metric", "Following"))

                        LineMark(
                            x: .value("Date", snap.timestamp),
                            y: .value("Count", snap.postCount)
                        )
                        .foregroundStyle(by: .value("Metric", "Posts"))
                    }
                }
                .chartForegroundStyleScale([
                    "Followers": Color.accentColor,
                    "Following": Color.secondaryText,
                    "Posts":     Color.orange,
                ])
                .chartLegend(.hidden)
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
                .frame(height: 150)

                HStack(spacing: 12) {
                    legendDot(color: .accentColor,    label: "Followers")
                    legendDot(color: .secondaryText,  label: "Following")
                    legendDot(color: .orange,         label: "Posts")
                    Spacer()
                }
            }
        }
        .padding(12)
        .background(Color.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Engagement Totals Chart

    // Why: snapshot charts show full history — weekly window would defeat the
    // purpose of a long-horizon engagement trend.
    private var engagementTotalsChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Engagement totals")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.secondaryText)
                Spacer()
                Text("Computed from scraped posts")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.mutedText)
            }

            if sortedSnapshots.count < 2 {
                noDataPlaceholder(height: 150)
            } else {
                Chart {
                    ForEach(sortedSnapshots) { snap in
                        LineMark(
                            x: .value("Date", snap.timestamp),
                            y: .value("Count", snap.totalLikes)
                        )
                        .foregroundStyle(by: .value("Metric", "Likes"))

                        LineMark(
                            x: .value("Date", snap.timestamp),
                            y: .value("Count", snap.totalReplies)
                        )
                        .foregroundStyle(by: .value("Metric", "Replies"))

                        LineMark(
                            x: .value("Date", snap.timestamp),
                            y: .value("Count", snap.totalReposts)
                        )
                        .foregroundStyle(by: .value("Metric", "Reposts"))

                        LineMark(
                            x: .value("Date", snap.timestamp),
                            y: .value("Count", snap.totalQuotes)
                        )
                        .foregroundStyle(by: .value("Metric", "Quotes"))
                    }
                }
                .chartForegroundStyleScale([
                    "Likes":   Color.counterBorder,
                    "Replies": Color.secondaryText,
                    "Reposts": Color.neutralBorder,
                    "Quotes":  Color.hateBorder.opacity(0.6),
                ])
                .chartLegend(.hidden)
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
                .frame(height: 150)

                HStack(spacing: 12) {
                    legendDot(color: .counterBorder,           label: "Likes")
                    legendDot(color: .secondaryText,           label: "Replies")
                    legendDot(color: .neutralBorder,           label: "Reposts")
                    legendDot(color: .hateBorder.opacity(0.6), label: "Quotes")
                    Spacer()
                }
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
