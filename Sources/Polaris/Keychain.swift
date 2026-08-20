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

    /// Items are scoped by the Polestar address they belong to, so two
    /// accounts can be signed in at once. The unscoped names are what a
    /// single-account install wrote; `Accounts.migrateSingleAccount()`
    /// moves those across on first launch.
    private static func scoped(_ base: String, _ email: String) -> String {
        email.isEmpty ? base : "\(base):\(email)"
    }

    // MARK: - Password

    static func savePassword(_ password: String, account email: String = Accounts.active) throws {
        try save(password, account: scoped(passwordAccount, email))
    }

    static func readPassword(account email: String = Accounts.active) throws -> String? {
        try read(account: scoped(passwordAccount, email))
    }

    static func deletePassword(account email: String = Accounts.active) {
        delete(account: scoped(passwordAccount, email))
    }

    // MARK: - Session (OAuth refresh token)

    static func saveSessionToken(_ token: String, account email: String = Accounts.active) throws {
        try save(token, account: scoped(sessionAccount, email))
    }

    static func readSessionToken(account email: String = Accounts.active) throws -> String? {
        try read(account: scoped(sessionAccount, email))
    }

    static func deleteSessionToken(account email: String = Accounts.active) {
        delete(account: scoped(sessionAccount, email))
    }

    // MARK: - Pre-multi-account items (read once, then removed)

    static func readLegacyPassword() throws -> String? { try read(account: passwordAccount) }
    static func deleteLegacyPassword() { delete(account: passwordAccount) }
    static func readLegacySessionToken() throws -> String? { try read(account: sessionAccount) }
    static func deleteLegacySessionToken() { delete(account: sessionAccount) }

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
