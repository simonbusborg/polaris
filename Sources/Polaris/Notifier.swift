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
        guard available, authorized, let old else { return }

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
