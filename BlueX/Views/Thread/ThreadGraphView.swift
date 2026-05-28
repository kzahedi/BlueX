// BlueX/Views/Thread/ThreadGraphView.swift
import SwiftUI
import SwiftData

// Tree visualization of a thread. Each post is a circle colored by its current
// classification (hate / counter / neutral / pending); edges connect parent→child.
// Layout: a simple top-down algorithm — each leaf takes one horizontal slot, each
// parent is centered above its subtree. Both axes scroll for large threads.
struct ThreadGraphView: View {
    let rootPost: Post
    @Query private var allPosts: [Post]
    @State private var selectedURI: String?

    init(rootPost: Post) {
        self.rootPost = rootPost
        let rootURI = rootPost.rootURI
        self._allPosts = Query(
            filter: #Predicate<Post> { $0.rootURI == rootURI },
            sort: \Post.createdAt
        )
    }

    // MARK: - Tree model

    private struct LaidOutNode: Identifiable {
        let post: Post
        var x: CGFloat
        var y: CGFloat
        var children: [LaidOutNode]
        var id: String { post.uri }
    }

    private let nodeRadius: CGFloat = 9
    private let horizontalSpacing: CGFloat = 28
    private let verticalSpacing: CGFloat = 48
    private let edgeInset: CGFloat = 24  // padding around the canvas

    private func buildChildMap() -> [String: [Post]] {
        var map: [String: [Post]] = [:]
        for p in allPosts {
            if let parent = p.parentURI {
                map[parent, default: []].append(p)
            }
        }
        for k in map.keys {
            map[k]?.sort { ($0.createdAt) < ($1.createdAt) }
        }
        return map
    }

    /// Recursive Reingold-Tilford-style layout. Returns the laid-out subtree and its
    /// total horizontal width in pixels.
    private func layout(post: Post, depth: Int, xStart: CGFloat,
                        childMap: [String: [Post]]) -> (LaidOutNode, CGFloat) {
        let y = CGFloat(depth) * verticalSpacing + nodeRadius + edgeInset
        let children = childMap[post.uri] ?? []
        if children.isEmpty {
            let node = LaidOutNode(
                post: post,
                x: xStart + horizontalSpacing / 2,
                y: y,
                children: []
            )
            return (node, horizontalSpacing)
        }
        var cursor = xStart
        var laidChildren: [LaidOutNode] = []
        for child in children {
            let (laid, width) = layout(post: child, depth: depth + 1,
                                       xStart: cursor, childMap: childMap)
            laidChildren.append(laid)
            cursor += width
        }
        let totalWidth = max(cursor - xStart, horizontalSpacing)
        let node = LaidOutNode(
            post: post,
            x: xStart + totalWidth / 2,
            y: y,
            children: laidChildren
        )
        return (node, totalWidth)
    }

    private func flatten(_ node: LaidOutNode, into acc: inout [LaidOutNode]) {
        acc.append(node)
        for c in node.children { flatten(c, into: &acc) }
    }

    private func depthOf(_ node: LaidOutNode) -> Int {
        1 + (node.children.map { depthOf($0) }.max() ?? 0)
    }

    // MARK: - Body

    var body: some View {
        let childMap = buildChildMap()
        let (root, treeWidth) = layout(post: rootPost, depth: 0, xStart: 0, childMap: childMap)
        let depth = depthOf(root)
        let canvasWidth = treeWidth + edgeInset * 2
        let canvasHeight = CGFloat(depth) * verticalSpacing + nodeRadius * 2 + edgeInset * 2

        var nodes: [LaidOutNode] = []
        flatten(root, into: &nodes)

        return VStack(spacing: 0) {
            header(totalPosts: nodes.count)

            Divider().background(Color.neutralBorder)

            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    edgeLayer(root: root, canvasWidth: canvasWidth, canvasHeight: canvasHeight)
                    nodeLayer(nodes: nodes)
                }
                .frame(width: canvasWidth, height: canvasHeight, alignment: .topLeading)
                .padding(edgeInset)
            }
            .background(Color.appBackground)

            if let selected = selectedURI, let post = nodes.first(where: { $0.post.uri == selected })?.post {
                selectedFooter(post: post)
            }
        }
        .background(Color.appBackground)
    }

    // MARK: - Subviews

    private func header(totalPosts: Int) -> some View {
        HStack(spacing: 10) {
            Text("Thread graph")
                .font(.headline)
                .foregroundStyle(Color.primaryText)
            Text("\(totalPosts) nodes")
                .font(.caption)
                .foregroundStyle(Color.secondaryText)
            Spacer()
            HStack(spacing: 10) {
                legendDot(color: .hateBorder, label: "Hate")
                legendDot(color: .counterBorder, label: "Counter")
                legendDot(color: .neutralBorder, label: "Neutral")
                legendDot(color: .pendingBackground, label: "Pending")
            }
        }
        .padding(12)
        .background(Color.panelBackground)
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.system(size: 10)).foregroundStyle(Color.secondaryText)
        }
    }

    private func edgeLayer(root: LaidOutNode, canvasWidth: CGFloat, canvasHeight: CGFloat) -> some View {
        Canvas { context, _ in
            func draw(_ node: LaidOutNode) {
                for child in node.children {
                    var path = Path()
                    path.move(to: CGPoint(x: node.x, y: node.y + nodeRadius))
                    let midY = (node.y + child.y) / 2
                    path.addCurve(
                        to: CGPoint(x: child.x, y: child.y - nodeRadius),
                        control1: CGPoint(x: node.x, y: midY),
                        control2: CGPoint(x: child.x, y: midY)
                    )
                    context.stroke(path,
                                   with: .color(Color.neutralBorder.opacity(0.5)),
                                   lineWidth: 1)
                    draw(child)
                }
            }
            draw(root)
        }
        .frame(width: canvasWidth, height: canvasHeight)
    }

    private func nodeLayer(nodes: [LaidOutNode]) -> some View {
        ForEach(nodes) { node in
            let isSelected = (selectedURI == node.post.uri)
            Circle()
                .fill(color(for: node.post))
                .frame(width: nodeRadius * 2, height: nodeRadius * 2)
                .overlay(
                    Circle().stroke(isSelected ? Color.primaryText : Color.clear, lineWidth: 2)
                )
                .position(x: node.x, y: node.y)
                .onTapGesture {
                    selectedURI = (selectedURI == node.post.uri) ? nil : node.post.uri
                }
                .help("@\(node.post.authorHandle)")
        }
    }

    private func selectedFooter(post: Post) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("@\(post.authorHandle)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.secondaryText)
                Spacer()
                Text(post.createdAt, style: .relative)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.mutedText)
            }
            Text(post.text)
                .font(.system(size: 12))
                .foregroundStyle(Color.primaryText)
                .lineLimit(4)
        }
        .padding(12)
        .background(Color.panelBackground)
    }

    // MARK: - Color

    private func color(for post: Post) -> Color {
        if let cls = post.currentSpeechClass {
            return Color.speechClassBorder(cls)
        }
        return Color.pendingBackground
    }
}
