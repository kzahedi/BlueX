// BlueX/Views/RootView.swift
import SwiftUI
import SwiftData

// MARK: - SidebarItem
enum SidebarItem: Hashable {
    case group(AccountGroup)
    case account(TrackedAccount)
    case post(Post)
    case authors
    case labelling
    case queue
    case settings
}

// MARK: - RootView
struct RootView: View {
    @State private var sidebarVM = SidebarViewModel()
    @State private var authorsVM = AuthorStatsViewModel()
    @State private var labellingVM = LabellingViewModel(annotatorID: NSUserName())
    @State private var selectedItem: SidebarItem? = nil
    @State private var coordinator: ScrapeCoordinator? = nil
    @State private var history = SelectionHistory()
    /// Set for the duration of a programmatic `goBack()` assignment so the resulting
    /// `onChange` does not record the very selection we just navigated away from —
    /// otherwise pressing back twice would bounce between two items forever.
    @State private var isNavigatingBack = false
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SidebarView(
                viewModel: sidebarVM,
                selection: $selectedItem,
                onStartScrape: { coordinator?.startScrape() },
                onCancelScrape: { coordinator?.cancel() },
                onScrapeAccount: { account in coordinator?.startScrape(accountDID: account.did) }
            )
        } content: {
            contentColumn
        } detail: {
            detailColumn
        }
        .frame(minWidth: 1200, minHeight: 700)
        .preferredColorScheme(.dark)
        .task {
            if coordinator == nil {
                coordinator = ScrapeCoordinator(api: BlueskyAPIClient(), modelContainer: modelContext.container)
            }
            // Seed / prune accounts to match the current seed set
            try? AccountSeeder.resetToSeedSet(in: modelContext)
            // Keep the installed-model presets in sync (replaces stale llama3.2 etc.)
            try? AccountSeeder.ensureModelConfigs(in: modelContext)
            // Clean up any (post, model) duplicates left over from earlier prompt-
            // revision runs; keeps the newest per (post, model). Safe to run every
            // launch — does nothing once the store is clean.
            try? AnnotationDedup.dedupLLM(in: modelContext)
        }
        .onChange(of: coordinator?.phase) { _, newPhase in
            sidebarVM.scrapePhase = newPhase ?? .idle
        }
        .onChange(of: coordinator?.currentAccountHandle) { _, newHandle in
            sidebarVM.activeScrapeHandle = (newHandle?.isEmpty == false) ? newHandle : nil
        }
        .onChange(of: coordinator?.progress) { _, newProgress in
            sidebarVM.scrapeProgress = newProgress ?? 0.0
        }
        .onChange(of: coordinator?.lastError) { _, newError in
            sidebarVM.lastError = newError ?? nil
        }
        .onChange(of: coordinator?.accountStatuses) { _, newStatuses in
            sidebarVM.accountStatuses = newStatuses ?? [:]
        }
        .onChange(of: selectedItem) { oldValue, _ in
            if isNavigatingBack {
                isNavigatingBack = false
                return
            }
            history.record(oldValue)
        }
    }

    private func goBack() {
        guard let previous = history.goBack() else { return }
        isNavigatingBack = true
        selectedItem = previous
    }

    @ViewBuilder
    private var contentColumn: some View {
        switch selectedItem {
        case .group(let group):
            GroupContentView(group: group, selection: $selectedItem)
        case .account(let account):
            AccountContentView(
                account: account,
                selection: $selectedItem,
                onScrapeAccount: { acct in coordinator?.startScrape(accountDID: acct.did) }
            )
        case .post(let post):
            ThreadView(rootPost: post, canGoBack: history.canGoBack, onBack: goBack)
        case .authors:
            AuthorListView(viewModel: authorsVM)
        case .labelling:
            LabellingHomeView(viewModel: labellingVM)
        case .queue, .settings, nil:
            Color.appBackground
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        switch selectedItem {
        case .group(let group):
            GroupChartsView(group: group)
        case .account(let account):
            AccountChartsView(account: account)
        case .post(let post):
            ThreadGraphView(rootPost: post)
        case .authors:
            AuthorsOverviewView(viewModel: authorsVM, selection: $selectedItem)
        case .labelling:
            LabellingSessionView(viewModel: labellingVM)
        case .queue:
            if let coordinator = coordinator {
                QueueView(coordinator: coordinator, modelContainer: modelContext.container)
            } else {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .settings:
            SettingsView()
        case nil:
            emptyDetailState
        }
    }

    private var emptyDetailState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 40))
                .foregroundStyle(Color.mutedText)
            Text("Select an account or group")
                .font(.title3)
                .foregroundStyle(Color.secondaryText)
            Text("Research instrument for hate and counter speech analysis on Bluesky")
                .font(.caption)
                .foregroundStyle(Color.mutedText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
    }
}
