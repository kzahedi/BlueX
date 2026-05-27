// BlueX/Views/Sidebar/SidebarView.swift
import SwiftUI
import SwiftData

struct SidebarView: View {
    var viewModel: SidebarViewModel
    @Binding var selection: SidebarItem?

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
        }
        .frame(minWidth: 220)
        .background(Color.appBackground)
    }

    @ViewBuilder
    private func accountRow(for account: TrackedAccount) -> some View {
        let isScraping = viewModel.scrapePhase != .idle
            && viewModel.activeScrapeHandle == account.handle
        HStack(spacing: 6) {
            Circle()
                .fill(isScraping ? Color.counterBorder : Color.mutedText)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.handle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.primaryText)
                if isScraping {
                    ProgressView(value: viewModel.scrapeProgress)
                        .tint(Color.counterBorder)
                        .scaleEffect(y: 0.5)
                }
            }
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
