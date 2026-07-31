//
//  StatusItemController.swift
//  Polaris (AppKit rewrite)
//
//  Owns the NSStatusItem and its menu. Everything is a plain NSMenu —
//  no window, no view hierarchy kept alive between clicks.
//

import AppKit

final class StatusItemController {

    private let statusItem: NSStatusItem
    private let onRefresh: () -> Void
    private let onSettings: () -> Void

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    init(onRefresh: @escaping () -> Void, onSettings: @escaping () -> Void) {
        self.onRefresh = onRefresh
        self.onSettings = onSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bolt.car", accessibilityDescription: "Polaris")
            button.imagePosition = .imageLeft
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        }
    }

    // MARK: - Rendering

    func showLoading() {
        statusItem.button?.title = " …"
    }

    func render(data: CarData?, error: String?, authenticated: Bool) {
        statusItem.button?.title = " " + barTitle(for: data)
        statusItem.menu = buildMenu(data: data, error: error)
    }

    private func barTitle(for data: CarData?) -> String {
        guard let data else { return "--" }
        switch Preferences.displayOption {
        case .batteryPercentage:
            return String(format: "%.0f%%", data.batteryPercentage)
        case .rangeKm:
            return "\(data.rangeKm)km"
        case .rangeMiles:
            return "\(data.rangeMiles ?? 0)mi"
        case .chargeTime:
            guard data.isCharging, let minutes = data.estimatedChargingTimeToFullMinutes, minutes > 0 else {
                return "0min"
            }
            return Self.shortDuration(minutes: minutes)
        }
    }

    private func buildMenu(data: CarData?, error: String?) -> NSMenu {
        let menu = NSMenu()

        if let data {
            if let model = data.modelName {
                menu.addItem(Self.infoItem(model, bold: true))
            }
            menu.addItem(Self.infoItem(String(format: "Battery  %.0f%%", data.batteryPercentage)))
            var range = "Range  \(data.rangeKm) km"
            if let miles = data.rangeMiles { range += " / \(miles) mi" }
            menu.addItem(Self.infoItem(range))
            menu.addItem(Self.infoItem("Status  \(Self.humanStatus(data.chargingStatus))"))
            if data.isCharging, let minutes = data.estimatedChargingTimeToFullMinutes, minutes > 0 {
                menu.addItem(Self.infoItem("Full in  \(Self.shortDuration(minutes: minutes))"))
            }
            menu.addItem(Self.infoItem("Updated  \(timeFormatter.string(from: data.lastUpdated))"))
        } else {
            menu.addItem(Self.infoItem("No data yet"))
        }

        if let error {
            menu.addItem(.separator())
            menu.addItem(Self.infoItem("⚠︎ \(error)"))
        }

        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshAction), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let settings = NSMenuItem(title: "Settings…", action: #selector(settingsAction), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Polaris", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    // MARK: - Actions

    @objc private func refreshAction() { onRefresh() }
    @objc private func settingsAction() { onSettings() }

    // MARK: - Helpers

    private static func infoItem(_ title: String, bold: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if bold {
            item.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize(for: .regular))]
            )
        }
        return item
    }

    private static func humanStatus(_ raw: String) -> String {
        switch raw {
        case "CHARGING_STATUS_CHARGING": return "Charging"
        case "CHARGING_STATUS_IDLE": return "Idle"
        case "CHARGING_STATUS_DONE": return "Done"
        case "CHARGING_STATUS_DISCHARGING": return "Discharging"
        case "CHARGING_STATUS_ERROR": return "Error"
        case "CHARGING_STATUS_FAULT": return "Fault"
        case "CHARGING_STATUS_SCHEDULED": return "Scheduled"
        case "CHARGING_STATUS_SMART_CHARGING": return "Smart charging"
        default:
            return raw
                .replacingOccurrences(of: "CHARGING_STATUS_", with: "")
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }
    }

    static func shortDuration(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h)h" : "\(h)h\(m)m"
    }
}
