//
//  MCPTools.swift
//  PolarisMCPKit
//
//  What the three tools answer, worked out from the widget snapshot and
//  nothing else. Pure functions, no I/O: the range maths is the one part of
//  this a wrong answer from could strand someone, so it is testable without
//  a car or a running app.
//
//  The snapshot is deliberately all this reads. It carries no VIN, no
//  location and no tokens, so a Claude conversation can never be handed any
//  of them by this helper.
//

import Foundation
import PolarisShared

public enum MCPTools {

    /// check_trip keeps this much range in reserve on top of the distance.
    public static let tripBuffer = 0.15
    /// Past this the car's own report is old enough to flag.
    static let carStaleAfterMinutes = 6 * 60
    /// Polaris polls every few minutes; an hour without a write means it is
    /// not running, and everything below is the last thing it saw.
    static let appStaleAfterMinutes = 60

    static func round(_ value: Double, _ digits: Int = 0) -> Double {
        let factor = pow(10.0, Double(digits))
        return (value * factor).rounded() / factor
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// "35 min ago", "9 h ago", "2 d 3 h ago". Claude reads these aloud, so
    /// they are shaped for a sentence rather than for parsing.
    static func ago(minutes: Int) -> String {
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60, rest = minutes % 60
        if hours < 24 { return rest == 0 ? "\(hours) h ago" : "\(hours) h \(rest) min ago" }
        let days = hours / 24, h = hours % 24
        return h == 0 ? "\(days) d ago" : "\(days) d \(h) h ago"
    }

    /// The reader's own clock, not UTC: "2026-09-26 12:40 GMT+2". The ISO
    /// value stays alongside for anything that needs to compare exactly.
    static func local(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm zzz"
        return f.string(from: date)
    }

    /// The car's own timestamp, how old it is, and whether that is too old.
    /// Both ages are reported because they mean different things: the car
    /// can be stale while Polaris is polling fine, or the reverse.
    static func freshness(_ s: WidgetSnapshot, now: Date) -> [String: Any] {
        var out: [String: Any] = [:]
        if let reported = s.carReportedAt {
            let age = max(0, Int((now.timeIntervalSince(reported) / 60).rounded()))
            out["data_timestamp"] = iso(reported)
            out["reported_at_local"] = local(reported)
            out["reported_ago"] = ago(minutes: age)
            out["data_age_minutes"] = age
            out["stale"] = age > carStaleAfterMinutes
        } else {
            out["data_timestamp"] = NSNull()
            out["reported_at_local"] = NSNull()
            out["reported_ago"] = NSNull()
            out["data_age_minutes"] = NSNull()
            out["stale"] = NSNull()
        }
        let appAge = max(0, Int((now.timeIntervalSince(s.writtenAt) / 60).rounded()))
        out["polaris_last_updated"] = iso(s.writtenAt)
        out["polaris_updated_ago"] = ago(minutes: appAge)
        if appAge > appStaleAfterMinutes {
            out["note"] = "Polaris has not refreshed for \(appAge) minutes; it may not be running, so this is its last reading."
        }
        return out
    }

    static func car(_ s: WidgetSnapshot) -> [String: Any] {
        ["model": s.carTitle ?? s.modelName ?? NSNull()]
    }

    public static func status(_ s: WidgetSnapshot, now: Date = Date()) -> [String: Any] {
        var out: [String: Any] = [
            "car": car(s),
            "battery_percent": round(s.batteryPercentage, 1),
            "estimated_range_km": s.rangeKm,
            "charging_state": s.statusKey,
            "in_use": s.isDriving,
            "plugged_in": s.isPluggedIn ?? NSNull(),
            "charging_power_kw": s.isCharging
                ? (s.chargingPowerWatts.map { round(Double($0) / 1000, 1) as Any } ?? NSNull())
                : 0,
            "time_to_full_minutes": s.isCharging ? (s.fullInMinutes.map { $0 as Any } ?? NSNull()) : NSNull(),
        ]
        out.merge(freshness(s, now: now)) { _, new in new }
        return out
    }

    public static func odometer(_ s: WidgetSnapshot, now: Date = Date()) -> [String: Any] {
        var out = freshness(s, now: now)
        out["car"] = car(s)
        out["odometer_km"] = s.odometerKm.map { $0 as Any } ?? NSNull()
        // Polaris's own staleness note, if any, is the more urgent one.
        if s.odometerKm == nil, out["note"] == nil {
            out["note"] = "Polaris has no odometer reading for this car."
        }
        return out
    }

    public enum TripVerdict: String {
        case ok = "OK", tight = "TIGHT", no = "NO"
    }

    /// Range against a trip, with a 15% buffer. The distance is Claude's
    /// estimate; the range is the car's own, which speed, cold and load can
    /// miss by a lot — a verdict is guidance, not a guarantee.
    public static func tripCheck(_ s: WidgetSnapshot, destination: String,
                                 distanceKm: Double, returnTrip: Bool,
                                 now: Date = Date()) -> [String: Any] {
        let range = Double(s.rangeKm)
        let required = distanceKm * (returnTrip ? 2 : 1)
        let withBuffer = required * (1 + tripBuffer)
        let margin = range - withBuffer
        let verdict: TripVerdict = margin >= 0 ? .ok : (range >= required ? .tight : .no)

        let percent = Int(tripBuffer * 100)
        let summary: String
        switch verdict {
        case .ok:
            summary = "Enough range, with the \(percent)% buffer to spare."
        case .tight:
            summary = "The trip is within range, but it eats into the \(percent)% buffer. Charge first or plan a charging stop."
        case .no:
            summary = "Not enough range. A charging stop is needed, short by about \(Int((withBuffer - range).rounded(.up))) km including the buffer."
        }

        // Linear guess: the same consumption per km the car's own estimate implies.
        var arrival = 0.0
        if verdict != .no, range > 0 {
            arrival = max(0, s.batteryPercentage * (range - required) / range)
        }

        var out: [String: Any] = [
            "destination": destination,
            "verdict": verdict.rawValue,
            "summary": summary,
            "current_range_km": s.rangeKm,
            "battery_percent": round(s.batteryPercentage, 1),
            "trip_distance_km": round(distanceKm, 1),
            "return_trip": returnTrip,
            "total_distance_km": round(required, 1),
            "buffer_percent": percent,
            "required_range_with_buffer_km": round(withBuffer, 1),
            "margin_km": round(margin, 1),
            "estimated_battery_at_end_percent": round(arrival),
            "caveat": returnTrip
                ? "Round trip assumes no charging at the destination. Range is the car's own estimate; motorway speed and cold weather reduce it."
                : "Range is the car's own estimate; motorway speed and cold weather reduce it.",
        ]
        out.merge(freshness(s, now: now)) { _, new in new }
        return out
    }
}
