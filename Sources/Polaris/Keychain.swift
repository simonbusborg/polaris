//
//  Keychain.swift
//  Polaris (AppKit rewrite)
//
//  Minimal generic-password Keychain wrapper. Two items live under a fixed
//  service: the Polestar password, and the OAuth refresh token that lets the
//  app resume its session without replaying the scripted form login.
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
    private static let passwordAccount = "polestar-password"
    private static let sessionAccount = "polestar-refresh-token"

    // MARK: - Password

    static func savePassword(_ password: String) throws { try save(password, account: passwordAccount) }
    static func readPassword() throws -> String? { try read(account: passwordAccount) }
    static func deletePassword() { delete(account: passwordAccount) }

    // MARK: - Session (OAuth refresh token)

    static func saveSessionToken(_ token: String) throws { try save(token, account: sessionAccount) }
    static func readSessionToken() throws -> String? { try read(account: sessionAccount) }
    static func deleteSessionToken() { delete(account: sessionAccount) }

    // MARK: - Plumbing

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static func save(_ value: String, account: String) throws {
        // Delete-then-add rather than update: ad-hoc builds get a new code
        // signature every rebuild, and an item created by an older build may
        // refuse access to the new one. Recreating the item resets its access
        // control to the currently-running app.
        SecItemDelete(baseQuery(account: account) as CFDictionary)

        var add = baseQuery(account: account)
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    /// Returns nil when no item is stored.
    private static func read(account: String) throws -> String? {
        var query = baseQuery(account: account)
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

    private static func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }
}
