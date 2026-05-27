// BlueX/Views/Group/GroupChartsView.swift
import SwiftUI
import Charts
import SwiftData

struct GroupChartsView: View {
    let group: AccountGroup

    @State private var viewModel = ChartsViewModel()
    @State private var selectedMetric: GroupMetric = .hate

    enum GroupMetric: String, CaseIterable {
        case hate = "Hate"
        case counter = "Counter"
        case neutral = "Neutral"
        case total = "Total"
    }

    // Per-account view models for small multiples
    @State private var accountViewModels: [String: ChartsViewModel] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("Group Analytics")
                        .font(.title2)
                        .foregroundStyle(Color.primaryText)
                    Text("\(group.name) · \(group.accounts.count) accounts")
                        .font(.caption)
                        .foregroundStyle(Color.secondaryText)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)

                // Metric selector
                metricSelector
                    .padding(.horizontal, 16)

                // Overlaid multi-series chart
                overlaidChart
                    .padding(.horizontal, 16)

                // Small multiples
                Text("Per-account breakdown")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.secondaryText)
                    .padding(.horizontal, 16)

                smallMultiplesGrid
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
        }
        .background(Color.appBackground)
        .onAppear { computeAllBuckets() }
        .onChange(of: group.accounts) { _, _ in computeAllBuckets() }
    }

    // MARK: - Metric Selector

    private var metricSelector: some View {
        HStack(spacing: 6) {
            ForEach(GroupMetric.allCases, id: \.self) { metric in
                Button(metric.rawValue) {
                    selectedMetric = metric
                }
                .font(.system(size: 11))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(selectedMetric == metric ? metricColor(metric) : Color.panelBackground)
                .foregroundStyle(selectedMetric == metric ? Color.primaryText : Color.secondaryText)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .buttonStyle(.plain)
            }
        }
    }

    private func metricColor(_ metric: GroupMetric) -> Color {
        switch metric {
        case .hate:    return Color.hateBackground
        case .counter: return Color.counterBackground
        case .neutral: return Color.neutralBackground
        case .total:   return Color.selectedBackground
        }
    }

    // MARK: - Overlaid Chart

    private var overlaidChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(selectedMetric.rawValue) posts per week — all accounts")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.secondaryText)

            let colors: [Color] = [.hateBorder, .counterBorder, .neutralBorder, .primaryText,
                                   .hateBadgeText, .counterBadgeText, .neutralBadgeText]

            if group.accounts.isEmpty {
                noDataPlaceholder(height: 200)
            } else {
                Chart {
                    ForEach(Array(group.accounts.enumerated()), id: \.element.did) { index, account in
                        let avm = accountViewModels[account.did]
                        let buckets = avm?.visibleBuckets ?? []
                        let color = colors[index % colors.count]

                        ForEach(buckets) { bucket in
                            LineMark(
                                x: .value("Week", bucket.weekStart),
                                y: .value(account.handle, metricValue(bucket: bucket))
                            )
                            .foregroundStyle(color)
                            .symbol(Circle().strokeBorder(lineWidth: 2))
                            .symbolSize(20)
                        }
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
                .frame(height: 200)
            }
        }
        .padding(12)
        .background(Color.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func metricValue(bucket: WeekBucket) -> Int {
        switch selectedMetric {
        case .hate:    return bucket.hateCount
        case .counter: return bucket.counterCount
        case .neutral: return bucket.neutralCount
        case .total:   return bucket.total
        }
    }

    // MARK: - Small Multiples

    private var smallMultiplesGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
            ForEach(group.accounts, id: \.did) { account in
                smallMultiple(for: account)
            }
        }
    }

    private func smallMultiple(for account: TrackedAccount) -> some View {
        let avm = accountViewModels[account.did]
        let buckets = avm?.visibleBuckets ?? []

        return VStack(alignment: .leading, spacing: 6) {
            Text("@\(account.handle)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.secondaryText)
                .lineLimit(1)

            if buckets.isEmpty {
                Text("No data")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.mutedText)
                    .frame(height: 70)
            } else {
                Chart {
                    ForEach(buckets) { bucket in
                        BarMark(
                            x: .value("Week", bucket.weekStart),
                            y: .value("Hate", bucket.hateCount),
                            width: .ratio(0.8)
                        )
                        .foregroundStyle(Color.hateBackground)

                        BarMark(
                            x: .value("Week", bucket.weekStart),
                            y: .value("Counter", bucket.counterCount),
                            width: .ratio(0.8)
                        )
                        .foregroundStyle(Color.counterBackground)
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 70)
            }

            HStack(spacing: 4) {
                let total = avm?.totalPosts ?? 0
                let hate = avm?.totalHate ?? 0
                Text("\(total) posts")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.mutedText)
                if total > 0 {
                    Text("·")
                        .foregroundStyle(Color.mutedText)
                    Text(String(format: "%.0f%% hate", Double(hate) / Double(total) * 100))
                        .font(.system(size: 10))
                        .foregroundStyle(Color.hateBorder)
                }
            }
        }
        .padding(10)
        .background(Color.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Helpers

    private func computeAllBuckets() {
        var avms: [String: ChartsViewModel] = [:]
        for account in group.accounts {
            let avm = ChartsViewModel()
            avm.computeBuckets(from: account.posts)
            avms[account.did] = avm
        }
        accountViewModels = avms

        // Combined buckets for the group
        let allPosts = group.accounts.flatMap { $0.posts }
        viewModel.computeBuckets(from: allPosts)
    }

    private func noDataPlaceholder(height: CGFloat) -> some View {
        Text("No data yet")
            .font(.system(size: 12))
            .foregroundStyle(Color.mutedText)
            .frame(maxWidth: .infinity, minHeight: height)
    }
}
