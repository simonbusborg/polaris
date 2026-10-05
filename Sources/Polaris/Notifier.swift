//
//  Notifier.swift
//  Polaris (AppKit rewrite)
//
//  Local notifications for charging milestones, derived by comparing
//  consecutive refreshes. UNUserNotificationCenter only works from a real
//  .app bundle, so everything is a no-op under `swift run`.
//

import AppKit
import UserNotifications
import PolarisShared

final class Notifier: NSObject, UNUserNotificationCenterDelegate {

    private let available = Bundle.main.bundleURL.pathExtension == "app"
    private var authorized = false

    func requestAuthorizationIfNeeded() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            self?.authorized = granted
        }
    }

    func carDataDidUpdate(old: CarData?, new: CarData) {
        guard available, authorized else { return }

        // Runs before the `old` guard: a reminder that only fired on a
        // comparison would stay silent through the first refresh after
        // launch, which is exactly when the app is catching up on a car
        // that drained while it wasn't running.
        checkLowBattery(new)
        checkParkedAtHome(new)
        checkLeftOpen(new)

        guard let old else { return }

        // Rising edge only: the warning stays true for as long as the car
        // does, and nobody wants it repeated every refresh of a long drive.
        if old.tyreWarnings.isEmpty, !new.tyreWarnings.isEmpty, Preferences.notifyTyrePressure {
            post(title: L("Tyre pressure low"),
                 body: new.tyreWarnings.joined(separator: ", "))
        }
        if !old.batteryWarning, new.batteryWarning, Preferences.notifyBatteryWarning {
            post(title: L("12V battery warning"),
                 body: L("The one fault that can leave the car unable to start"))
        }

        let done = new.statusKey == "DONE" || new.batteryPercentage >= 99.5
        let trouble = new.statusKey == "ERROR" || new.statusKey == "FAULT"

        if !old.isCharging && new.isCharging {
            guard Preferences.notifyChargingStarted else { return }
            var body = String(format: "%.0f%%", new.batteryPercentage)
            if let minutes = new.estimatedChargingTimeToFullMinutes, minutes > 0 {
                body += " · " + String(format: L("full in %@"), StatusItemController.shortDuration(minutes: minutes))
            }
            post(title: L("Charging started"), body: body)
        } else if old.isCharging && !new.isCharging && done {
            guard Preferences.notifyChargingComplete else { return }
            post(title: L("Charging complete"),
                 body: String(format: L("%.0f%% · %@ range"), new.batteryPercentage,
                              StatusItemController.distance(km: new.rangeKm)))
        } else if old.isCharging && trouble {
            guard Preferences.notifyChargingProblem else { return }
            post(title: L("Charging problem"),
                 body: String(format: L("Charger reported an error at %.0f%%"), new.batteryPercentage))
        }
    }

    private func checkLowBattery(_ new: CarData) {
        let vin = new.vin ?? Preferences.vin
        let warned = Preferences.lowBatteryWarned(vin: vin)
        let outcome = LowBatteryWatch.evaluate(percentage: new.batteryPercentage,
                                               isCharging: new.isCharging,
                                               threshold: Preferences.lowBatteryThreshold,
                                               warned: warned)
        // The armed/disarmed state is tracked even with the reminder switched
        // off, so turning it on mid-drive doesn't fire for a crossing that
        // happened while it was off.
        if outcome.warned != warned {
            Preferences.setLowBatteryWarned(outcome.warned, vin: vin)
        }
        guard outcome.notify, Preferences.notifyLowBattery else { return }
        post(title: L("Low battery"),
             body: String(format: L("%.0f%% left — time to plug in"), new.batteryPercentage))
    }

    /// "Parked at home, not plugged in", once per stay, after the grace
    /// period in `HomeWatch`. Needs the Data Portal: only it reports where
    /// the car is and whether the charger is connected.
    private func checkParkedAtHome(_ new: CarData) {
        let vin = new.vin ?? Preferences.vin
        let state = Preferences.homeWatch(vin: vin)
        let outcome = HomeWatch.evaluate(atHome: new.isAtHome, pluggedIn: new.isPluggedIn,
                                         inUse: new.isDriving, state: state)
        if outcome.state != state { Preferences.setHomeWatch(outcome.state, vin: vin) }
        guard outcome.notify, Preferences.notifyParkedAtHome else { return }
        post(title: L("Parked at home, not charging"),
             body: String(format: L("%.0f%% · the charger isn't connected"), new.batteryPercentage))
    }

    /// A door, the tailgate, a window or the lock, once per stay, after the
    /// grace period in `OpenWatch`. Needs the Data Portal: only it reports
    /// which parts are open and whether the car is locked.
    ///
    /// `defaults write com.weareheavy.polaris debug_left_open -bool true`
    /// holds the car exposed regardless of what it actually reports, same
    /// reason as debug_tyre_warning: to see the reminder fire (after the
    /// real grace period — this only fakes the input, not the wait) without
    /// leaving a door open for five minutes on purpose.
    private func checkLeftOpen(_ new: CarData) {
        let vin = new.vin ?? Preferences.vin
        let state = Preferences.openWatch(vin: vin)
        let debugExposed = UserDefaults.standard.bool(forKey: "debug_left_open")
        let outcome = OpenWatch.evaluate(exposed: new.isExposed == true || debugExposed,
                                         inUse: new.isDriving, state: state)
        if outcome.state != state { Preferences.setOpenWatch(outcome.state, vin: vin) }
        guard outcome.notify, Preferences.notifyLeftOpen else { return }
        var parts = new.exterior?.openings.map { StatusItemController.openingName($0) } ?? []
        if new.exterior?.locked == false { parts.append(L("Unlocked")) }
        post(title: L("Left open or unlocked"), body: parts.isEmpty ? L("Unlocked") : parts.joined(separator: ", "))
    }

    private func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // Menu bar apps count as "foreground"; without this the banner is suppressed.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
