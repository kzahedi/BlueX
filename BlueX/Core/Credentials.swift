//
//  Credentials.swift
//  Bluesent
//
//  Created by Keyan Ghazi-Zahedi on 25.12.24.
//
import SwiftUI
import Foundation

class Credentials {
    static let shared = Credentials()
    private let usernameKey = "username"
    private let keychainService = "kgz.bluex.preferences"

    private init() {}

    // MARK: - Read Username
    func getUsername() -> String? {
        return UserDefaults.standard.string(forKey: usernameKey)
    }

    // MARK: - Read Password
    func getPassword() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
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
