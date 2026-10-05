//
//  CarStatus.swift
//  Polaris (AppKit rewrite)
//
//  The car states the Data Portal reports beyond battery and odometer:
//  whether it is in use, what the parking climate is doing, whether it is
//  locked and shut, and where it is. All optional on `CarData` — the MyStar
//  path has none of them, and a car may not report every one.
//
//  Also home: Polaris's own idea of it, a coordinate the owner saves from
//  the car's position. The portal's charge locations would do the same job
//  but only exist on Polestar 3, and "parked at home, not plugged in" is a
//  reminder every model deserves.
//

import Foundation

/// Parking climatisation, from `telemetry/parking-climatization`.
struct ClimateStatus: Equatable {
    /// "ON", "OFF" or "PENDING" (UNSPECIFIED dropped).
    let runningStatus: String?
    /// "HEATING", "COOLING" or "NEUTRAL".
    let ventilation: String?
    let currentCelsius: Double?
    let requestedCelsius: Double?
    let minutesLeft: Int?
    /// Error and warning enum cases with their prefixes stripped, e.g.
    /// "NOT_CONNECTED_TO_POWER". Empty when the car is content.
    let problems: [String]
    let reportedAt: Date?

    var isRunning: Bool { runningStatus == "ON" }
    var isPending: Bool { runningStatus == "PENDING" }
}

/// Locks, doors, windows and lids, from `telemetry/exterior`.
struct ExteriorStatus: Equatable {
    /// nil when the car didn't say.
    let locked: Bool?
    /// Which parts are open or ajar, as field names: "frontLeftDoor",
    /// "tailgate", "sunroof"… Rendering turns them into words.
    let openings: [String]
    let alarmTriggered: Bool
    let reportedAt: Date?

    var allShut: Bool { openings.isEmpty }
}

/// Last known position, from `telemetry/location`.
struct CarLocation: Equatable {
    let latitude: Double
    let longitude: Double
    /// Degrees, nil when the car didn't report one.
    let heading: Double?
    let reportedAt: Date?

    /// Great-circle distance in metres. Close enough for "is this home".
    func distance(to other: CarLocation) -> Double {
        let r = 6_371_000.0
        let dLat = (other.latitude - latitude) * .pi / 180
        let dLon = (other.longitude - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(latitude * .pi / 180) * cos(other.latitude * .pi / 180)
            * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }
}

/// What `availability` says about use. The API's own words, prefix stripped:
/// DRIVING, ENGINE_ON, ACTIVE, CONVENIENCE, INACTIVE, ABANDONED, ENGINE_OFF.
enum UsageMode {
    /// The car is being driven, or is switched on with someone in it.
    /// Both read as "in use" in the menu; the distinction the API draws
    /// between them is finer than a menu bar needs.
    static func isInUse(_ mode: String?) -> Bool? {
        guard let mode else { return nil }
        switch mode {
        case "DRIVING", "ENGINE_ON": return true
        case "ABANDONED", "INACTIVE", "CONVENIENCE", "ACTIVE", "ENGINE_OFF": return false
        default: return nil
        }
    }
}

/// Decides when "parked at home, not plugged in" fires. Pure, like
/// `LowBatteryWatch`, so it is testable without a notification centre.
enum HomeWatch {

    /// Within this many metres of the saved point counts as home. Wide
    /// enough for a driveway and the GPS scatter of a parked car, narrow
    /// enough not to include the neighbours.
    static let radiusMetres = 150.0

    /// How long the car has to sit at home unplugged before the reminder
    /// fires. Arriving and plugging in takes a few minutes, and the portal's
    /// charger state can lag the location by a few more.
    static let grace: TimeInterval = 10 * 60

    struct State: Equatable {
        /// When the car was first seen at home and unplugged, nil otherwise.
        var unpluggedSince: Date?
        /// Fired for this stay already; re-arms when the car leaves or plugs in.
        var warned: Bool
    }

    struct Outcome: Equatable {
        let notify: Bool
        let state: State
    }

    static func evaluate(atHome: Bool?, pluggedIn: Bool?, inUse: Bool,
                         state: State, now: Date = Date()) -> Outcome {
        // Away, plugged in, moving, or unknown on either count: not a
        // situation to nag about. Reset so the next arrival starts clean.
        guard atHome == true, pluggedIn == false, !inUse else {
            return Outcome(notify: false, state: State(unpluggedSince: nil, warned: false))
        }
        let since = state.unpluggedSince ?? now
        let overdue = now.timeIntervalSince(since) >= grace
        let notify = overdue && !state.warned
        return Outcome(notify: notify,
                       state: State(unpluggedSince: since, warned: state.warned || notify))
    }
}

/// Decides when "left open or unlocked" fires: parked, not in use, and
/// something open or unlocked for longer than the grace period. Pure, like
/// `HomeWatch` — no home needed, this one fires anywhere the car is parked.
enum OpenWatch {

    /// How long something may sit open or unlocked before the reminder
    /// fires — long enough to carry groceries in, short enough that a
    /// forgotten door doesn't sit that way all night.
    static let grace: TimeInterval = 5 * 60

    struct State: Equatable {
        /// When the car was first seen parked and exposed, nil otherwise.
        var exposedSince: Date?
        /// Fired for this stay already; re-arms once it's shut and locked,
        /// or the car is driven again.
        var warned: Bool
    }

    struct Outcome: Equatable {
        let notify: Bool
        let state: State
    }

    static func evaluate(exposed: Bool, inUse: Bool,
                         state: State, now: Date = Date()) -> Outcome {
        // Shut and locked, or moving: not a situation to nag about. Reset
        // so the next time it's left open starts a fresh clock.
        guard exposed, !inUse else {
            return Outcome(notify: false, state: State(exposedSince: nil, warned: false))
        }
        let since = state.exposedSince ?? now
        let overdue = now.timeIntervalSince(since) >= grace
        let notify = overdue && !state.warned
        return Outcome(notify: notify,
                       state: State(exposedSince: since, warned: state.warned || notify))
    }
}
