//
//  Preferences.swift
//  Polaris (AppKit rewrite)
//
//  Non-secret settings live in UserDefaults. The password lives in the
//  Keychain (see Keychain.swift) — never in UserDefaults.
//

import Foundation
import PolarisShared

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
            // "Range (km)" was the stored value before units became a setting.
            if raw == "Range (km)" { return .rangeKm }
            return DisplayOption(rawValue: raw) ?? .batteryPercentage
        }
        set { d.set(newValue.rawValue, forKey: "statusbar_display_option") }
    }

    static var distanceUnit: DistanceUnit {
        get {
            let raw = d.string(forKey: "distance_unit") ?? ""
            return DistanceUnit(rawValue: raw) ?? .kilometers
        }
        set { d.set(newValue.rawValue, forKey: "distance_unit") }
    }

    static var launchAtLogin: Bool {
        get { d.bool(forKey: "launch_at_login") }
        set { d.set(newValue, forKey: "launch_at_login") }
    }

    // Notification preferences default to on; only an explicit opt-out
    // (stored false) disables them.
    private static func boolDefaultTrue(_ key: String) -> Bool {
        d.object(forKey: key) == nil ? true : d.bool(forKey: key)
    }

    static var notifyChargingStarted: Bool {
        get { boolDefaultTrue("notify_charging_started") }
        set { d.set(newValue, forKey: "notify_charging_started") }
    }

    static var notifyChargingComplete: Bool {
        get { boolDefaultTrue("notify_charging_complete") }
        set { d.set(newValue, forKey: "notify_charging_complete") }
    }

    static var notifyChargingProblem: Bool {
        get { boolDefaultTrue("notify_charging_problem") }
        set { d.set(newValue, forKey: "notify_charging_problem") }
    }

    static var notifyLowBattery: Bool {
        get { boolDefaultTrue("notify_low_battery") }
        set { d.set(newValue, forKey: "notify_low_battery") }
    }

    static var lowBatteryThreshold: Int {
        get {
            guard let stored = d.object(forKey: "low_battery_threshold") as? Int,
                  LowBatteryWatch.thresholds.contains(stored) else {
                return LowBatteryWatch.defaultThreshold
            }
            return stored
        }
        set { d.set(newValue, forKey: "low_battery_threshold") }
    }

    /// Whether the low-battery reminder has already fired for this car's
    /// current discharge. Kept per VIN and on disk so quitting the app
    /// doesn't re-arm it, and so one car's level can't warn for the other.
    static func lowBatteryWarned(vin: String) -> Bool {
        d.bool(forKey: "low_battery_warned_" + vin)
    }

    static func setLowBatteryWarned(_ warned: Bool, vin: String) {
        d.set(warned, forKey: "low_battery_warned_" + vin)
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
