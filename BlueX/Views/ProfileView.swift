//
//  ProfileView.swift
//  Bluesent
//
//  Created by Keyan Ghazi-Zahedi on 25.12.24.
//
import Foundation
import SwiftUI
import Security


struct ProfileSettingsView: View {
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var isPasswordVisible: Bool = false

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Username", text: $username)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .onChange(of: username) { 
                            UserDefaults.standard.set(username, forKey: "username")
                        }
                }

                HStack {
                    if isPasswordVisible {
                        TextField("Password", text: $password)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .onAppear(){
                                loadPassword()
                            }
                    } else {
                        SecureField("Password", text: $password)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .onAppear(){
                                loadPassword()
                            }
                    }
                    Button(action: {
                        isPasswordVisible.toggle()
                    }) {
                        Image(systemName: isPasswordVisible ? "eye" : "eye.slash")
                            .foregroundColor(.gray)
                    }
                }
            }
        }
        .padding()
        .onAppear {
            loadStoredCredentials()
        }
        .onDisappear {
            saveCredentials()
        }
    }

    private func loadStoredCredentials() {
        loadPassword()
        loadUsername()
    }
    
    private func loadUsername(){
        username = UserDefaults.standard.string(forKey: "username") ?? ""
    }
    private func loadPassword(){
        password = KeychainHelper.shared.getPassword() ?? ""
    }

    private func saveCredentials() {
        UserDefaults.standard.set(username, forKey: "username")
        KeychainHelper.shared.savePassword(password)
    }
}

// MARK: - Keychain Helper
class KeychainHelper {
    static let shared = KeychainHelper()
    private let service = "com.example.preferences"

    func savePassword(_ password: String) {
        guard let passwordData = password.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecValueData as String: passwordData
        ]

        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    func getPassword() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)

        guard status == errSecSuccess, let data = dataTypeRef as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

#Preview {
    ProfileSettingsView()
}
