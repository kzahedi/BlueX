import Foundation
import Security

// Why: Keychain is the secure store for credentials on macOS.
// UserDefaults and files are NOT secure — never store passwords there.
// The Security framework APIs are C-style, so we wrap them in a Swift struct.
struct KeychainCredentials {
    let handle: String
    let password: String

    static let service = "net.pulsschlag.BlueX"

    /// Saves credentials to Keychain. Returns true on success.
    @discardableResult
    static func save(handle: String, password: String) -> Bool {
        // Why: We encode both fields as JSON in a single keychain item —
        // simpler than two separate items, and atomic (both saved or neither).
        guard let data = try? JSONEncoder().encode(["handle": handle, "password": password]) else {
            return false
        }

        // Delete any existing item first (SecItemAdd fails if key already exists)
        let deleteQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
        ]
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    /// Loads credentials from Keychain. Returns nil if not found.
    static func load() -> KeychainCredentials? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let dict = try? JSONDecoder().decode([String: String].self, from: data),
              let handle = dict["handle"],
              let password = dict["password"]
        else { return nil }

        return KeychainCredentials(handle: handle, password: password)
    }

    /// Removes credentials from Keychain.
    static func delete() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service
        ]
        SecItemDelete(query as CFDictionary)
    }
}
