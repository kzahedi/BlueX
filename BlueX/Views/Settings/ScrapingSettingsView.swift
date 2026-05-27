// BlueX/Views/Settings/ScrapingSettingsView.swift
import SwiftUI

struct ScrapingSettingsView: View {
    // Persist settings in UserDefaults (not sensitive data)
    @AppStorage("scraping.batchSize") private var batchSize: Int = 50
    @AppStorage("scraping.maxDepth") private var maxDepth: Int = 3
    @AppStorage("scraping.maxRepliesPerPost") private var maxRepliesPerPost: Int = 100
    @AppStorage("scraping.maxRescrapeWindowDays") private var maxRescrapeWindowDays: Int = 14
    @AppStorage("scraping.autoStartAfterScrape") private var autoStartAnnotation: Bool = true
    @AppStorage("scraping.skipAlreadyAnnotated") private var skipAlreadyAnnotated: Bool = true
    @AppStorage("scraping.rateLimitBuffer") private var rateLimitBuffer: Int = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text("Scraping Settings")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.primaryText)
                Text("Controls how the feed and thread scrapers behave. Changes take effect on the next scrape run.")
                    .font(.caption)
                    .foregroundStyle(Color.secondaryText)
            }

            Divider().background(Color.neutralBorder)

            // Feed scraping
            settingsGroup(title: "Feed Scraping") {
                stepper(label: "Posts per account per run", value: $batchSize, range: 10...500, step: 10) {
                    "Fetch up to \(batchSize) recent posts per account"
                }
            }

            Divider().background(Color.neutralBorder)

            // Thread scraping
            settingsGroup(title: "Thread Scraping") {
                stepper(label: "Max reply depth", value: $maxDepth, range: 1...10, step: 1) {
                    "Replies nested \(maxDepth) levels deep"
                }
                stepper(label: "Max replies per post", value: $maxRepliesPerPost, range: 10...500, step: 10) {
                    "Stop after \(maxRepliesPerPost) replies per thread"
                }
                stepper(label: "Reply-tree refresh window (days)", value: $maxRescrapeWindowDays, range: 1...90, step: 1) {
                    "Keep refreshing a post's replies for \(maxRescrapeWindowDays) days after it was posted, then freeze"
                }
            }

            Divider().background(Color.neutralBorder)

            // Annotation
            settingsGroup(title: "Annotation") {
                toggle(label: "Auto-annotate after scrape", value: $autoStartAnnotation,
                       description: "Automatically run NLTagger baseline after each scrape")
                toggle(label: "Skip already annotated posts", value: $skipAlreadyAnnotated,
                       description: "Don't re-annotate posts that already have an LLM annotation")
            }

            Divider().background(Color.neutralBorder)

            // Rate limiting
            settingsGroup(title: "Rate Limiting") {
                stepper(label: "Rate limit buffer (requests/hour)", value: $rateLimitBuffer, range: 100...2800, step: 100) {
                    "Reserve \(rateLimitBuffer) of the 3,000 req/hour limit as buffer"
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Bluesky Public API limit: 3,000 requests/hour")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.mutedText)
                    Text("Effective limit: \(3000 - rateLimitBuffer) req/hour")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondaryText)
                }
            }

            Divider().background(Color.neutralBorder)

            // Reset button
            Button("Reset to Defaults") {
                batchSize = 50
                maxDepth = 3
                maxRepliesPerPost = 100
                maxRescrapeWindowDays = 14
                autoStartAnnotation = true
                skipAlreadyAnnotated = true
                rateLimitBuffer = 200
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

    private func toggle(label: String, value: Binding<Bool>, description: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.primaryText)
                Text(description)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.mutedText)
            }
            Spacer()
            Toggle("", isOn: value)
                .labelsHidden()
                .tint(Color.counterBorder)
        }
    }
}
