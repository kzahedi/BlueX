// BlueX/Views/Thread/PostInspectorView.swift
import SwiftUI

/// Click-popover that reveals everything stored about a post: the full text, Apple's
/// sentiment, each LLM annotation lineage with its prompt hash, raw model output,
/// engagement counters and the AT URI. Used by both the thread message list and the
/// thread graph view so they share one consistent inspector.
struct PostInspectorView: View {
    let post: Post

    private var llmAnnotations: [Annotation] {
        post.annotations
            .filter { $0.stage == "llm" }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                Divider().background(Color.neutralBorder)
                fullText
                if let nlt = post.nlTaggerAnnotation {
                    Divider().background(Color.neutralBorder)
                    sentimentSection(nlt)
                }
                if !llmAnnotations.isEmpty {
                    Divider().background(Color.neutralBorder)
                    Text("LLM annotations · \(llmAnnotations.count)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.secondaryText)
                    ForEach(llmAnnotations) { ann in
                        llmAnnotationCard(ann)
                    }
                }
                Divider().background(Color.neutralBorder)
                engagementRow
                uriFooter
            }
            .padding(14)
        }
        .frame(width: 440)
        .frame(minHeight: 220, maxHeight: 620)
        .background(Color.panelBackground)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("@\(post.authorHandle)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.primaryText)
                    .textSelection(.enabled)
                Spacer()
                Text(post.isRootPost ? "root" : "reply · depth \(post.depth)")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.mutedText)
            }
            HStack(spacing: 8) {
                Text(post.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 10))
                    .foregroundStyle(Color.mutedText)
            }
        }
    }

    private var fullText: some View {
        Text(post.text)
            .font(.system(size: 12))
            .foregroundStyle(Color.primaryText)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Sentiment

    private func sentimentSection(_ ann: Annotation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Apple sentiment")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.secondaryText)
            HStack(spacing: 10) {
                SentimentIndicator(score: ann.sentimentScore)
                Spacer()
                Text("lang: \(ann.detectedLanguage)")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.mutedText)
            }
        }
    }

    // MARK: - LLM annotation card

    private func llmAnnotationCard(_ ann: Annotation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(ann.modelName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.primaryText)
                    .textSelection(.enabled)
                Text("· \(String(ann.promptHash.prefix(8)))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color.mutedText)
                Spacer()
                Text(ann.createdAt, style: .relative)
                    .font(.system(size: 9))
                    .foregroundStyle(Color.mutedText)
            }
            HStack(spacing: 8) {
                classBadge(ann.speechClass)
                if let sev = ann.severity, !sev.isEmpty {
                    Text("severity: \(sev)")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.mutedText)
                }
                Text(String(format: "conf %.2f", ann.confidence))
                    .font(.system(size: 10))
                    .foregroundStyle(Color.mutedText)
                    .monospacedDigit()
            }
            if let reasoning = ann.reasoning, !reasoning.isEmpty {
                Text(reasoning)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 4) {
                    Text("prompt hash")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.mutedText)
                    Text(ann.promptHash)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.secondaryText)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("raw response")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.mutedText)
                        .padding(.top, 4)
                    Text(ann.rawResponse)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.secondaryText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            } label: {
                Text("Raw response · prompt hash")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.mutedText)
            }
        }
        .padding(10)
        .background(Color.appBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func classBadge(_ cls: String) -> some View {
        Text(cls)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.speechClassBackground(cls))
            .foregroundStyle(Color.speechClassBadgeText(cls))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - Engagement + URI

    private var engagementRow: some View {
        HStack(spacing: 16) {
            Label("\(post.likeCount)", systemImage: "heart")
            Label("\(post.replyCount)", systemImage: "arrow.uturn.left")
            Label("\(post.repostCount)", systemImage: "arrow.2.squarepath")
            Label("\(post.quoteCount)", systemImage: "quote.bubble")
            Spacer()
        }
        .font(.system(size: 10))
        .foregroundStyle(Color.mutedText)
    }

    private var uriFooter: some View {
        Text(post.uri)
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(Color.mutedText)
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}
