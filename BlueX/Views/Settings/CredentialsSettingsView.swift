// BlueX/Views/Settings/CredentialsSettingsView.swift
import SwiftUI

struct CredentialsSettingsView: View {
    @State private var handle: String = ""
    @State private var password: String = ""
    @State private var saveStatus: SaveStatus = .idle
    @State private var connectionResult: String? = nil
    @State private var isTesting: Bool = false

    enum SaveStatus {
        case idle, saved, error
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Section header
            VStack(alignment: .leading, spacing: 4) {
                Text("Bluesky Credentials")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.primaryText)
                Text("Used to authenticate scraping requests. Store as an app password (not your main password).")
                    .font(.caption)
                    .foregroundStyle(Color.secondaryText)
            }

            // Handle field
            VStack(alignment: .leading, spacing: 4) {
                Text("Handle")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondaryText)
                TextField("user.bsky.social", text: $handle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primaryText)
                    .padding(8)
                    .background(Color.panelBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.neutralBorder, lineWidth: 1)
                    )
            }

            // Password field
            VStack(alignment: .leading, spacing: 4) {
                Text("App Password")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondaryText)
                SecureField("xxxx-xxxx-xxxx-xxxx", text: $password)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primaryText)
                    .padding(8)
                    .background(Color.panelBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.neutralBorder, lineWidth: 1)
                    )
            }

            // Action buttons
            HStack(spacing: 10) {
                Button("Save Credentials") {
                    let saved = KeychainCredentials.save(handle: handle, password: password)
                    saveStatus = saved ? .saved : .error
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.primaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(canSave ? Color.selectedBackground : Color.panelBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .disabled(!canSave)

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
                .disabled(isTesting || !canSave)

                Button("Clear") {
                    KeychainCredentials.delete()
                    handle = ""
                    password = ""
                    saveStatus = .idle
                    connectionResult = nil
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Color.mutedText)
            }

            // Status messages
            if saveStatus == .saved {
                Label("Saved to Keychain", systemImage: "checkmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.counterBorder)
            } else if saveStatus == .error {
                Label("Failed to save credentials", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.hateBorder)
            }

            if let result = connectionResult {
                Text(result)
                    .font(.system(size: 11))
                    .foregroundStyle(result.hasPrefix("✓") ? Color.counterBorder : Color.hateBorder)
                    .padding(8)
                    .background(result.hasPrefix("✓") ? Color.counterBackground : Color.hateBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if isTesting {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("Testing connection…")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondaryText)
                }
            }
        }
        .onAppear {
            if let stored = KeychainCredentials.load() {
                handle = stored.handle
                password = stored.password
            }
        }
    }

    private var canSave: Bool {
        !handle.isEmpty && !password.isEmpty
    }

    private func testConnection() {
        isTesting = true
        connectionResult = nil
        Task {
            let api = BlueskyAPIClient()
            let result = await api.createSession(handle: handle, password: password)
            await MainActor.run {
                isTesting = false
                switch result {
                case .success:
                    connectionResult = "✓ Connected successfully"
                case .failure(let error):
                    connectionResult = "✗ \(error.localizedDescription)"
                }
            }
        }
    }
}
