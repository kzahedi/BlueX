// BlueX/Views/Settings/ScrapingSettingsView.swift
//
// Only one knob actually feeds back into the scrapers today: the reply-tree
// refresh window. Earlier drafts of this panel had additional steppers (batch
// size, max depth, replies per post, auto-annotate toggle, rate-limit buffer)
// but none of them were ever wired through to ScrapeCoordinator / FeedScraper /
// ThreadScraper / the rate limiter. Decorative settings were silently
// misleading, so they were removed. Re-add a row only when the corresponding
// code path actually reads it.
import SwiftUI

struct ScrapingSettingsView: View {
    @AppStorage("scraping.maxRescrapeWindowDays") private var maxRescrapeWindowDays: Int = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Scraping Settings")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.primaryText)
                Text("Controls how the thread scraper behaves. Changes take effect on the next scrape run.")
                    .font(.caption)
                    .foregroundStyle(Color.secondaryText)
            }

            Divider().background(Color.neutralBorder)

            settingsGroup(title: "Thread Scraping") {
                stepper(label: "Reply-tree refresh window (days)",
                        value: $maxRescrapeWindowDays, range: 1...90, step: 1) {
                    "Keep refreshing a post's replies for \(maxRescrapeWindowDays) days after it was posted, then freeze"
                }
            }

            Divider().background(Color.neutralBorder)

            Button("Reset to Default") {
                maxRescrapeWindowDays = 14
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(Color.mutedText)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func settingsGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.secondaryText)
                .textCase(.uppercase)
                .tracking(0.5)
            content()
        }
    }

    private func stepper(
        label: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int,
        description: () -> String
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.primaryText)
                Text(description())
                    .font(.system(size: 10))
                    .foregroundStyle(Color.mutedText)
            }
            Spacer()
            Stepper("\(value.wrappedValue)", value: value, in: range, step: step)
                .labelsHidden()
                .font(.system(size: 12))
                .foregroundStyle(Color.primaryText)
        }
    }
}
