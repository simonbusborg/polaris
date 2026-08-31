//
//  DistanceUnit.swift
//  PolarisShared
//
//  Shared because the widget has to render the same distances as the menu
//  but cannot read the app's preference: an .appex is sandboxed, so
//  UserDefaults.standard there is the extension's own domain, not Polaris's.
//  The app therefore writes the chosen unit into the snapshot and the widget
//  formats with this same type.
//

import Foundation

/// The raw values are what sits in UserDefaults and must never be translated
/// — a Danish user's stored setting has to still parse after they switch the
/// system to German. `title` is the translated face of the same case.
public enum DistanceUnit: String, CaseIterable, Codable {
    case kilometers = "Kilometers (km)"
    case miles = "Miles (mi)"

    public var title: String {
        switch self {
        case .kilometers: return L("Kilometers (km)")
        case .miles: return L("Miles (mi)")
        }
    }

    public var suffix: String { self == .kilometers ? "km" : "mi" }

    /// The API reports km only; miles are converted locally.
    public func convert(km: Int) -> Int {
        self == .kilometers ? km : Int((Double(km) * 0.621371).rounded())
    }
}
