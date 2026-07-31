//
//  Preferences.swift
//  Polaris (AppKit rewrite)
//
//  Non-secret settings live in UserDefaults. The password lives in the
//  Keychain (see Keychain.swift) — never in UserDefaults.
//

import Foundation

enum DisplayOption: String, CaseIterable {
    case batteryPercentage = "Battery Percentage"
    case rangeKm = "Range (km)"
    case chargeTime = "Charge Time"
}

enum Preferences {
    private static let d = UserDefaults.standard

    static var email: String {
        get { d.string(forKey: "polestar_email") ?? "" }
        set { d.set(newValue, forKey: "polestar_email") }
    }

    static var vin: String {
        get { d.string(forKey: "polestar_vin") ?? "" }
        set { d.set(newValue, forKey: "polestar_vin") }
    }

    static var displayOption: DisplayOption {
        get {
            let raw = d.string(forKey: "statusbar_display_option") ?? ""
            return DisplayOption(rawValue: raw) ?? .batteryPercentage
        }
        set { d.set(newValue.rawValue, forKey: "statusbar_display_option") }
    }

    static var launchAtLogin: Bool {
        get { d.bool(forKey: "launch_at_login") }
        set { d.set(newValue, forKey: "launch_at_login") }
    }

    /// One-time migration from the original Polaris, which kept the
    /// password in UserDefaults. If found, move it into the Keychain
    /// and delete the plaintext copy.
    static func migrateLegacyPassword() {
        guard let legacy = d.string(forKey: "polestar_password"), !legacy.isEmpty else { return }
        if (try? Keychain.readPassword()) == nil {
            try? Keychain.savePassword(legacy)
        }
        d.removeObject(forKey: "polestar_password")
    }
}
