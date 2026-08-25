//
//  LowBattery.swift
//  Polaris (AppKit rewrite)
//
//  Decides when the "plug the car in" reminder fires. Kept apart from
//  Notifier because Notifier can't run outside a real .app bundle and so
//  can't be tested; this is pure and is.
//

import Foundation

enum LowBatteryWatch {

    /// The thresholds offered in Settings, in percent.
    static let thresholds = Array(stride(from: 5, through: 50, by: 5))

    static let defaultThreshold = 20

    /// How far the battery has to climb back above the threshold before the
    /// reminder re-arms. Without it a car sitting on the line would warn,
    /// recover half a percent, and warn again.
    static let rearmMargin = 3.0

    struct Outcome: Equatable {
        let notify: Bool
        /// The warned flag to persist for this car.
        let warned: Bool
    }

    /// A reminder fires on the *downward crossing* of the threshold, once.
    /// Level-triggered would nag on every refresh; edge-triggered from the
    /// previous reading alone would miss the crossing after a relaunch,
    /// when there is no previous reading — hence `warned` coming in from
    /// storage rather than from a comparison.
    static func evaluate(percentage: Double,
                         isCharging: Bool,
                         threshold: Int,
                         warned: Bool) -> Outcome {
        let line = Double(threshold)

        // Back above the line with room to spare: ready to warn again on the
        // next discharge.
        if percentage > line + rearmMargin {
            return Outcome(notify: false, warned: false)
        }
        // Already plugged in — the reminder would be telling the user to do
        // what they've just done.
        if isCharging {
            return Outcome(notify: false, warned: warned)
        }
        if percentage <= line && !warned {
            return Outcome(notify: true, warned: true)
        }
        return Outcome(notify: false, warned: warned)
    }
}
