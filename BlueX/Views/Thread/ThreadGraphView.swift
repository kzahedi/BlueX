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
    @State private var colorSource: ColorSource = .sentiment

    /// What drives the node colors: Apple's NLTagger sentiment score (continuous
    /// red→gray→green), or a specific LLM lineage identified by (modelName, promptHash).
    enum ColorSource: Hashable, Identifiable {
        case sentiment
        case llm(modelName: String, promptHash: String)

        var id: String {
            switch self {
            case .sentiment: return "sentiment"
            case .llm(let m, let h): return "llm::\(m)::\(h)"
            }
        }

        var displayName: String {
            switch self {
            case .sentiment: return "Apple sentiment"
            case .llm(let m, let h): return "\(m) · \(String(h.prefix(6)))"
            }
        }
    }

    private struct LLMKey: Hashable { let modelName: String; let promptHash: String }

    /// Every distinct (model, prompt) LLM lineage that appears anywhere in the thread.
    private var availableLLMs: [LLMKey] {
        let keys = allPosts
            .flatMap { $0.annotations }
            .filter { $0.stage == "llm" }
            .map { LLMKey(modelName: $0.modelName, promptHash: $0.promptHash) }
        return Array(Set(keys)).sorted { $0.modelName == $1.modelName ? $0.promptHash < $1.promptHash : $0.modelName < $1.modelName }
    }

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
            colorSourcePicker
            legend
        }
        .padding(12)
        .background(Color.panelBackground)
    }

    private var colorSourcePicker: some View {
        Menu(colorSource.displayName) {
            Button("Apple sentiment") { colorSource = .sentiment }
            if !availableLLMs.isEmpty {
                Divider()
                ForEach(availableLLMs, id: \.self) { key in
                    Button("\(key.modelName) · \(String(key.promptHash.prefix(6)))") {
                        colorSource = .llm(modelName: key.modelName, promptHash: key.promptHash)
                    }
                }
            }
        }
        .menuStyle(.borderlessButton)
        .font(.system(size: 11))
        .foregroundStyle(Color.secondaryText)
        .fixedSize()
    }

    @ViewBuilder
    private var legend: some View {
        switch colorSource {
        case .sentiment:
            HStack(spacing: 10) {
                legendDot(color: sentimentColor(-1.0), label: "−1")
                legendDot(color: sentimentColor( 0.0), label: "0")
                legendDot(color: sentimentColor( 1.0), label: "+1")
                legendDot(color: Color.pendingBackground, label: "no score")
            }
        case .llm:
            HStack(spacing: 10) {
                legendDot(color: .hateBorder, label: "Hate")
                legendDot(color: .counterBorder, label: "Counter")
                legendDot(color: .neutralBorder, label: "Neutral")
                legendDot(color: Color.pendingBackground, label: "no annotation")
            }
        }
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
                .help(tooltipText(for: node.post))
                .popover(
                    isPresented: Binding(
                        get: { selectedURI == node.post.uri },
                        set: { if !$0 { selectedURI = nil } }
                    ),
                    arrowEdge: .trailing
                ) {
                    PostInspectorView(post: node.post)
                }
        }
    }

    /// Compact one-line summary shown as the macOS hover tooltip.
    private func tooltipText(for post: Post) -> String {
        var parts: [String] = ["@\(post.authorHandle)"]
        if let score = post.nlTaggerAnnotation?.sentimentScore {
            parts.append(String(format: "sentiment %+.2f", score))
        }
        if case .llm(let modelName, let promptHash) = colorSource,
           let ann = post.annotations.first(where: {
               $0.stage == "llm" && $0.modelName == modelName && $0.promptHash == promptHash
           }) {
            parts.append("\(ann.speechClass) (conf \(String(format: "%.2f", ann.confidence)))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Color

    /// Node color resolution. Sentiment mode produces a smooth red→gray→green gradient
    /// from the NLTagger score; LLM mode uses the classification color from the chosen
    /// (model, prompt) lineage. Falls back to the muted pending color when the post has
    /// no annotation for the current source.
    private func color(for post: Post) -> Color {
        switch colorSource {
        case .sentiment:
            guard let score = post.nlTaggerAnnotation?.sentimentScore else {
                return Color.pendingBackground
            }
            return sentimentColor(score)
        case .llm(let modelName, let promptHash):
            guard let ann = post.annotations.first(where: {
                $0.stage == "llm"
                && $0.modelName == modelName
                && $0.promptHash == promptHash
            }) else { return Color.pendingBackground }
            return Color.speechClassBorder(ann.speechClass)
        }
    }

    private func sentimentColor(_ score: Double) -> Color {
        let s = max(-1.0, min(1.0, score))
        // Palette anchors (matching the rest of the app):
        //   mutedText    = (0.278, 0.341, 0.412)  ← s = 0
        //   hateBorder   = (0.937, 0.267, 0.267)  ← s = −1
        //   counterBorder= (0.133, 0.773, 0.369)  ← s = +1
        if s < 0 {
            let t = abs(s)
            return Color(
                red:   0.278 + (0.937 - 0.278) * t,
                green: 0.341 + (0.267 - 0.341) * t,
                blue:  0.412 + (0.267 - 0.412) * t
            )
        } else {
            let t = s
            return Color(
                red:   0.278 + (0.133 - 0.278) * t,
                green: 0.341 + (0.773 - 0.341) * t,
                blue:  0.412 + (0.369 - 0.412) * t
            )
        }
    }
}
