// BlueX/Views/Queue/QueueView.swift
import SwiftUI
import SwiftData

struct QueueView: View {
    let coordinator: ScrapeCoordinator
    let modelContainer: ModelContainer

    @State private var viewModel = QueueViewModel()
    @State private var selectedModelID: String?       // ModelConfig.modelID; nil → fall back to isDefault
    @AppStorage("llm.pace") private var paceRaw: String = LLMPace.steady.rawValue
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ModelConfig.name) private var modelConfigs: [ModelConfig]

    private var pace: LLMPace {
        LLMPace(rawValue: paceRaw) ?? .steady
    }

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

            // Live progress for whichever pass is running (sentiment or LLM).
            if coordinator.annotationService.isRunning {
                annotationProgressSection
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
            viewModel.loadQueue(from: modelContext, activeModelName: activeModel?.modelID)
        }
        .onChange(of: selectedModelID) { _, _ in
            viewModel.loadQueue(from: modelContext, activeModelName: activeModel?.modelID)
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

            // LLM sentiment pass — uses the same LLM model as the classification pass
            // but with a sentiment-specific prompt (positive/neutral/negative). Sits
            // alongside Apple sentiment for comparison and catches contrastive replies
            // ("subscriber for 40 years but article is shit") that NLTagger mis-scores
            // as positive.
            Button("Run LLM Sentiment") {
                startLLMSentiment()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.primaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.selectedBackground)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .disabled(
                viewModel.isRunning
                || coordinator.annotationService.isRunning
                || activeModel == nil
            )
            .help("Run sentiment classification (positive/neutral/negative) using the selected LLM. Annotations stored separately from Apple NLTagger sentiment for side-by-side comparison.")

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

            // Pace — inter-request pause to keep the SoC from cooking on long runs.
            Menu("Pace: \(pace.label)") {
                ForEach(LLMPace.allCases) { p in
                    Button {
                        paceRaw = p.rawValue
                    } label: {
                        if p == pace {
                            Label(p.label, systemImage: "checkmark")
                        } else {
                            Text(p.label)
                        }
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .font(.system(size: 12))
            .foregroundStyle(Color.secondaryText)
            .disabled(coordinator.annotationService.isRunning)

            if coordinator.annotationService.isRunning {
                Button("Stop") {
                    coordinator.cancelAnnotation()
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
                // viewModel.isRunning catches the sentiment pass (Run Sentiment sets it);
                // without that check, the user could fire an LLM pass concurrently with
                // the in-flight NLTagger pass and collide on the same ModelContext.
                .disabled(
                    viewModel.totalQueued == 0
                    || activeModel == nil
                    || viewModel.isRunning
                )
            }

            Button("Refresh") {
                viewModel.loadQueue(from: modelContext, activeModelName: activeModel?.modelID)
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(Color.secondaryText)
        }
    }

    // MARK: - Progress Section

    private var annotationProgressSection: some View {
        let svc = coordinator.annotationService
        let progress = svc.queueSize > 0
            ? min(1.0, Double(svc.processedCount) / Double(svc.queueSize)) : 0
        return VStack(spacing: 4) {
            HStack {
                Text("\(svc.passLabel.isEmpty ? "Annotating" : svc.passLabel)…")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondaryText)
                Self.thermalBadge(state: svc.thermalState)
                Spacer()
                Text("\(svc.processedCount) / \(svc.queueSize)" +
                     (svc.errorCount > 0 ? " · \(svc.errorCount) errors" : ""))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.primaryText)
            }
            ProgressView(value: progress).tint(Color.counterBorder)
            HStack {
                if !svc.currentPostText.isEmpty {
                    Text(svc.currentPostText)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.mutedText)
                        .lineLimit(1)
                }
                Spacer()
                if let eta = svc.etaSeconds {
                    Text("~\(Self.formatETA(eta)) remaining")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.secondaryText)
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.panelBackground)
    }

    /// Small badge that's hidden while the SoC is nominal/fair and lights up when
    /// the system starts throttling — so a long overnight run gives visible feedback
    /// that the cool-down back-off has kicked in.
    @ViewBuilder
    private static func thermalBadge(state: ProcessInfo.ThermalState) -> some View {
        switch state {
        case .nominal, .fair:
            EmptyView()
        case .serious:
            Label("warm — cooling", systemImage: "thermometer.medium")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.yellow)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.yellow.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        case .critical:
            Label("hot — long cool-down", systemImage: "thermometer.high")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.hateBorder)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.hateBackground.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        @unknown default:
            EmptyView()
        }
    }

    private static func formatETA(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s >= 3600 {
            let h = s / 3600
            let m = (s % 3600) / 60
            return "\(h)h \(m)m"
        }
        if s >= 60 {
            let m = s / 60
            let sec = s % 60
            return "\(m)m \(sec)s"
        }
        return "\(s)s"
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
                viewModel.loadQueue(from: modelContext, activeModelName: activeModel?.modelID)
            }
        }
    }

    /// Kicks off the LLM-sentiment pass: same selected model + endpoint as the
    /// classification pass, but the client is built with the sentiment prompt and
    /// the positive/neutral/negative class set. Annotations land at
    /// stage = "llm-sentiment" so the hate/counter LLM pass and the NLTagger pass
    /// stay untouched for comparison.
    private func startLLMSentiment() {
        guard let cfg = activeModel else {
            viewModel.lastError = "No LLM model configured. Add one in Settings."
            return
        }
        viewModel.isRunning = true
        viewModel.lastError = nil
        Task {
            // Dispatch through the factory with the sentiment prompt + class set
            // injected. The factory routes Apple-foundation / Cerebras / Ollama
            // identically, so the same button works whether the active model is
            // local Gemma or Cerebras Llama 3.3 70B.
            do {
                let client = try ModelClientFactory.make(
                    from: cfg,
                    promptOverride: ModelConfig.defaultSentimentPromptTemplate,
                    validClasses: LLMResponseParser.positiveNeutralNegative
                )
                await coordinator.runLLMSentimentAnnotation(using: client, pace: pace)
            } catch {
                await MainActor.run { viewModel.lastError = error.localizedDescription }
            }
            await MainActor.run {
                viewModel.isRunning = false
                viewModel.loadQueue(from: modelContext, activeModelName: activeModel?.modelID)
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
            // Transport selection lives in ModelClientFactory — Apple Foundation Models
            // is now an option alongside Ollama, and OpenAI-compatible servers (MLX,
            // LM Studio) plug in there without touching this site.
            do {
                let client = try ModelClientFactory.make(from: cfg)
                await coordinator.runLLMAnnotation(using: client, pace: pace)
            } catch {
                await MainActor.run {
                    viewModel.lastError = error.localizedDescription
                }
            }
            await MainActor.run {
                viewModel.isRunning = false
                viewModel.loadQueue(from: modelContext, activeModelName: activeModel?.modelID)
            }
        }
    }
}
