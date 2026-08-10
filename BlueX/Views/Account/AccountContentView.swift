// BlueX/Views/Account/AccountContentView.swift
import SwiftUI
import SwiftData

struct AccountContentView: View {
    let account: TrackedAccount
    @Binding var selection: SidebarItem?
    var onScrapeAccount: ((TrackedAccount) -> Void)? = nil

    @State private var viewModel = AccountViewModel()
    @Environment(\.modelContext) private var modelContext

    @State private var reader: AggregateReader?
    @State private var rootRows: [RootPostSummary] = []
    /// How many trees match the current reply-count + text filters, in total — not just
    /// the capped page in `rootRows`. Surfaced so a filter that hides most of the corpus
    /// is visible, not implied, and so the count reflects what search actually finds
    /// across the whole account rather than only the loaded page.
    @State private var matchingCount: Int = 0
    @State private var loadError: String?
    /// When `rootRows` was last (re)loaded from the store. Shown next to the refresh
    /// button so, during a multi-day scrape, stale data is visibly stale rather than
    /// indistinguishable from current.
    @State private var lastLoadedAt: Date?

    /// Caps the page pulled from SQL per filter change. Large enough that ordinary
    /// browsing never notices it; the point is to stop pulling the *whole* account
    /// (up to 39k roots), not to paginate deliberately — see task-7 brief on why
    /// pagination was evaluated and rejected for reply trees.
    private static let rowLimit = 1000

    init(account: TrackedAccount, selection: Binding<SidebarItem?>,
         onScrapeAccount: ((TrackedAccount) -> Void)? = nil) {
        self.account = account
        self._selection = selection
        self.onScrapeAccount = onScrapeAccount
    }

    /// Identifies everything a reload depends on: which account, which reply-count
    /// range, and the search text. Changing any of these re-runs the SQL query; nothing
    /// else does.
    private var reloadKey: String {
        let bounds = viewModel.replyCountBounds
        return "\(account.did)|\(bounds.min ?? -1)|\(bounds.max ?? -1)|\(viewModel.searchText)"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.displayName)
                            .font(.headline)
                            .foregroundStyle(Color.primaryText)
                            .lineLimit(1)
                        Text("@\(account.handle)")
                            .font(.caption)
                            .foregroundStyle(Color.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if let lastLoadedAt {
                        HStack(spacing: 3) {
                            Text("Updated")
                            Text(lastLoadedAt, style: .relative)
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(Color.mutedText)
                        .help("Data as of \(lastLoadedAt.formatted(date: .abbreviated, time: .standard)) — press refresh for the latest")
                    }
                    Button {
                        Task { await reload() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("Refresh from the store")
                    if let onScrapeAccount {
                        Button {
                            onScrapeAccount(account)
                        } label: {
                            Label("Scrape", systemImage: "arrow.clockwise")
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                                .fixedSize()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.selectedBackground)
                    }
                }
                if let loadError {
                    Text(loadError)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.hateBorder)
                }
                statsRow
                filterBar
            }
            .padding(12)
            .background(Color.panelBackground)

            Divider()
                .background(Color.neutralBorder)

            // Post list
            let filtered = viewModel.filteredRootPosts(rootRows)
            if filtered.isEmpty {
                emptyState
            } else {
                List(filtered, id: \.uri) { row in
                    RootPostSummaryRow(row: row, accountHandle: account.handle) {
                        selectRoot(row)
                    }
                    .listRowBackground(Color.appBackground)
                    .listRowSeparatorTint(Color.neutralBorder)
                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                }
                .listStyle(.plain)
                .background(Color.appBackground)
            }
        }
        .background(Color.appBackground)
        .task(id: reloadKey) { await reload() }
    }

    /// Loads this account's root posts within the current reply-count range and text
    /// search, plus the total match count for the same filters — both via SQL aggregates
    /// (`AggregateReader.rootPosts`/`rootPostCount`). Replaces a `@Query` over every root
    /// post and a `Set`-predicate fetch of every reply belonging to it, which together
    /// materialised up to ~1.08M `Post` objects per account click.
    ///
    /// **Debounce.** The leading sleep is not decorative: `.task(id: reloadKey)` cancels
    /// this call and starts a fresh one on every keystroke in the search field. If the
    /// sleep is cancelled (a new keystroke arrived), `Task.isCancelled` is true and this
    /// returns before touching the store — so typing "hate speech" runs one query, not
    /// eleven.
    ///
    /// **Cancellation vs. staleness.** Every `Task.isCancelled` check below exists to stop
    /// a superseded load (previous account, previous filter) from publishing its result
    /// after a newer one has already started — `.task(id:)` cancellation is cooperative,
    /// so without these checks a slow load for account A can finish after a fast switch
    /// to account B and overwrite B's rows with A's.
    private func reload() async {
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard !Task.isCancelled else { return }
        do {
            let reader = try self.reader ?? AggregateReader()
            guard !Task.isCancelled else { return }
            self.reader = reader
            guard let pk = try reader.accountPK(did: account.did) else {
                guard !Task.isCancelled else { return }
                loadError = "Account not found in the store (did: \(account.did))"
                rootRows = []
                matchingCount = 0
                return
            }
            let bounds = viewModel.replyCountBounds
            let search = viewModel.searchText.isEmpty ? nil : viewModel.searchText
            let rows = try reader.rootPosts(accountPK: pk, minReplies: bounds.min,
                                             maxReplies: bounds.max, textSearch: search,
                                             limit: Self.rowLimit)
            let count = try reader.rootPostCount(accountPK: pk, minReplies: bounds.min,
                                                  maxReplies: bounds.max, textSearch: search)
            guard !Task.isCancelled else { return }
            rootRows = rows
            matchingCount = count
            loadError = nil
            lastLoadedAt = Date()
        } catch {
            guard !Task.isCancelled else { return }
            loadError = error.localizedDescription
        }
    }

    /// Navigation still needs a real `Post` (`SidebarItem.post` is typed to it), so this
    /// fetches exactly the one row the user tapped — never the whole account.
    private func selectRoot(_ row: RootPostSummary) {
        let uri = row.uri
        let descriptor = FetchDescriptor<Post>(predicate: #Predicate<Post> { $0.uri == uri })
        if let post = try? modelContext.fetch(descriptor).first {
            selection = .post(post)
        }
    }

    private var statsRow: some View {
        HStack(spacing: 8) {
            statBadge(label: "trees loaded", count: rootRows.count, color: .neutralBorder)
            if matchingCount != rootRows.count {
                statBadge(label: "match filter", count: matchingCount, color: .counterBorder)
            }
        }
    }

    private func statBadge(label: String, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.primaryText)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Color.secondaryText)
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.appBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mutedText)
                TextField("Filter posts…", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.primaryText)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.appBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            replyCountFilterMenu

            Button {
                viewModel.sortNewestFirst.toggle()
            } label: {
                Image(systemName: viewModel.sortNewestFirst ? "arrow.down" : "arrow.up")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mutedText)
            }
            .buttonStyle(.plain)
        }
    }

    /// Reply-count range filter — "trees with certain sizes are more interesting than
    /// others." Presets mirror the corpus's measured tree-size distribution; filtering
    /// happens in SQL (`reload()`), never in memory.
    private var replyCountFilterMenu: some View {
        Menu {
            ForEach(ReplyCountPreset.allCases.filter { $0 != .custom }) { preset in
                Button {
                    viewModel.replyCountPreset = preset
                } label: {
                    if viewModel.replyCountPreset == preset {
                        Label(preset.label, systemImage: "checkmark")
                    } else {
                        Text(preset.label)
                    }
                }
            }
            Divider()
            Menu("More than…") {
                ForEach([10, 25, 50, 100, 250, 500], id: \.self) { n in
                    Button("More than \(n)") {
                        viewModel.customMinReplies = n
                        viewModel.replyCountPreset = .custom
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 14))
                Text(viewModel.replyCountPreset == .custom
                     ? "More than \(viewModel.customMinReplies)"
                     : viewModel.replyCountPreset.label)
                    .font(.system(size: 11))
            }
            .foregroundStyle(viewModel.replyCountPreset != .any ? Color.counterBorder : Color.mutedText)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundStyle(Color.mutedText)
            Text(viewModel.searchText.isEmpty ? "No posts yet" : "No matching posts")
                .font(.body)
                .foregroundStyle(Color.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
    }
}

// MARK: - RootPostSummaryRow

private struct RootPostSummaryRow: View {
    let row: RootPostSummary
    let accountHandle: String
    let onSelect: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle()
                .fill(statusColor)
                .frame(width: 3)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("@\(accountHandle)")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondaryText)
                    Spacer()
                    statusBadge
                    Text(row.createdAt, style: .relative)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.mutedText)
                }
                Text(row.text)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.primaryText)
                    .lineLimit(2)
                if row.replyCount > 0 {
                    Text("\(row.replyCount) replies")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.mutedText)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }

    /// A small tree can mean a genuinely quiet thread, or a scrape that hasn't finished
    /// yet — `replyTreeStatus` is what tells those apart, so it rides along on every row
    /// rather than only being available as a filter.
    private var status: ReplyTreeStatus {
        ReplyTreeStatus(rawValue: row.replyTreeStatus) ?? .pending
    }

    private var statusColor: Color {
        switch status {
        case .complete:   return Color(red: 0.200, green: 0.255, blue: 0.333)
        case .inProgress: return Color.counterBorder
        case .pending:    return Color.mutedText
        }
    }

    private var statusBadge: some View {
        Group {
            switch status {
            case .complete:
                EmptyView()
            case .inProgress:
                Text("scraping…")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.counterBorder)
            case .pending:
                Text("not scraped")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.mutedText)
            }
        }
    }
}
