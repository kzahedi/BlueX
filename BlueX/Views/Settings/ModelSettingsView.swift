// BlueX/Views/Settings/ModelSettingsView.swift
import SwiftUI
import SwiftData

struct ModelSettingsView: View {
    @Query private var configs: [ModelConfig]
    @Environment(\.modelContext) private var modelContext

    @State private var selectedConfigID: PersistentIdentifier? = nil
    @State private var editName: String = ""
    @State private var editEndpoint: String = ""
    @State private var editModelID: String = ""
    @State private var editPromptTemplate: String = ""
    @State private var isTesting: Bool = false
    @State private var testResult: String? = nil
    @State private var saveStatus: String? = nil

    private var selectedConfig: ModelConfig? {
        configs.first { $0.id == selectedConfigID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Config list header
            HStack {
                Text("Model Configurations")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.primaryText)
                Spacer()
                Button {
                    addNewConfig()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.secondaryText)
            }
            .padding(.bottom, 12)

            // Config picker
            if configs.isEmpty {
                Text("No configurations yet. Add one with the + button.")
                    .font(.caption)
                    .foregroundStyle(Color.mutedText)
                    .padding(.bottom, 16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(configs) { config in
                            configChip(config)
                        }
                    }
                }
                .padding(.bottom, 12)
            }

            Divider().background(Color.neutralBorder)
                .padding(.bottom, 12)

            if let config = selectedConfig {
                configEditor(config: config)
            } else if !configs.isEmpty {
                Text("Select a configuration to edit")
                    .font(.caption)
                    .foregroundStyle(Color.mutedText)
            }
        }
    }

    // MARK: - Config Chip

    private func configChip(_ config: ModelConfig) -> some View {
        HStack(spacing: 4) {
            if config.isDefault {
                Circle()
                    .fill(Color.counterBorder)
                    .frame(width: 5, height: 5)
            }
            Text(config.name)
                .font(.system(size: 11))
                .foregroundStyle(selectedConfigID == config.id ? Color.primaryText : Color.secondaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(selectedConfigID == config.id ? Color.selectedBackground : Color.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture {
            selectConfig(config)
        }
    }

    // MARK: - Config Editor

    private func configEditor(config: ModelConfig) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Name
            settingsField(label: "Name", placeholder: "My Ollama Config") {
                TextField("", text: $editName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primaryText)
            }

            // Endpoint
            settingsField(label: "Endpoint", placeholder: "http://localhost:11434") {
                TextField("", text: $editEndpoint)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primaryText)
            }

            // Model ID
            settingsField(label: "Model ID", placeholder: "llama3.2") {
                TextField("", text: $editModelID)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primaryText)
            }

            // Prompt template
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Prompt Template")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondaryText)
                    Spacer()
                    Button("Reset to default") {
                        editPromptTemplate = ModelConfig.defaultPromptTemplate
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(Color.mutedText)
                    .buttonStyle(.plain)
                }
                TextEditor(text: $editPromptTemplate)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.primaryText)
                    .frame(minHeight: 160)
                    .padding(6)
                    .background(Color.panelBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.neutralBorder, lineWidth: 1)
                    )
                Text("Use {{text}} and {{language}} placeholders")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.mutedText)
            }

            // Buttons
            HStack(spacing: 10) {
                Button("Save") {
                    saveConfig(config)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.primaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.selectedBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                Button("Test Connection") {
                    testConnection()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Color.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.panelBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .disabled(isTesting)

                Button("Set as Default") {
                    setDefault(config)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(config.isDefault ? Color.counterBorder : Color.mutedText)

                Spacer()

                Button("Delete") {
                    deleteConfig(config)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Color.hateBorder)
            }

            if let status = saveStatus {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(status.hasPrefix("✓") ? Color.counterBorder : Color.hateBorder)
            }

            if isTesting {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6)
                    Text("Testing…")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondaryText)
                }
            }

            if let result = testResult {
                Text(result)
                    .font(.system(size: 11))
                    .foregroundStyle(result.hasPrefix("✓") ? Color.counterBorder : Color.hateBorder)
                    .padding(8)
                    .background(result.hasPrefix("✓") ? Color.counterBackground : Color.hateBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    @ViewBuilder
    private func settingsField<Content: View>(
        label: String,
        placeholder: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Color.secondaryText)
            content()
                .padding(8)
                .background(Color.panelBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.neutralBorder, lineWidth: 1)
                )
        }
    }

    // MARK: - Actions

    private func selectConfig(_ config: ModelConfig) {
        selectedConfigID = config.id
        editName = config.name
        editEndpoint = config.endpoint
        editModelID = config.modelID
        editPromptTemplate = config.promptTemplate
        testResult = nil
        saveStatus = nil
    }

    private func saveConfig(_ config: ModelConfig) {
        config.name = editName
        config.endpoint = editEndpoint
        config.modelID = editModelID
        config.promptTemplate = editPromptTemplate
        do {
            try modelContext.save()
            saveStatus = "✓ Saved"
        } catch {
            saveStatus = "✗ \(error.localizedDescription)"
        }
    }

    private func addNewConfig() {
        let config = ModelConfig(
            name: "New Config",
            endpoint: "http://localhost:11434",
            modelID: "llama3.2",
            promptTemplate: ModelConfig.defaultPromptTemplate
        )
        modelContext.insert(config)
        try? modelContext.save()
        selectConfig(config)
    }

    private func deleteConfig(_ config: ModelConfig) {
        modelContext.delete(config)
        try? modelContext.save()
        selectedConfigID = nil
    }

    private func setDefault(_ config: ModelConfig) {
        for c in configs { c.isDefault = false }
        config.isDefault = true
        try? modelContext.save()
    }

    private func testConnection() {
        isTesting = true
        testResult = nil
        Task {
            let client = OllamaClient(
                modelName: editModelID,
                endpoint: editEndpoint
            )
            do {
                _ = try await client.classify(text: "Test post", language: "en")
                await MainActor.run {
                    isTesting = false
                    testResult = "✓ Connection successful — model responds"
                }
            } catch {
                await MainActor.run {
                    isTesting = false
                    testResult = "✗ \(error.localizedDescription)"
                }
            }
        }
    }
}
