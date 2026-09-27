//
//  StatusItemController.swift
//  Polaris (AppKit rewrite)
//
//  Owns the NSStatusItem and its menu. Everything is a plain NSMenu —
//  no window, no view hierarchy kept alive between clicks.
//

import AppKit
import PolarisShared

final class StatusItemController {

    private let statusItem: NSStatusItem
    private let onRefresh: () -> Void
    private let onSettings: () -> Void

    /// Set when a newer release exists; renders as a menu item.
    /// Set only when Sparkle is running (a real .app bundle); the menu item
    /// is hidden otherwise.
    var onCheckForUpdates: (() -> Void)?

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

    private var lastRender: (data: CarData?, error: String?, authenticated: Bool)?

    func render(data: CarData?, error: String?, authenticated: Bool) {
        lastRender = (data, error, authenticated)
        // First render wires the preview's callback; the closure is idempotent.
        LocationPreview.shared.onUpdate = { [weak self] in
            guard let self, let last = self.lastRender else { return }
            self.render(data: last.data, error: last.error, authenticated: last.authenticated)
            // The widget was published before the street was known; publish
            // again now that it is. sameData() makes a no-op of the rest.
            if let data = last.data { WidgetBridge.publish(data) }
        }
        let symbol = Self.icon(for: data)
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Polaris")
        statusItem.button?.title = " " + barTitle(for: data)
        statusItem.menu = buildMenu(data: data, error: error)
    }

    /// Drop the menu as though the icon had been clicked. Clicking the
    /// widget lands here: an LSUIElement app has no window to bring forward,
    /// so the menu is the only thing there is to open.
    func popMenu() {
        statusItem.button?.performClick(nil)
    }

    /// Menu bar icon by car state: filled bolted car while charging, bolted
    /// car when plugged in but not charging, plain car when unplugged.
    /// Always a template image with no tint, so it follows the menu bar's
    /// appearance like the clock. Unknown plug state (gRPC unavailable)
    /// reads as unplugged.
    static func icon(for data: CarData?) -> String {
        guard let data else { return "car" }
        if data.isCharging { return "bolt.car.fill" }
        if data.isDriving { return "car.fill" }
        if data.isPluggedIn == true { return "bolt.car" }
        return "car"
    }

    private func barTitle(for data: CarData?) -> String {
        guard let data else { return "--" }
        switch Preferences.displayOption {
        case .batteryPercentage:
            return String(format: "%.0f%%", data.batteryPercentage)
        case .rangeKm:
            let unit = Preferences.distanceUnit
            return "\(unit.convert(km: data.rangeKm))\(unit.suffix)"
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
                menu.addItem(Self.imageItem(image, description: data.modelName))
            }

            // Identity
            let title = [data.modelName, data.modelYear].compactMap { $0 }.joined(separator: " · ")
            if !title.isEmpty {
                menu.addItem(rowItem(title, bold: true))
            }
            // Only the variant earns a row: the title above already says
            // "Polestar 4 · 2026", so make and model would just repeat it, and
            // the raw pno34 means nothing to an owner.
            if let variant = data.spec?.variant {
                menu.addItem(kvItem(L("Variant"), variant))
            }
            // `defaults write com.weareheavy.polaris debug_pno34 -bool YES`
            // brings the raw code back, copyable. It is how a car's pno34 gets
            // read off a running app in the first place, which is the only way
            // PNO34.variantsByPrefix will ever be filled in.
            if let spec = data.spec, UserDefaults.standard.bool(forKey: "debug_pno34") {
                menu.addItem(kvItem(L("Product Code"), spec.raw, copyable: true))
            }
            if let plate = data.registrationNo, !plate.isEmpty {
                menu.addItem(kvItem(L("Plate"), plate, copyable: true))
            }
            if let vin = data.vin, !vin.isEmpty {
                menu.addItem(kvItem(L("VIN"), vin, copyable: true))
            }
            if cars.count > 1 {
                let switcher = NSMenuItem(title: L("Switch Car"), action: nil, keyEquivalent: "")
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
            menu.addItem(kvItem(L("Battery"), String(format: "%.0f%%", data.batteryPercentage)))
            let barItem = NSMenuItem()
            barItem.view = BatteryBarView(
                fraction: data.batteryPercentage / 100,
                color: Self.batteryColor(percentage: data.batteryPercentage, charging: data.isCharging)
            )
            menu.addItem(barItem)
            menu.addItem(kvItem(L("Range"), Self.distance(km: data.rangeKm)))
            menu.addItem(kvItem(L("Status"), data.isDriving ? L("In use") : Self.humanStatus(data.statusKey)))
            switch data.grpcExtras?.chargerConnectionStatus {
            case "CONNECTED": menu.addItem(kvItem(L("Charger"), L("Connected")))
            case "DISCONNECTED": menu.addItem(kvItem(L("Charger"), L("Disconnected")))
            case "FAULT": menu.addItem(kvItem(L("Charger"), L("Fault"), valueWarning: true))
            default: break
            }
            // `defaults write com.weareheavy.polaris debug_charging_type -string DC`
            // renders the charging rows on a parked car. The values are invented
            // here rather than injected upstream, so the flag can never dress up
            // a parser fault as a working feature — if this row looks right, it
            // says the layout is right and nothing about the wire format.
            if let fake = UserDefaults.standard.string(forKey: "debug_charging_type"), !fake.isEmpty {
                menu.addItem(kvItem(L("Power"), "\(Self.kilowatts(watts: 11000)) · \(fake)"))
            } else if data.isCharging, let watts = data.grpcExtras?.chargingPowerWatts, watts > 0 {
                // The AC/DC distinction belongs with the power reading rather
                // than on its own row — it is what makes 11 kW or 150 kW make
                // sense. The car only reports it while it is actually charging.
                var power = Self.kilowatts(watts: watts)
                if let type = data.grpcExtras?.chargingType { power += " · \(type)" }
                menu.addItem(kvItem(L("Power"), power))
            }
            if data.isCharging, let minutes = data.estimatedChargingTimeToFullMinutes, minutes > 0 {
                let fullAt = data.lastUpdated.addingTimeInterval(TimeInterval(minutes * 60))
                menu.addItem(kvItem(L("Full in"),
                                    "\(Self.shortDuration(minutes: minutes)) · \(timeFormatter.string(from: fullAt))"))
            }
            // 100 is the default and says nothing; a lower limit is a choice
            // the owner made, and explains why "full" stops short.
            if let target = data.targetSoc, target > 0, target < 100 {
                menu.addItem(kvItem(L("Charge limit"), "\(target)%"))
            }

            // Everything from here on is Data Portal only, and shows up as
            // the credential's scopes allow. Rows, not a section: the menu
            // reads as one car, not as two APIs.
            // `defaults write com.weareheavy.polaris debug_climate -string HEATING`
            // renders the climate row on an idle car, invented values and all,
            // for the same reason as debug_charging_type: to see the layout
            // without waiting for a frosty morning. COOLING and PENDING work too.
            var climate = data.climate
            if let fake = UserDefaults.standard.string(forKey: "debug_climate"), !fake.isEmpty {
                climate = ClimateStatus(runningStatus: fake == "PENDING" ? "PENDING" : "ON",
                                        ventilation: fake, currentCelsius: 12, requestedCelsius: 21,
                                        minutesLeft: 18, problems: [], reportedAt: Date())
            }
            if let climate, let text = Self.climateText(climate) {
                menu.addItem(kvItem(L("Climate"), text))
            }
            data.climate?.problems.forEach {
                menu.addItem(rowItem("⚠︎ " + String(format: L("Climate: %@"), Self.climateProblem($0)), warning: true))
            }

            if let exterior = data.exterior {
                if let locked = exterior.locked {
                    let value = (locked ? L("Locked") : L("Unlocked")) + Self.ageSuffix(exterior.reportedAt)
                    menu.addItem(kvItem(L("Doors"), value, valueWarning: !locked))
                }
                exterior.openings.forEach {
                    menu.addItem(rowItem("⚠︎ " + String(format: L("%@ open"), Self.openingName($0)), warning: true))
                }
                if exterior.alarmTriggered {
                    menu.addItem(rowItem("⚠︎ " + L("Alarm triggered"), warning: true))
                }
            }

            // A map and a street, both from Apple, both arriving a moment
            // after the first build; until then the row shows the coordinate.
            // Either click opens Maps. The reading's age goes on the map when
            // there is one, because "Hjallesevej 12, Odense · 20 hr ago" no
            // longer fits a row.
            if let location = data.location {
                let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                LocationPreview.shared.prepare(location, dark: dark)
                let preview = LocationPreview.shared.entry(for: location, dark: dark)
                let age = Self.ageSuffix(location.reportedAt)
                let open = {
                    let url = URL(string: "https://maps.apple.com/?ll=\(location.latitude),\(location.longitude)&q=Polestar")!
                    NSWorkspace.shared.open(url)
                }
                if let map = preview?.map {
                    let caption = age.replacingOccurrences(of: " · ", with: "")
                    menu.addItem(Self.imageItem(LocationPreview.captioned(map, caption: caption),
                                                description: L("Location"), onClick: open))
                }
                var place = data.isAtHome == true ? L("Home") : (preview?.address ?? Self.coordinate(location))
                if preview?.map == nil { place += age }
                menu.addItem(kvItem(L("Location"), place, onClick: open))
            }

            // Car stats
            var stats: [(String, String)] = []
            if let km = data.odometerKm {
                stats.append((L("Odometer"), Self.distance(km: km, grouped: true)))
            }
            var serviceSoon = false
            if let days = data.daysToService {
                var service = String(format: L(days == 1 ? "in %d day" : "in %d days"), days)
                if let km = data.distanceToServiceKm { service += " / \(Self.distance(km: km))" }
                serviceSoon = days < 30
                stats.append((L("Service"), service))
            }
            if !stats.isEmpty || data.serviceWarning || !data.fluidWarnings.isEmpty {
                menu.addItem(.separator())
                stats.forEach {
                    menu.addItem(kvItem($0.0, $0.1, valueWarning: $0.0 == L("Service") && serviceSoon))
                }
                if data.serviceWarning {
                    menu.addItem(rowItem("⚠︎ " + L("Service warning"), warning: true))
                }
                data.fluidWarnings.forEach { menu.addItem(rowItem("⚠︎ \($0)", warning: true)) }
            }

            menu.addItem(.separator())
            menu.addItem(kvItem(L("Updated"), timeFormatter.string(from: data.lastUpdated)))
        } else {
            menu.addItem(Self.infoItem(L("No data yet")))
        }

        if let error {
            menu.addItem(.separator())
            menu.addItem(Self.infoItem("⚠︎ \(error)"))
        }

        menu.addItem(.separator())

        let settings = NSMenuItem(title: L("Settings…"), action: #selector(settingsAction), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        // Refreshing and updating are both "housekeeping" next to the car
        // itself, so they sit under Settings rather than above it.
        let refresh = NSMenuItem(title: L("Refresh Now"), action: #selector(refreshAction), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        if onCheckForUpdates != nil {
            let update = NSMenuItem(title: L("Check for Updates…"),
                                    action: #selector(updateAction), keyEquivalent: "")
            update.target = self
            menu.addItem(update)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("Quit Polaris"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    // MARK: - Actions

    @objc private func refreshAction() { onRefresh() }
    @objc private func settingsAction() { onSettings() }
    @objc private func selectCarAction(_ sender: NSMenuItem) {
        guard let vin = sender.representedObject as? String, vin != activeVin else { return }
        onSelectCar?(vin)
    }
    @objc private func updateAction() { onCheckForUpdates?() }

    // MARK: - Key/value rows (custom views: exact colors, exact width,
    // no system dimming, aligned with the car image)

    /// Total row width — matches the car image container (14 + 280 + 14).
    static let rowWidth: CGFloat = 308

    private func kvItem(_ key: String, _ value: String, copyable: Bool = false,
                        valueWarning: Bool = false, onClick: (() -> Void)? = nil) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = KVRowView(key: key, value: value, valueWarning: valueWarning,
                              copyText: copyable ? value : nil, onClick: onClick)
        if copyable { item.toolTip = L("Click to copy") }
        if onClick != nil { item.toolTip = L("Click to open in Maps") }
        return item
    }

    // MARK: - Data Portal row wording

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    /// " · 3 hr. ago" once a reading is old enough that showing it as the
    /// present would mislead. Doors and location can lag hours behind the
    /// battery; the owner should see that, not a confident "Locked".
    static func ageSuffix(_ reportedAt: Date?, now: Date = Date()) -> String {
        guard let reportedAt, now.timeIntervalSince(reportedAt) > 30 * 60 else { return "" }
        return " · " + relativeFormatter.localizedString(for: reportedAt, relativeTo: now)
    }

    private static let temperatureFormatter: MeasurementFormatter = {
        let f = MeasurementFormatter()
        f.numberFormatter.maximumFractionDigits = 0
        return f
    }()

    static func temperature(celsius: Double) -> String {
        temperatureFormatter.string(from: Measurement(value: celsius, unit: UnitTemperature.celsius))
    }

    /// "55.6761° N, 12.5683° E": four decimals is about ten metres, which
    /// is what the car's GPS is good for.
    static func coordinate(_ l: CarLocation) -> String {
        String(format: "%.4f° %@, %.4f° %@",
               abs(l.latitude), l.latitude >= 0 ? L("N") : L("S"),
               abs(l.longitude), l.longitude >= 0 ? L("E") : L("W"))
    }

    /// "Heating to 21 °C · 18 min": the target and the time, which is what
    /// you check for. The cabin's current temperature is dropped; it made
    /// the row too long to say anything. nil when the climate is off, so
    /// the row and the widget line simply don't appear.
    static func climateText(_ climate: ClimateStatus) -> String? {
        guard climate.isRunning || climate.isPending else { return nil }
        var parts: [String] = []
        let target = climate.requestedCelsius.map(temperature(celsius:))
        if climate.isPending {
            parts.append(L("Starting"))
            if let target { parts.append(target) }
        } else {
            parts.append(climateVerb(climate.ventilation, target: target))
        }
        if let left = climate.minutesLeft, left > 0 {
            parts.append(String(format: L("%d min"), left))
        }
        return parts.joined(separator: " · ")
    }

    static func climateVerb(_ ventilation: String?, target: String?) -> String {
        switch (ventilation, target) {
        case ("HEATING", let t?): return String(format: L("Heating to %@"), t)
        case ("COOLING", let t?): return String(format: L("Cooling to %@"), t)
        case ("HEATING", nil): return L("Heating")
        case ("COOLING", nil): return L("Cooling")
        case (_, let t?): return L("On") + " · " + t
        default: return L("On")
        }
    }

    static func openingName(_ part: String) -> String {
        switch part {
        case "frontLeftDoor": return L("Front left door")
        case "frontRightDoor": return L("Front right door")
        case "rearLeftDoor": return L("Rear left door")
        case "rearRightDoor": return L("Rear right door")
        case "hood": return L("Hood")
        case "tailgate": return L("Tailgate")
        case "tankLid": return L("Charge port lid")
        case "sunroof": return L("Sunroof")
        case "frontLeftWindow": return L("Front left window")
        case "frontRightWindow": return L("Front right window")
        case "rearLeftWindow": return L("Rear left window")
        case "rearRightWindow": return L("Rear right window")
        default: return part
        }
    }

    static func climateProblem(_ key: String) -> String {
        switch key {
        case "NOT_CONNECTED_TO_POWER": return L("not connected to power")
        case "BATTERY_LOW": return L("battery too low")
        case "INTERRUPTED": return L("interrupted")
        case "REACHED_MAX_RUNTIME": return L("reached its time limit")
        case "RUN_TIME_NEARING_LIMIT": return L("nearing its time limit")
        case "SERVICE_REQUIRED": return L("needs service")
        case "TEMPORARILY_NOT_AVAILABLE": return L("temporarily unavailable")
        default: return key.replacingOccurrences(of: "_", with: " ").lowercased()
        }
    }

    private func rowItem(_ text: String, bold: Bool = false, warning: Bool = false) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = KVRowView(key: text, value: nil, bold: bold, warning: warning)
        return item
    }

    // MARK: - Helpers

    private static func imageItem(_ image: NSImage, description: String?,
                                  onClick: (() -> Void)? = nil) -> NSMenuItem {
        let width: CGFloat = 280
        let aspect = image.size.height / max(image.size.width, 1)
        let height = min(width * aspect, 180)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width + 28, height: height + 8))
        let imageView = ClickableImageView(frame: NSRect(x: 14, y: 4, width: width, height: height))
        imageView.image = image
        imageView.onClick = onClick
        imageView.setAccessibilityLabel(description)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        // Maps come back square-cornered; the car render is on transparency
        // and doesn't care.
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = onClick == nil ? 0 : 6
        imageView.layer?.masksToBounds = true
        container.addSubview(imageView)

        let item = NSMenuItem()
        item.view = container
        if onClick != nil { item.toolTip = L("Click to open in Maps") }
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

    // The formatting itself lives in PolarisShared so the widget renders the
    // same numbers; these stay as the menu's call sites (and their tests)
    // already know them, and supply the unit the extension can't read.

    private static func humanStatus(_ key: String) -> String {
        CarFormat.humanStatus(key)
    }

    static func shortDuration(minutes: Int) -> String {
        CarFormat.shortDuration(minutes: minutes)
    }

    static func kilowatts(watts: Int, locale: Locale = .current) -> String {
        CarFormat.kilowatts(watts: watts, locale: locale)
    }

    static func distance(km: Int, grouped: Bool = false,
                         unit: DistanceUnit = Preferences.distanceUnit,
                         locale: Locale = .current) -> String {
        CarFormat.distance(km: km, grouped: grouped, unit: unit, locale: locale)
    }

    static func batteryColor(percentage: Double, charging: Bool) -> NSColor {
        if charging { return .systemGreen }
        if percentage <= 20 { return .systemOrange }
        return .controlAccentColor
    }

    /// "Hi"/"Hello" in the system language — but only for languages the rest
    /// of the menu also speaks. A greeting in Chinese above an all-English
    /// menu promises a localization that doesn't exist.
    static func greeting(_ name: String,
                         languageCode: String? = Locale.preferredLanguages.first) -> String {
        let code = String(languageCode?.prefix(2) ?? "en")
        let hello: [String: String] = [
            "da": "Hej", "sv": "Hej", "nb": "Hei", "nn": "Hei", "no": "Hei",
            "de": "Hallo", "nl": "Hallo", "fi": "Hei", "fr": "Bonjour",
            "es": "Hola", "it": "Ciao", "pt": "Olá", "pl": "Cześć",
            "en": "Hi"
        ]
        return "\(hello[code] ?? "Hi"), \(name)"
    }
}

/// A menu row rendered as a custom view: key on the left, value right-aligned,
/// consistent colors regardless of enabled state, fixed width matching the
/// car image. Rows with `copyText` or `onClick` highlight on hover and act
/// on click.
final class KVRowView: NSView {

    private let copyText: String?
    private let onClick: (() -> Void)?
    private static let sidePad: CGFloat = 14

    init(key: String, value: String?, bold: Bool = false, warning: Bool = false,
         valueWarning: Bool = false, copyText: String? = nil, onClick: (() -> Void)? = nil) {
        self.copyText = copyText
        self.onClick = onClick
        let height: CGFloat = bold ? 26 : 24
        super.init(frame: NSRect(x: 0, y: 0, width: StatusItemController.rowWidth, height: height))
        wantsLayer = true
        layer?.cornerRadius = 4

        // A menu item with a custom view exposes nothing to VoiceOver on its
        // own, so without this the whole data section of the menu is silent.
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(value.map { "\(key), \($0)" } ?? key)

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
            valueLabel.textColor = valueWarning ? .systemOrange : .labelColor
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
        if copyText != nil || onClick != nil {
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
        if let onClick {
            enclosingMenuItem?.menu?.cancelTracking()
            onClick()
            return
        }
        guard let copyText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyText, forType: .string)
        enclosingMenuItem?.menu?.cancelTracking()
    }
}

/// An image row that can act on a click, for the map. Same rule as the KV
/// rows: clicking closes the menu first, so Maps comes up in front of it.
final class ClickableImageView: NSImageView {
    var onClick: (() -> Void)?

    override func mouseUp(with event: NSEvent) {
        guard let onClick else { return super.mouseUp(with: event) }
        enclosingMenuItem?.menu?.cancelTracking()
        onClick()
    }
}

/// Slim battery-level bar shown under the Battery row, aligned with the
/// KV rows' side padding. Green while charging, orange when low.
/// Layer-backed like KVRowView; colors resolve via effectiveAppearance so
/// dark mode and the vibrant menu background are handled correctly.
final class BatteryBarView: NSView {

    private let color: NSColor
    private let trackLayer = CALayer()
    private let fillLayer = CALayer()

    init(fraction: Double, color: NSColor) {
        self.color = color
        let height: CGFloat = 13
        let sidePad: CGFloat = 14
        let barHeight: CGFloat = 5
        super.init(frame: NSRect(x: 0, y: 0, width: StatusItemController.rowWidth, height: height))
        wantsLayer = true
        // Decorative: the Battery row above already reads the percentage, and
        // a second element saying the same number is worse for VoiceOver, not
        // better.
        setAccessibilityElement(false)

        let track = CGRect(x: sidePad, y: (height - barHeight) / 2,
                           width: StatusItemController.rowWidth - sidePad * 2, height: barHeight)
        trackLayer.frame = track
        trackLayer.cornerRadius = barHeight / 2
        layer?.addSublayer(trackLayer)

        let clamped = CGFloat(min(max(fraction, 0), 1))
        var fill = track
        // Never narrower than the endcap radius, or the rounding inverts.
        fill.size.width = clamped > 0 ? max(track.width * clamped, barHeight) : 0
        fillLayer.frame = fill
        fillLayer.cornerRadius = barHeight / 2
        layer?.addSublayer(fillLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            trackLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
            fillLayer.backgroundColor = color.cgColor
        }
    }
}
