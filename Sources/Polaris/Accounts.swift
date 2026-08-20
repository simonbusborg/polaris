//
//  Accounts.swift
//  Polaris (AppKit rewrite)
//
//  Polaris used to know one Polestar account. A household can easily have
//  two — one car per person — and the API gives no way to see across them,
//  so the app has to hold several logins at once.
//
//  The user never meets the word "account": they add a car, sign in, and
//  then pick between all their cars in one menu. Everything here is the
//  bookkeeping that makes that single list possible.
//
//  Cars are cached per account because the menu has to list cars belonging
//  to accounts that aren't currently signed in — otherwise switching to the
//  other car would mean knowing it exists before you can select it.
//

import Foundation

enum Accounts {
    private static let d = UserDefaults.standard
    private static let listKey = "polestar_accounts"

    /// Every account the user has signed into, oldest first. The active one
    /// is `Preferences.email`.
    static var all: [String] {
        get { d.stringArray(forKey: listKey) ?? [] }
        set { d.set(newValue, forKey: listKey) }
    }

    static var active: String { Preferences.email }

    static func add(_ email: String) {
        guard !email.isEmpty, !all.contains(email) else { return }
        all.append(email)
    }

    /// Forgets an account, its cached cars and its Keychain items. Signing
    /// out of the last account leaves the app in its unconfigured state.
    static func remove(_ email: String) {
        all.removeAll { $0 == email }
        d.removeObject(forKey: carsKey(email))
        Keychain.deletePassword(account: email)
        Keychain.deleteSessionToken(account: email)
        if Preferences.email == email {
            Preferences.email = all.first ?? ""
            Preferences.vin = cars(for: Preferences.email).first?.vin ?? ""
        }
    }

    // MARK: - Cached cars

    private static func carsKey(_ email: String) -> String { "polestar_cars_\(email)" }

    static func cars(for email: String) -> [CarSummary] {
        guard let raw = d.array(forKey: carsKey(email)) as? [[String]] else { return [] }
        return raw.compactMap { $0.count == 2 ? CarSummary(vin: $0[0], title: $0[1]) : nil }
    }

    static func setCars(_ cars: [CarSummary], for email: String) {
        guard !email.isEmpty else { return }
        d.set(cars.map { [$0.vin, $0.title] }, forKey: carsKey(email))
    }

    /// Every known car across every account, in the order the accounts were
    /// added. This is what the menu's switcher shows.
    static var allCars: [CarSummary] {
        all.flatMap { cars(for: $0) }
    }

    /// Which account owns a VIN, or nil if no account has ever reported it.
    static func owner(ofVin vin: String) -> String? {
        all.first { cars(for: $0).contains { $0.vin == vin } }
    }

    /// Moves a pre-multi-account install onto the new layout: the single
    /// stored login becomes account number one, and its unscoped Keychain
    /// items are re-saved under its address. Runs once — afterwards the
    /// account list is non-empty and this is a no-op.
    static func migrateSingleAccount() {
        guard all.isEmpty, !Preferences.email.isEmpty else { return }
        all = [Preferences.email]
        if let password = (try? Keychain.readLegacyPassword()) ?? nil {
            try? Keychain.savePassword(password, account: Preferences.email)
            Keychain.deleteLegacyPassword()
        }
        if let token = (try? Keychain.readLegacySessionToken()) ?? nil {
            try? Keychain.saveSessionToken(token, account: Preferences.email)
            Keychain.deleteLegacySessionToken()
        }
    }
}
