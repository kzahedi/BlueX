// BlueX/Views/Thread/PostRowView.swift
import SwiftUI

struct PostRowView: View {
    let post: Post
    let depth: Int
    let onSelect: () -> Void

    private var latestAnnotation: Annotation? {
        post.annotations.last(where: { $0.stage == "llm" })
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer().frame(width: CGFloat(depth) * 16)
            Rectangle()
                .fill(borderColor)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("@\(post.authorHandle)")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondaryText)
                    Spacer()
                    if let annotation = latestAnnotation {
                        AnnotationBadge(annotation: annotation)
                    } else {
                        pendingIndicator
                    }
                    Text(post.createdAt, style: .relative)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.mutedText)
                }
                Text(post.text)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.primaryText)
                    .lineLimit(3)
                    .opacity(latestAnnotation != nil ? 1.0 : 0.6)
                HStack(spacing: 8) {
                    Label("\(post.replyCount)", systemImage: "arrow.uturn.left")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.mutedText)
                    Label("\(post.likeCount)", systemImage: "heart")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.mutedText)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(Color.panelBackground)
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }

    private var borderColor: Color {
        guard let annotation = latestAnnotation else {
            return Color(red: 0.200, green: 0.255, blue: 0.333)
        }
        return Color.speechClassBorder(annotation.speechClass)
    }

    private var pendingIndicator: some View {
        HStack(spacing: 3) {
            Image(systemName: "clock").font(.system(size: 8))
            Text("pending").font(.system(size: 9))
        }
        .foregroundStyle(Color.mutedText)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(Color.neutralBackground)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
