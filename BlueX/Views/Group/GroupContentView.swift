// BlueX/Views/Group/GroupContentView.swift
import SwiftUI
import SwiftData

struct GroupContentView: View {
    let group: AccountGroup
    @Binding var selection: SidebarItem?

    @State private var viewModel = GroupViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.name)
                            .font(.headline)
                            .foregroundStyle(Color.primaryText)
                        Text("\(group.accounts.count) accounts")
                            .font(.caption)
                            .foregroundStyle(Color.secondaryText)
                    }
                    Spacer()
                    groupStatsRow
                }
                if let notes = group.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(Color.secondaryText)
                        .lineLimit(2)
                }
            }
            .padding(12)
            .background(Color.panelBackground)

            Divider().background(Color.neutralBorder)

            // Account list
            if group.accounts.isEmpty {
                emptyState
            } else {
                List(group.accounts, id: \.did) { account in
                    accountRow(for: account)
                        .listRowBackground(Color.appBackground)
                        .listRowSeparatorTint(Color.neutralBorder)
                }
                .listStyle(.plain)
                .background(Color.appBackground)
            }
        }
        .background(Color.appBackground)
        .onAppear {
            viewModel.updateStats(for: group.accounts)
        }
        .onChange(of: group.accounts) { _, accounts in
            viewModel.updateStats(for: accounts)
        }
    }

    private var groupStatsRow: some View {
        HStack(spacing: 6) {
            statChip(label: "hate", count: viewModel.totalHate, color: .hateBorder)
            statChip(label: "counter", count: viewModel.totalCounter, color: .counterBorder)
            statChip(label: "neutral", count: viewModel.totalNeutral, color: .neutralBorder)
        }
    }

    private func statChip(label: String, count: Int, color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.primaryText)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Color.appBackground)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func accountRow(for account: TrackedAccount) -> some View {
        let stats = viewModel.accountStats[account.handle]
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(account.displayName.isEmpty ? account.handle : account.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.primaryText)
                Text("@\(account.handle)")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondaryText)
            }
            Spacer()
            if let s = stats {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(s.totalPosts) posts")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondaryText)
                    HStack(spacing: 4) {
                        miniStat(count: s.hateCount, color: .hateBorder)
                        miniStat(count: s.counterCount, color: .counterBorder)
                        miniStat(count: s.neutralCount, color: .neutralBorder)
                    }
                }
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 10))
                .foregroundStyle(Color.mutedText)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            selection = .account(account)
        }
    }

    private func miniStat(count: Int, color: Color) -> some View {
        HStack(spacing: 2) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text("\(count)")
                .font(.system(size: 10))
                .foregroundStyle(Color.mutedText)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.2")
                .font(.system(size: 32))
                .foregroundStyle(Color.mutedText)
            Text("No accounts in this group")
                .font(.body)
                .foregroundStyle(Color.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
    }
}
