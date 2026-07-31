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

    /// Set when a newer release exists; renders as a menu item.
    var updateVersion: String?

    /// Cars on the account; more than one adds a Switch Car submenu.
    var cars: [CarSummary] = []
    var activeVin: String?
    var onSelectCar: ((String) -> Void)?

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
            // Greeting (owner's first name from the Polestar ID profile)
            if let name = data.ownerFirstName, !name.isEmpty {
                menu.addItem(rowItem(Self.greeting(name), bold: true))
            }

            // Car image (studio render of the actual configuration)
            if let imageData = data.imageData, let image = NSImage(data: imageData) {
                menu.addItem(Self.imageItem(image))
            }

            // Identity
            let title = [data.modelName, data.modelYear].compactMap { $0 }.joined(separator: " · ")
            if !title.isEmpty {
                menu.addItem(rowItem(title, bold: true))
            }
            if let plate = data.registrationNo, !plate.isEmpty {
                menu.addItem(kvItem("Plate", plate, copyable: true))
            }
            if let vin = data.vin, !vin.isEmpty {
                menu.addItem(kvItem("VIN", vin, copyable: true))
            }
            if cars.count > 1 {
                let switcher = NSMenuItem(title: "Switch Car", action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                for car in cars {
                    let item = NSMenuItem(title: car.title, action: #selector(selectCarAction(_:)),
                                          keyEquivalent: "")
                    item.target = self
                    item.representedObject = car.vin
                    item.state = (car.vin == activeVin) ? .on : .off
                    submenu.addItem(item)
                }
                switcher.submenu = submenu
                menu.addItem(switcher)
            }

            menu.addItem(.separator())

            // Live data
            menu.addItem(kvItem("Battery", String(format: "%.0f%%", data.batteryPercentage)))
            menu.addItem(kvItem("Range", "\(data.rangeKm) km"))
            menu.addItem(kvItem("Status", Self.humanStatus(data.statusKey)))
            if data.isCharging, let minutes = data.estimatedChargingTimeToFullMinutes, minutes > 0 {
                menu.addItem(kvItem("Full in", Self.shortDuration(minutes: minutes)))
            }

            // Car stats
            var stats: [(String, String)] = []
            if let km = data.odometerKm {
                let f = NumberFormatter(); f.numberStyle = .decimal
                stats.append(("Odometer", "\(f.string(from: NSNumber(value: km)) ?? "\(km)") km"))
            }
            if let days = data.daysToService {
                var service = "in \(days) days"
                if let km = data.distanceToServiceKm { service += " / \(km) km" }
                stats.append(("Service", service))
            }
            if !stats.isEmpty || data.serviceWarning || !data.fluidWarnings.isEmpty {
                menu.addItem(.separator())
                stats.forEach { menu.addItem(kvItem($0.0, $0.1)) }
                if data.serviceWarning {
                    menu.addItem(rowItem("⚠︎ Service warning", warning: true))
                }
                data.fluidWarnings.forEach { menu.addItem(rowItem("⚠︎ \($0)", warning: true)) }
            }

            menu.addItem(.separator())
            menu.addItem(kvItem("Updated", timeFormatter.string(from: data.lastUpdated)))
        } else {
            menu.addItem(Self.infoItem("No data yet"))
        }

        if let error {
            menu.addItem(.separator())
            menu.addItem(Self.infoItem("⚠︎ \(error)"))
        }

        menu.addItem(.separator())

        if let updateVersion {
            let update = NSMenuItem(title: "Update Available (v\(updateVersion))…",
                                    action: #selector(updateAction), keyEquivalent: "")
            update.target = self
            menu.addItem(update)
        }

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
    @objc private func selectCarAction(_ sender: NSMenuItem) {
        guard let vin = sender.representedObject as? String, vin != activeVin else { return }
        onSelectCar?(vin)
    }
    @objc private func updateAction() { NSWorkspace.shared.open(UpdateChecker.releasesPage) }

    // MARK: - Key/value rows (custom views: exact colors, exact width,
    // no system dimming, aligned with the car image)

    /// Total row width — matches the car image container (14 + 280 + 14).
    static let rowWidth: CGFloat = 308

    private func kvItem(_ key: String, _ value: String, copyable: Bool = false) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = KVRowView(key: key, value: value, copyText: copyable ? value : nil)
        if copyable { item.toolTip = "Click to copy" }
        return item
    }

    private func rowItem(_ text: String, bold: Bool = false, warning: Bool = false) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = KVRowView(key: text, value: nil, bold: bold, warning: warning)
        return item
    }

    // MARK: - Helpers

    private static func imageItem(_ image: NSImage) -> NSMenuItem {
        let width: CGFloat = 280
        let aspect = image.size.height / max(image.size.width, 1)
        let height = min(width * aspect, 180)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width + 28, height: height + 8))
        let imageView = NSImageView(frame: NSRect(x: 14, y: 4, width: width, height: height))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        container.addSubview(imageView)

        let item = NSMenuItem()
        item.view = container
        return item
    }

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

    /// Takes the already-normalized status key (prefixes stripped), e.g. "IDLE".
    private static func humanStatus(_ key: String) -> String {
        switch key {
        case "CHARGING": return "Charging"
        case "IDLE": return "Idle"
        case "DONE": return "Done"
        case "DISCHARGING": return "Discharging"
        case "ERROR": return "Error"
        case "FAULT": return "Fault"
        case "SCHEDULED": return "Scheduled"
        case "SMART_CHARGING": return "Smart charging"
        default:
            return key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func shortDuration(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h)h" : "\(h)h\(m)m"
    }

    /// "Hi"/"Hello" in the system language, covering Polestar's markets.
    static func greeting(_ name: String,
                         languageCode: String? = Locale.preferredLanguages.first) -> String {
        let code = String(languageCode?.prefix(2) ?? "en")
        let hello: [String: String] = [
            "da": "Hej", "sv": "Hej", "nb": "Hei", "nn": "Hei", "no": "Hei",
            "de": "Hallo", "nl": "Hallo", "fi": "Hei", "fr": "Bonjour",
            "es": "Hola", "it": "Ciao", "pt": "Olá", "pl": "Cześć",
            "zh": "你好", "ko": "안녕하세요", "en": "Hi"
        ]
        return "\(hello[code] ?? "Hi"), \(name)"
    }
}

/// A menu row rendered as a custom view: key on the left, value right-aligned,
/// consistent colors regardless of enabled state, fixed width matching the
/// car image. Rows with `copyText` highlight on hover and copy on click.
final class KVRowView: NSView {

    private let copyText: String?
    private static let sidePad: CGFloat = 14

    init(key: String, value: String?, bold: Bool = false, warning: Bool = false, copyText: String? = nil) {
        self.copyText = copyText
        let height: CGFloat = bold ? 26 : 24
        super.init(frame: NSRect(x: 0, y: 0, width: StatusItemController.rowWidth, height: height))
        wantsLayer = true
        layer?.cornerRadius = 4

        let keyLabel = NSTextField(labelWithString: key)
        keyLabel.font = bold ? .boldSystemFont(ofSize: 13) : .systemFont(ofSize: 13)
        keyLabel.textColor = warning ? .systemOrange : (value == nil ? .labelColor : .secondaryLabelColor)
        keyLabel.sizeToFit()
        keyLabel.frame.origin = NSPoint(x: Self.sidePad,
                                        y: (height - keyLabel.frame.height) / 2)
        addSubview(keyLabel)

        if let value {
            let valueLabel = NSTextField(labelWithString: value)
            valueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            valueLabel.textColor = .labelColor
            valueLabel.alignment = .right
            valueLabel.sizeToFit()
            // Long values (upholstery names etc.) must not run into the key.
            let maxWidth = StatusItemController.rowWidth - Self.sidePad * 2
                - keyLabel.frame.width - 12
            if valueLabel.frame.width > maxWidth {
                valueLabel.lineBreakMode = .byTruncatingTail
                valueLabel.frame.size.width = maxWidth
                toolTip = value
            }
            valueLabel.frame.origin = NSPoint(
                x: StatusItemController.rowWidth - Self.sidePad - valueLabel.frame.width,
                y: (height - valueLabel.frame.height) / 2
            )
            addSubview(valueLabel)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // Hover highlight + click-to-copy, only for copyable rows.

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        if copyText != nil {
            addTrackingArea(NSTrackingArea(rect: bounds,
                                           options: [.mouseEnteredAndExited, .activeAlways],
                                           owner: self, userInfo: nil))
        }
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.09).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
    }

    override func mouseUp(with event: NSEvent) {
        guard let copyText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyText, forType: .string)
        enclosingMenuItem?.menu?.cancelTracking()
    }
}
