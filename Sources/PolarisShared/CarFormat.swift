//
//  CarFormat.swift
//  PolarisShared
//
//  The number formatting the menu and the widget have to agree on. Both
//  render the same car, so a range that reads "412 km" in the menu and
//  "412km" on the desktop would be a bug in the eye of anyone looking at
//  both at once. StatusItemController keeps thin wrappers over these so its
//  own call sites (and their tests) stay as they were.
//

import Foundation

public enum CarFormat {

    /// Takes the already-normalized status key (prefixes stripped), e.g. "IDLE".
    public static func humanStatus(_ key: String) -> String {
        switch key {
        case "CHARGING": return L("Charging")
        case "IDLE": return L("Idle")
        case "DONE": return L("Done")
        case "DISCHARGING": return L("Discharging")
        case "ERROR": return L("Error")
        case "FAULT": return L("Fault")
        case "SCHEDULED": return L("Scheduled")
        case "SMART_CHARGING": return L("Smart charging")
        default:
            return key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    public static func shortDuration(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h)h" : "\(h)h\(m)m"
    }

    /// "7.2 kW" below 10 kW, "150 kW" above — DC fast charging doesn't
    /// need a decimal.
    public static func kilowatts(watts: Int, locale: Locale = .current) -> String {
        let kw = Double(watts) / 1000
        // The separator is locale's, not C's: 7,2 kW in Danish, 7.2 kW in English.
        // Injectable so tests can pin a locale instead of inheriting the
        // machine's — the assertions are written with a decimal point.
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.minimumFractionDigits = kw >= 10 ? 0 : 1
        f.maximumFractionDigits = kw >= 10 ? 0 : 1
        return "\(f.string(from: NSNumber(value: kw)) ?? "\(Int(kw))") kW"
    }

    /// "412 km" / "256 mi"; `grouped` adds thousands separators (odometer).
    /// `locale` only reaches the grouped path — the plain one is an integer
    /// and a suffix, with no separator to get wrong.
    public static func distance(km: Int, grouped: Bool = false,
                                unit: DistanceUnit,
                                locale: Locale = .current) -> String {
        let value = unit.convert(km: km)
        if grouped {
            let f = NumberFormatter(); f.locale = locale; f.numberStyle = .decimal
            return "\(f.string(from: NSNumber(value: value)) ?? "\(value)") \(unit.suffix)"
        }
        return "\(value) \(unit.suffix)"
    }
}
