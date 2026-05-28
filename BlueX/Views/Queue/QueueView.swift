// BlueX/Views/Queue/QueueView.swift
import SwiftUI
import SwiftData

struct QueueView: View {
    let coordinator: ScrapeCoordinator
    let modelContainer: ModelContainer

    @State private var viewModel = QueueViewModel()
    @State private var selectedModelID: String?       // ModelConfig.modelID; nil → fall back to isDefault
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ModelConfig.name) private var modelConfigs: [ModelConfig]

    private var activeModel: ModelConfig? {
        if let id = selectedModelID, let m = modelConfigs.first(where: { $0.modelID == id }) {
            return m
        }
        return modelConfigs.first(where: { $0.isDefault }) ?? modelConfigs.first
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Annotation Queue")
                        .font(.headline)
                        .foregroundStyle(Color.primaryText)
                    Text("\(viewModel.sentimentPending) pending sentiment · \(viewModel.totalQueued) pending LLM" +
                         (viewModel.totalQueued > QueueViewModel.queueDisplayLimit
                            ? " · showing \(QueueViewModel.queueDisplayLimit) newest"
                            : ""))
                        .font(.caption)
                        .foregroundStyle(Color.secondaryText)
                }
                Spacer()
                controlButtons
            }
            .padding(12)
            .background(Color.panelBackground)

            Divider().background(Color.neutralBorder)

            // Progress — sentiment pass (real, observed from shared service)
            if coordinator.annotationService.isRunning {
                sentimentProgressSection
            }

            // Progress — LLM pass
            if viewModel.isRunning && !coordinator.annotationService.isRunning {
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
            .disabled(viewModel.isRunning || coordinator.annotationService.isRunning || viewModel.sentimentPending == 0)

            // LLM model picker — sourced from ModelConfig in Settings (seeded with the
            // installed Ollama models). Falls back to whichever is marked isDefault.
            Menu(activeModel.map { "Model: \($0.modelID)" } ?? "No model") {
                ForEach(modelConfigs) { cfg in
                    Button {
                        selectedModelID = cfg.modelID
                    } label: {
                        if cfg.modelID == activeModel?.modelID {
                            Label(cfg.name, systemImage: "checkmark")
                        } else {
                            Text(cfg.name)
                        }
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .font(.system(size: 12))
            .foregroundStyle(Color.secondaryText)
            .disabled(viewModel.isRunning || coordinator.annotationService.isRunning)

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

    private var sentimentProgressSection: some View {
        let svc = coordinator.annotationService
        let progress = svc.queueSize > 0 ? Double(svc.processedCount) / Double(svc.queueSize) : 0
        return VStack(spacing: 4) {
            HStack {
                Text("Sentiment (Apple NLTagger)…")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondaryText)
                Spacer()
                Text("\(svc.processedCount) / \(svc.queueSize)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.primaryText)
            }
            ProgressView(value: progress).tint(Color.counterBorder)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.panelBackground)
    }

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
        guard let cfg = activeModel else {
            viewModel.lastError = "No LLM model configured. Add one in Settings."
            return
        }
        viewModel.isRunning = true
        viewModel.lastError = nil
        Task {
            // For now every preset endpoint is Ollama; OpenAI-compatible servers (MLX,
            // LM Studio) can be added later by branching on cfg.endpoint here.
            let client = OllamaClient(
                modelName: cfg.modelID,
                endpoint: cfg.endpoint,
                promptTemplate: cfg.promptTemplate
            )
            await coordinator.runLLMAnnotation(using: client, batchSize: viewModel.batchSize)
            await MainActor.run {
                viewModel.isRunning = false
                viewModel.loadQueue(from: modelContext)
            }
        }
    }
}
