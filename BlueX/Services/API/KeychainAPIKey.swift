import Foundation
import Security

/// Keychain-backed store for per-provider API keys (Cerebras, Groq, OpenRouter, …).
/// Separate from `KeychainCredentials` (which holds the Bluesky handle+password):
/// API keys live under a different service namespace so we can hold many of them
/// and the user can remove one without disturbing the others.
///
/// Service identifier convention: `net.pulsschlag.BlueX.apikey.<provider>`
///   provider = "cerebras", "groq", "openrouter", "together", …
///
/// The provider string also doubles as the lookup key in `ModelClientFactory`
/// when it needs to attach an Authorization header — see
/// `KeychainAPIKey.provider(forEndpoint:)`.
struct KeychainAPIKey {

    static func service(for provider: String) -> String {
        "net.pulsschlag.BlueX.apikey.\(provider)"
    }

    /// Maps an endpoint URL string to a provider identifier so the factory can
    /// look up the right Keychain entry. Returns nil for endpoints that don't
    /// need an API key (a localhost Ollama URL, for instance).
    static func provider(forEndpoint endpoint: String) -> String? {
        let lower = endpoint.lowercased()
        if lower.contains("cerebras.ai")  { return "cerebras" }
        if lower.contains("groq.com")     { return "groq" }
        if lower.contains("openrouter.ai") { return "openrouter" }
        if lower.contains("together.xyz") { return "together" }
        return nil   // localhost / Ollama / Apple — no key needed
    }

    @discardableResult
    static func save(provider: String, key: String) -> Bool {
        let data = Data(key.utf8)
        let s = service(for: provider)
        // Replace-not-merge: delete first, then add. SecItemAdd fails with
        // duplicate-item if the entry already exists.
        let delQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: s
        ]
        SecItemDelete(delQuery as CFDictionary)

        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: s,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
        ]
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    static func load(provider: String) -> String? {
        let s = service(for: provider)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: s,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8)
        else { return nil }
        return key
    }

    static func delete(provider: String) {
        let s = service(for: provider)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: s
        ]
        SecItemDelete(query as CFDictionary)
    }
}
