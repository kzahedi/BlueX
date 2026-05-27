// BlueX/Views/Settings/SettingsView.swift
import SwiftUI

struct SettingsView: View {
    enum SettingsTab: String, CaseIterable {
        case credentials = "Credentials"
        case model = "Model"
        case scraping = "Scraping"
    }

    @State private var selectedTab: SettingsTab = .credentials

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.headline)
                    .foregroundStyle(Color.primaryText)
                Spacer()
            }
            .padding(12)
            .background(Color.panelBackground)

            Divider().background(Color.neutralBorder)

            // Tab bar
            HStack(spacing: 0) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Button(tab.rawValue) {
                        selectedTab = tab
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: selectedTab == tab ? .semibold : .regular))
                    .foregroundStyle(selectedTab == tab ? Color.primaryText : Color.secondaryText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        selectedTab == tab
                            ? Color.selectedBackground
                            : Color.clear
                    )
                    .overlay(alignment: .bottom) {
                        if selectedTab == tab {
                            Rectangle()
                                .fill(Color.counterBorder)
                                .frame(height: 2)
                        }
                    }
                }
                Spacer()
            }
            .background(Color.panelBackground)

            Divider().background(Color.neutralBorder)

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch selectedTab {
                    case .credentials:
                        CredentialsSettingsView()
                    case .model:
                        ModelSettingsView()
                    case .scraping:
                        ScrapingSettingsView()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .background(Color.appBackground)
        }
        .background(Color.appBackground)
    }
}
