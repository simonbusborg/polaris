//
//  Keychain.swift
//  Polaris (AppKit rewrite)
//
//  Minimal generic-password Keychain wrapper. The Polestar password is
//  stored under a fixed service/account pair, encrypted at rest by macOS.
//

import Foundation
import Security

enum KeychainError: Error, LocalizedError {
    case status(OSStatus)

    var errorDescription: String? {
        switch self {
        case .status(let code):
            let msg = SecCopyErrorMessageString(code, nil) as String? ?? "OSStatus \(code)"
            return "Keychain error: \(msg)"
        }
    }
}

enum Keychain {
    private static let service = "com.weareheavy.polaris"
    private static let account = "polestar-password"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    static func savePassword(_ password: String) throws {
        let data = Data(password.utf8)

        // Try update first, add if the item doesn't exist yet.
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)

        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    /// Returns nil when no password is stored.
    static func readPassword() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError.status(status)
        }
        return String(data: data, encoding: .utf8)
    }

    static func deletePassword() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
