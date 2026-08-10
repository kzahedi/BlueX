// BlueX/Views/Thread/ThreadView.swift
import SwiftUI
import SwiftData

struct ThreadView: View {
    let rootPost: Post
    var canGoBack: Bool = false
    var onBack: (() -> Void)? = nil

    @State private var viewModel = ThreadViewModel()
    @Query private var allPosts: [Post]

    init(rootPost: Post, canGoBack: Bool = false, onBack: (() -> Void)? = nil) {
        self.rootPost = rootPost
        self.canGoBack = canGoBack
        self.onBack = onBack
        let rootURI = rootPost.rootURI
        self._allPosts = Query(
            filter: #Predicate<Post> { $0.rootURI == rootURI },
            sort: \Post.createdAt
        )
    }

    var body: some View {
        let ordered = viewModel.orderedPosts(root: rootPost, allPosts: allPosts)

        VStack(spacing: 0) {
            // Thread header
            HStack {
                Button {
                    onBack?()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(canGoBack ? Color.secondaryText : Color.mutedText)
                }
                .buttonStyle(.borderless)
                .disabled(!canGoBack)
                .keyboardShortcut("[", modifiers: .command)
                .help("Back")

                VStack(alignment: .leading, spacing: 3) {
                    Text("Thread")
                        .font(.headline)
                        .foregroundStyle(Color.primaryText)
                    HStack(spacing: 8) {
                        Text("\(ordered.count) posts")
                            .font(.caption)
                            .foregroundStyle(Color.secondaryText)
                        if viewModel.hateCount(in: ordered) > 0 {
                            Label("\(viewModel.hateCount(in: ordered))", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(Color.hateBorder)
                        }
                        if viewModel.counterCount(in: ordered) > 0 {
                            Label("\(viewModel.counterCount(in: ordered))", systemImage: "shield")
                                .font(.caption)
                                .foregroundStyle(Color.counterBorder)
                        }
                        if viewModel.pendingCount(in: ordered) > 0 {
                            Label("\(viewModel.pendingCount(in: ordered)) pending", systemImage: "clock")
                                .font(.caption)
                                .foregroundStyle(Color.mutedText)
                        }
                    }
                }
                Spacer()
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
            }
            .padding(12)
            .background(Color.panelBackground)

            Divider().background(Color.neutralBorder)

            if ordered.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(ordered, id: \.uri) { post in
                            PostRowView(post: post, depth: post.depth) {
                                viewModel.selectedPostURI =
                                    (viewModel.selectedPostURI == post.uri) ? nil : post.uri
                            }
                            .background(
                                viewModel.selectedPostURI == post.uri
                                    ? Color.selectedBackground
                                    : Color.clear
                            )
                            .popover(
                                isPresented: Binding(
                                    get: { viewModel.selectedPostURI == post.uri },
                                    set: { if !$0 { viewModel.selectedPostURI = nil } }
                                ),
                                arrowEdge: .leading
                            ) {
                                PostInspectorView(post: post)
                            }
                        }
                    }
                    .padding(4)
                }
                .background(Color.appBackground)
            }
        }
        .background(Color.appBackground)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 32))
                .foregroundStyle(Color.mutedText)
            Text("No replies yet")
                .font(.body)
                .foregroundStyle(Color.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
    }
}
