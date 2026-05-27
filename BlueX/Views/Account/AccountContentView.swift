// BlueX/Views/Account/AccountContentView.swift
import SwiftUI
import SwiftData

struct AccountContentView: View {
    let account: TrackedAccount
    @Binding var selection: SidebarItem?

    @State private var viewModel = AccountViewModel()
    @Query private var allPosts: [Post]

    init(account: TrackedAccount, selection: Binding<SidebarItem?>) {
        self.account = account
        self._selection = selection
        let did = account.did
        self._allPosts = Query(
            filter: #Predicate<Post> { $0.account?.did == did },
            sort: \Post.createdAt,
            order: .reverse
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.displayName)
                            .font(.headline)
                            .foregroundStyle(Color.primaryText)
                        Text("@\(account.handle)")
                            .font(.caption)
                            .foregroundStyle(Color.secondaryText)
                    }
                    Spacer()
                    statsRow
                }
                filterBar
            }
            .padding(12)
            .background(Color.panelBackground)

            Divider()
                .background(Color.neutralBorder)

            // Post list
            let filtered = viewModel.filteredPosts(allPosts)
            if filtered.isEmpty {
                emptyState
            } else {
                List(filtered, id: \.uri) { post in
                    PostSummaryRow(post: post) {
                        selection = .post(post)
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
        .onChange(of: allPosts) { _, newPosts in
            viewModel.updateCounts(from: newPosts)
        }
        .onAppear {
            viewModel.updateCounts(from: allPosts)
        }
    }

    private var statsRow: some View {
        HStack(spacing: 8) {
            statBadge(label: "hate", count: viewModel.hateCount, color: .hateBorder)
            statBadge(label: "counter", count: viewModel.counterCount, color: .counterBorder)
            statBadge(label: "neutral", count: viewModel.neutralCount, color: .neutralBorder)
            if viewModel.pendingCount > 0 {
                statBadge(label: "pending", count: viewModel.pendingCount, color: .mutedText)
            }
        }
    }

    private func statBadge(label: String, count: Int, color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.primaryText)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Color.secondaryText)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
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

            Menu {
                Button("All") { viewModel.filterClass = nil }
                Divider()
                Button("Hate only") { viewModel.filterClass = "hate" }
                Button("Counter only") { viewModel.filterClass = "counter" }
                Button("Neutral only") { viewModel.filterClass = "neutral" }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(viewModel.filterClass != nil ? Color.counterBorder : Color.mutedText)
            }
            .menuStyle(.borderlessButton)

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

// MARK: - PostSummaryRow

private struct PostSummaryRow: View {
    let post: Post
    let onSelect: () -> Void

    private var latestAnnotation: Annotation? {
        post.annotations.last(where: { $0.stage == "llm" })
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle()
                .fill(borderColor)
                .frame(width: 3)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("@\(post.authorHandle)")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondaryText)
                    Spacer()
                    if let annotation = latestAnnotation {
                        AnnotationBadge(annotation: annotation)
                    }
                    Text(post.createdAt, style: .relative)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.mutedText)
                }
                Text(post.text)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.primaryText)
                    .lineLimit(2)
                if post.replyCount > 0 {
                    Text("\(post.replyCount) replies")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.mutedText)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }

    private var borderColor: Color {
        guard let annotation = latestAnnotation else {
            return Color(red: 0.200, green: 0.255, blue: 0.333)
        }
        return Color.speechClassBorder(annotation.speechClass)
    }
}
