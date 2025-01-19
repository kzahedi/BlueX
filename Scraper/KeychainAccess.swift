//
//  KeychainAccess.swift
//  BlueX
//
//  Created by Keyan Ghazi-Zahedi on 19.01.25.
//

import Foundation

func retrieveCredentials(forService service: String) -> (username: String, password: String)? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecReturnAttributes as String: true, // Retrieve attributes like the account (username)
        kSecReturnData as String: true,      // Retrieve the actual password data
        kSecMatchLimit as String: kSecMatchLimitOne
    ]
    
    var itemRef: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &itemRef)
    
    if status == errSecSuccess,
        let item = itemRef as? [String: Any],
        let account = item[kSecAttrAccount as String] as? String,
        let passwordData = item[kSecValueData as String] as? Data,
        let password = String(data: passwordData, encoding: .utf8) {
        return (username: account, password: password)
    } else {
        print("Error retrieving credentials for service '\(service)': \(status)")
        return nil
    }
}
