// BlueX/Views/Queue/QueueView.swift
import SwiftUI
import SwiftData

struct QueueView: View {
    let coordinator: ScrapeCoordinator
    let modelContainer: ModelContainer

    @State private var viewModel = QueueViewModel()
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Annotation Queue")
                        .font(.headline)
                        .foregroundStyle(Color.primaryText)
                    Text("\(viewModel.sentimentPending) pending sentiment · \(viewModel.totalQueued) pending LLM")
                        .font(.caption)
                        .foregroundStyle(Color.secondaryText)
                }
                Spacer()
                controlButtons
            }
            .padding(12)
            .background(Color.panelBackground)

            Divider().background(Color.neutralBorder)

            // Progress
            if viewModel.isRunning {
                progressSection
            }

            // Error
            if let error = viewModel.lastError {
                errorBanner(message: error)
            }

            // Queue list
            if viewModel.pendingPosts.isEmpty {
                emptyState
            } else {
                List(viewModel.pendingPosts, id: \.uri) { post in
                    queueRow(for: post)
                        .listRowBackground(Color.appBackground)
                        .listRowSeparatorTint(Color.neutralBorder)
                }
                .listStyle(.plain)
                .background(Color.appBackground)
            }
        }
        .background(Color.appBackground)
        .onAppear {
            viewModel.loadQueue(from: modelContext)
        }
    }

    // MARK: - Control Buttons

    private var controlButtons: some View {
        HStack(spacing: 8) {
            // Apple sentiment pass — fast, runs independently of any LLM
            Button("Run Sentiment") {
                startSentiment()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.primaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.selectedBackground)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .disabled(viewModel.isRunning || viewModel.sentimentPending == 0)

            // Batch size picker
            Menu("Batch: \(viewModel.batchSize)") {
                ForEach([5, 10, 25, 50, 100], id: \.self) { size in
                    Button("\(size)") { viewModel.batchSize = size }
                }
            }
            .menuStyle(.borderlessButton)
            .font(.system(size: 12))
            .foregroundStyle(Color.secondaryText)

            if coordinator.phase == .annotating {
                Button("Cancel") {
                    coordinator.cancel()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Color.hateBorder)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.hateBackground)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                Button("Start LLM") {
                    startAnnotation()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.primaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.counterBackground)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .disabled(viewModel.pendingPosts.isEmpty)
            }

            Button("Refresh") {
                viewModel.loadQueue(from: modelContext)
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(Color.secondaryText)
        }
    }

    // MARK: - Progress Section

    private var progressSection: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Annotating…")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondaryText)
                Spacer()
                Text("\(viewModel.processedCount) / \(viewModel.totalQueued)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.primaryText)
            }
            ProgressView(value: viewModel.progress)
                .tint(Color.counterBorder)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.panelBackground)
    }

    // MARK: - Queue Row

    private func queueRow(for post: Post) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle()
                .fill(Color.neutralBorder)
                .frame(width: 3)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("@\(post.authorHandle)")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondaryText)
                    Spacer()
                    Text(post.createdAt, style: .relative)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.mutedText)
                }
                Text(post.text)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.primaryText.opacity(0.7))
                    .lineLimit(2)
                if post.needsReAnnotation {
                    Label("Re-annotation required", systemImage: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.hateBorder)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Error Banner

    private func errorBanner(message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.yellow)
            Text(message)
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

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 32))
                .foregroundStyle(Color.counterBorder)
            Text("All posts annotated")
                .font(.body)
                .foregroundStyle(Color.secondaryText)
            Text("Run a scrape to collect new posts")
                .font(.caption)
                .foregroundStyle(Color.mutedText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
    }

    // MARK: - Actions

    private func startSentiment() {
        viewModel.isRunning = true
        viewModel.lastError = nil
        Task {
            do {
                try await coordinator.runNLTaggerAnnotation()
            } catch {
                await MainActor.run { viewModel.lastError = error.localizedDescription }
            }
            await MainActor.run {
                viewModel.isRunning = false
                viewModel.loadQueue(from: modelContext)
            }
        }
    }

    private func startAnnotation() {
        viewModel.isRunning = true
        viewModel.lastError = nil
        Task {
            let client = OllamaClient(
                modelName: "llama3.2",
                endpoint: "http://localhost:11434"
            )
            await coordinator.runLLMAnnotation(using: client, batchSize: viewModel.batchSize)
            await MainActor.run {
                viewModel.isRunning = false
                viewModel.loadQueue(from: modelContext)
            }
        }
    }
}
