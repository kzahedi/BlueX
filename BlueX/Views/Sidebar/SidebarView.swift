// BlueX/Views/Sidebar/SidebarView.swift
import SwiftUI
import SwiftData

struct SidebarView: View {
    var viewModel: SidebarViewModel
    @Binding var selection: SidebarItem?
    var onStartScrape: (() -> Void)? = nil
    var onCancelScrape: (() -> Void)? = nil
    var onScrapeAccount: ((TrackedAccount) -> Void)? = nil

    @Query(sort: \AccountGroup.name) private var groups: [AccountGroup]
    @Query(sort: \TrackedAccount.displayName) private var accounts: [TrackedAccount]

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section("Groups") {
                    ForEach(groups) { group in
                        NavigationLink(value: SidebarItem.group(group)) {
                            Label(group.name, systemImage: "folder")
                                .foregroundStyle(Color.primaryText)
                        }
                    }
                }
                Section("Accounts") {
                    ForEach(accounts) { account in
                        NavigationLink(value: SidebarItem.account(account)) {
                            accountRow(for: account)
                        }
                        .contextMenu {
                            Button {
                                onScrapeAccount?(account)
                            } label: {
                                Label("Scrape \(account.handle)", systemImage: "arrow.clockwise")
                            }
                            .disabled(onScrapeAccount == nil)
                        }
                    }
                }
                Divider()
                NavigationLink(value: SidebarItem.queue) {
                    Label("Annotation Queue", systemImage: "list.bullet.clipboard")
                        .foregroundStyle(Color.primaryText)
                }
                NavigationLink(value: SidebarItem.settings) {
                    Label("Settings", systemImage: "gear")
                        .foregroundStyle(Color.primaryText)
                }
            }
            .listStyle(.sidebar)
            .background(Color.appBackground)
            if let error = viewModel.lastError {
                errorBanner(error: error)
            }
            scrapeBar
        }
        .frame(minWidth: 220)
        .background(Color.appBackground)
    }

    // MARK: - Scrape bar (bottom of sidebar)

    private var scrapeBar: some View {
        let isRunning = viewModel.scrapePhase != .idle
        return VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                if isRunning {
                    // Spinning indicator + phase label
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 16, height: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(phaseLabel)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.primaryText)
                        if let handle = viewModel.activeScrapeHandle {
                            Text(handle)
                                .font(.system(size: 10))
                                .foregroundStyle(Color.mutedText)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Button("Stop") { onCancelScrape?() }
                        .font(.system(size: 11))
                        .buttonStyle(.bordered)
                        .tint(Color.hateBorder)
                } else {
                    Spacer()
                    Button {
                        onStartScrape?()
                    } label: {
                        Label("Scrape All", systemImage: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.selectedBackground)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.panelBackground)
        }
    }

    private var phaseLabel: String {
        switch viewModel.scrapePhase {
        case .idle:        return "Idle"
        case .preparing:   return "Authenticating…"
        case .feed:        return "Scraping feeds…"
        case .thread:      return "Scraping threads…"
        case .annotating:  return "Annotating…"
        }
    }

    @ViewBuilder
    private func accountRow(for account: TrackedAccount) -> some View {
        let status = viewModel.accountStatuses[account.did]
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor(status))
                .frame(width: 7, height: 7)
            Text(account.handle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.primaryText)
            Spacer(minLength: 4)
            if status == .scraping {
                ProgressView()
                    .scaleEffect(0.45)
                    .frame(width: 12, height: 12)
            }
        }
    }

    private func statusColor(_ status: AccountScrapeStatus?) -> Color {
        switch status {
        case .scraping, .done: return .counterBorder
        case .failed:          return .hateBorder
        case .queued:          return .neutralBorder
        case .none:            return .mutedText
        }
    }

    private func errorBanner(error: BlueskyError) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.yellow)
            Text(error.localizedDescription)   // NOT ?? "Unknown error"
                .font(.caption)
                .foregroundStyle(Color.primaryText)
                .lineLimit(2)
            Spacer()
            Button("×") { viewModel.lastError = nil }
                .foregroundStyle(Color.mutedText)
        }
        .padding(8)
        .background(Color.hateBackground)
    }
}
