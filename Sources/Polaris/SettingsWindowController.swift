//
//  SettingsWindowController.swift
//  Polaris (AppKit rewrite)
//
//  Settings, in the shape macOS settings actually take: a toolbar of panes,
//  and changes that land the moment they're made.
//
//  It used to be one long grid behind Save and Cancel. Two problems with
//  that. A settings pane on this platform doesn't have a Save button —
//  people expect a checkbox to mean something the instant it's ticked, and
//  a window that hoards changes until a button is pressed loses them to a
//  ⌘W. And the grid had grown past the height of the window: account,
//  menu bar, general, notifications, updates and the version number, all
//  in one column.
//
//  Credentials are the exception and keep an explicit Save. An email
//  half-typed is not an email, and writing it per keystroke would tear
//  down a working session on the way to a valid one.
//

import AppKit
import PolarisShared

final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    // MARK: Account pane

    private let emailField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let vinField = NSTextField()
    private let statusDot = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let addCarButton = NSButton(title: L("Add Car…"), target: nil, action: nil)
    private let removeCarButton = NSButton(title: L("Remove Car"), target: nil, action: nil)
    private let saveAccountButton = NSButton(title: L("Save"), target: nil, action: nil)

    // MARK: Menu bar pane

    private let displayPopup = NSPopUpButton()
    private let unitPopup = NSPopUpButton()
    private let launchCheckbox = NSButton(checkboxWithTitle: L("Launch at login"), target: nil, action: nil)

    // MARK: Notifications pane

    private let notifyStartCheckbox = NSButton(checkboxWithTitle: L("Charging started"), target: nil, action: nil)
    private let notifyDoneCheckbox = NSButton(checkboxWithTitle: L("Charging complete"), target: nil, action: nil)
    private let notifyProblemCheckbox = NSButton(checkboxWithTitle: L("Charging problems"), target: nil, action: nil)
    private let notifyLowCheckbox = NSButton(checkboxWithTitle: L("Low battery"), target: nil, action: nil)
    private let lowThresholdPopup = NSPopUpButton()

    // MARK: Updates pane

    private let autoCheckCheckbox = NSButton(checkboxWithTitle: L("Check automatically"), target: nil, action: nil)
    private let autoInstallCheckbox = NSButton(checkboxWithTitle: L("Download and install automatically"), target: nil, action: nil)

    /// Sparkle isn't running under `swift run`, so the update pane is left
    /// out entirely rather than shown dead.
    private let updater: Updater?

    /// Set while the form holds a login for a car being added, so saving
    /// creates a second account instead of overwriting the current one.
    private var isAddingCar = false

    /// Cheap changes: launch-at-login, and redrawing the menu bar with what
    /// the app already has. Never refetches.
    private let onChange: () -> Void
    /// The account changed — the session has to be started over.
    private let onAccountChange: () -> Void

    private let tabs = NSTabViewController()

    init(updater: Updater? = nil,
         onChange: @escaping () -> Void,
         onAccountChange: @escaping () -> Void) {
        self.updater = (updater?.isAvailable == true) ? updater : nil
        self.onChange = onChange
        self.onAccountChange = onAccountChange

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L("Polaris Settings")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        loadValues()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Called by the app whenever it learns something new, so the pane isn't
    /// showing a connection state from whenever it was last opened.
    func updateStatus(data: CarData?, error: String?, authenticated: Bool) {
        let colour: NSColor
        let text: String
        if let error {
            colour = .systemRed
            text = error
        } else if authenticated, let data {
            colour = .systemGreen
            let car = [data.modelName, data.modelYear].compactMap { $0 }.joined(separator: " · ")
            let when = Self.relative(data.lastUpdated)
            text = car.isEmpty
                ? String(format: L("Signed in · updated %@"), when)
                : String(format: L("Signed in · %@ · updated %@"), car, when)
        } else if authenticated {
            colour = .systemGreen
            text = L("Signed in")
        } else {
            colour = .tertiaryLabelColor
            text = L("Not signed in")
        }
        statusLabel.stringValue = text
        statusDot.layer?.backgroundColor = colour.cgColor
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - UI

    private func buildUI() {
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(pane(L("Account"), symbol: "person.crop.circle", view: accountPane()))
        tabs.addTabViewItem(pane(L("Menu Bar"), symbol: "menubar.rectangle", view: menuBarPane()))
        tabs.addTabViewItem(pane(L("Notifications"), symbol: "bell", view: notificationsPane()))
        if updater != nil {
            tabs.addTabViewItem(pane(L("Updates"), symbol: "arrow.down.circle", view: updatesPane()))
        }
        tabs.addTabViewItem(pane(L("About"), symbol: "info.circle", view: aboutPane()))

        window?.contentViewController = tabs
        // The System Settings look: pane icons centred in the title bar
        // rather than a toolbar sitting above the content.
        window?.toolbarStyle = .preference
    }

    private func pane(_ title: String, symbol: String, view: NSView) -> NSTabViewItem {
        let vc = NSViewController()
        let host = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        // Pinned to the leading edge, never stretched to the trailing one.
        // A grid whose label column is trailing-aligned hands every spare
        // point to that column, so a pane stretched to full width ends up
        // with its contents pressed against the right edge — which is what
        // the Menu Bar pane did.
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor, constant: Self.paneInset.height),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: Self.paneInset.width),
            view.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor,
                                           constant: -Self.paneInset.width),
            view.bottomAnchor.constraint(lessThanOrEqualTo: host.bottomAnchor,
                                         constant: -Self.paneInset.height)
        ])
        vc.view = host
        vc.title = title

        // Without this every pane inherits the window's initial size and the
        // window stays at the tallest one — a checkbox pane with 700 points
        // of empty space under it. The tab controller resizes the window to
        // the selected pane's preferred size, so each pane has to state it.
        host.layoutSubtreeIfNeeded()
        let fitting = view.fittingSize
        vc.preferredContentSize = NSSize(
            width: max(Self.paneMinWidth, fitting.width + Self.paneInset.width * 2),
            height: fitting.height + Self.paneInset.height * 2
        )

        let item = NSTabViewItem(viewController: vc)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }

    /// Shared so every pane starts its content at the same point; panes that
    /// disagree on their left margin read as five different windows.
    private static let paneInset = NSSize(width: 24, height: 22)
    /// Wide enough that the five toolbar items aren't crowded.
    private static let paneMinWidth: CGFloat = 480

    // MARK: Panes

    private func accountPane() -> NSView {
        emailField.placeholderString = "you@example.com"
        passwordField.placeholderString = L("Polestar password")
        vinField.placeholderString = L("Vehicle VIN")
        // Editable text fields have no useful intrinsic width; without one,
        // the grid hands the window's spare width to the label column and
        // the whole form ends up shoved against the right edge.
        for field in [emailField, passwordField, vinField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        }
        // Same reason as onboarding: a password manager filling a native app
        // looks for fields that declare what they hold.
        if #available(macOS 14.0, *) {
            emailField.contentType = .username
            passwordField.contentType = .password
        }
        emailField.setAccessibilityIdentifier("username")
        passwordField.setAccessibilityIdentifier("password")

        let grid = NSGridView(views: [
            [label(L("Email:")), emailField],
            [label(L("Password:")), passwordField],
            [label(L("VIN:")), vinField]
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing

        addCarButton.target = self
        addCarButton.action = #selector(addCarAction)
        removeCarButton.target = self
        removeCarButton.action = #selector(removeCarAction)
        saveAccountButton.target = self
        saveAccountButton.action = #selector(saveAccountAction)
        saveAccountButton.keyEquivalent = "\r"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [addCarButton, removeCarButton, spacer, saveAccountButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [statusRow(), grid, buttons])
        stack.orientation = .vertical
        // Leading, so the status line and the grid share a left edge with
        // the other panes rather than centring on their own.
        stack.alignment = .leading
        stack.spacing = 18
        stack.setCustomSpacing(20, after: stack.arrangedSubviews[0])
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    /// A dot and a sentence: signed in or not, which car, how long ago it
    /// last heard anything — or the error, in place of all of it. Without
    /// this the only way to tell a stale session from a quiet car was to
    /// watch the menu bar and guess.
    private func statusRow() -> NSView {
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 4
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let row = NSStackView(views: [statusDot, statusLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func menuBarPane() -> NSView {
        displayPopup.removeAllItems()
        // Selection travels by index, not by title: a translated title can no
        // longer be fed back through init(rawValue:).
        for option in DisplayOption.allCases { displayPopup.addItem(withTitle: option.title) }
        unitPopup.removeAllItems()
        for unit in DistanceUnit.allCases { unitPopup.addItem(withTitle: unit.title) }

        displayPopup.target = self; displayPopup.action = #selector(displayChanged)
        unitPopup.target = self;    unitPopup.action = #selector(unitChanged)
        launchCheckbox.target = self; launchCheckbox.action = #selector(launchChanged)

        let grid = NSGridView(views: [
            [label(L("Show in bar:")), displayPopup],
            [label(L("Distances:")), unitPopup],
            [NSGridCell.emptyContentView, launchCheckbox]
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        for control in [displayPopup, unitPopup, launchCheckbox] {
            grid.cell(for: control)?.xPlacement = .leading
        }
        return grid
    }

    private func notificationsPane() -> NSView {
        lowThresholdPopup.removeAllItems()
        lowThresholdPopup.addItems(withTitles: LowBatteryWatch.thresholds.map { "\($0)%" })
        lowThresholdPopup.target = self
        lowThresholdPopup.action = #selector(notificationsChanged)
        for box in [notifyStartCheckbox, notifyDoneCheckbox, notifyProblemCheckbox, notifyLowCheckbox] {
            box.target = self
            box.action = #selector(notificationsChanged)
        }

        /// The threshold belongs to the checkbox, so the two share a row
        /// rather than the popup floating a line below with a label of its own.
        let lowRow = NSStackView(views: [notifyLowCheckbox, lowThresholdPopup])
        lowRow.orientation = .horizontal
        lowRow.spacing = 8
        lowRow.alignment = .firstBaseline

        let stack = NSStackView(views: [
            notifyStartCheckbox, notifyDoneCheckbox, notifyProblemCheckbox, lowRow
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        return stack
    }

    private func updatesPane() -> NSView {
        autoCheckCheckbox.target = self;   autoCheckCheckbox.action = #selector(updatesChanged)
        autoInstallCheckbox.target = self; autoInstallCheckbox.action = #selector(updatesChanged)

        let check = NSButton(title: L("Check for Updates…"), target: self,
                             action: #selector(checkForUpdatesAction))

        let stack = NSStackView(views: [autoCheckCheckbox, autoInstallCheckbox, check])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(18, after: autoInstallCheckbox)
        return stack
    }

    /// The version used to sit at the bottom of the settings form because
    /// there was nowhere else for it. There is now.
    private func aboutPane() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let name = NSTextField(labelWithString: "Polaris")
        name.font = .systemFont(ofSize: 17, weight: .semibold)

        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        let version = NSTextField(labelWithString: "\(short) (\(build))")
        version.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        version.textColor = .secondaryLabelColor

        let blurb = NSTextField(wrappingLabelWithString:
            L("Battery, range and charging status for your Polestar."))
        blurb.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        blurb.textColor = .secondaryLabelColor

        let text = NSStackView(views: [name, version, blurb])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.setCustomSpacing(10, after: version)

        let row = NSStackView(views: [icon, text])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 16
        return row
    }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.alignment = .right
        return l
    }

    // MARK: - Loading

    private func loadValues() {
        isAddingCar = false
        // Nothing to remove until there's a second car to fall back to.
        removeCarButton.isHidden = Accounts.all.count < 2
        emailField.stringValue = Preferences.email
        passwordField.stringValue = ((try? Keychain.readPassword()) ?? nil) ?? ""
        vinField.stringValue = Preferences.vin
        displayPopup.selectItem(at: DisplayOption.allCases.firstIndex(of: Preferences.displayOption) ?? 0)
        unitPopup.selectItem(at: DistanceUnit.allCases.firstIndex(of: Preferences.distanceUnit) ?? 0)
        launchCheckbox.state = Preferences.launchAtLogin ? .on : .off
        notifyStartCheckbox.state = Preferences.notifyChargingStarted ? .on : .off
        notifyDoneCheckbox.state = Preferences.notifyChargingComplete ? .on : .off
        notifyProblemCheckbox.state = Preferences.notifyChargingProblem ? .on : .off
        notifyLowCheckbox.state = Preferences.notifyLowBattery ? .on : .off
        lowThresholdPopup.selectItem(at: LowBatteryWatch.thresholds
            .firstIndex(of: Preferences.lowBatteryThreshold) ?? 0)
        lowThresholdPopup.isEnabled = (notifyLowCheckbox.state == .on)
        if let updater {
            autoCheckCheckbox.state = updater.automaticallyChecks ? .on : .off
            autoInstallCheckbox.state = updater.automaticallyDownloads ? .on : .off
        }
    }

    // MARK: - Instant apply

    @objc private func displayChanged() {
        guard displayPopup.indexOfSelectedItem >= 0 else { return }
        Preferences.displayOption = DisplayOption.allCases[displayPopup.indexOfSelectedItem]
        onChange()
    }

    @objc private func unitChanged() {
        guard unitPopup.indexOfSelectedItem >= 0 else { return }
        Preferences.distanceUnit = DistanceUnit.allCases[unitPopup.indexOfSelectedItem]
        onChange()
    }

    @objc private func launchChanged() {
        Preferences.launchAtLogin = (launchCheckbox.state == .on)
        onChange()
    }

    @objc private func notificationsChanged() {
        Preferences.notifyChargingStarted = (notifyStartCheckbox.state == .on)
        Preferences.notifyChargingComplete = (notifyDoneCheckbox.state == .on)
        Preferences.notifyChargingProblem = (notifyProblemCheckbox.state == .on)
        Preferences.notifyLowBattery = (notifyLowCheckbox.state == .on)
        if lowThresholdPopup.indexOfSelectedItem >= 0 {
            Preferences.lowBatteryThreshold = LowBatteryWatch.thresholds[lowThresholdPopup.indexOfSelectedItem]
        }
        lowThresholdPopup.isEnabled = (notifyLowCheckbox.state == .on)
    }

    @objc private func updatesChanged() {
        updater?.automaticallyChecks = (autoCheckCheckbox.state == .on)
        updater?.automaticallyDownloads = (autoInstallCheckbox.state == .on)
    }

    @objc private func checkForUpdatesAction() {
        updater?.checkForUpdates()
    }

    // MARK: - Account

    @objc private func saveAccountAction() {
        let email = emailField.stringValue.trimmingCharacters(in: .whitespaces)
        let previous = Preferences.email
        // Editing the address of the account you're on is a rename, not a
        // new car: the old entry and its Keychain items would otherwise be
        // orphaned with no way to reach them.
        if !isAddingCar, !previous.isEmpty, previous != email {
            Accounts.remove(previous)
        }
        Preferences.email = email
        Accounts.add(email)
        Preferences.vin = vinField.stringValue.trimmingCharacters(in: .whitespaces).uppercased()

        let password = passwordField.stringValue
        if password.isEmpty {
            Keychain.deletePassword()
        } else {
            do {
                try Keychain.savePassword(password)
            } catch {
                let alert = NSAlert()
                alert.messageText = L("Couldn't save password to Keychain")
                alert.informativeText = error.localizedDescription
                alert.runModal()
                return
            }
        }

        // Credentials may have changed — drop the stored session so the next
        // login uses the new account rather than resuming the old one.
        Keychain.deleteSessionToken()
        isAddingCar = false
        onAccountChange()
    }

    /// Empty the form for a second Polestar login. The current car stays
    /// signed in — its password and session live under its own address in
    /// the Keychain — and both turn up in the menu's switcher afterwards.
    @objc private func addCarAction() {
        isAddingCar = true
        emailField.stringValue = ""
        passwordField.stringValue = ""
        vinField.stringValue = ""
        window?.makeFirstResponder(emailField)
    }

    @objc private func removeCarAction() {
        let alert = NSAlert()
        alert.messageText = L("Sign out and forget this car?")
        alert.informativeText = String(format: L("Polaris will forget the login for %@."),
                                       Preferences.email)
        alert.addButton(withTitle: L("Remove Car"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Accounts.remove(Preferences.email)
        // The removed car may be the one on the desktop; the next poll fills
        // the widget with whichever car is now active.
        WidgetBridge.clear()
        window?.orderOut(nil)
        onAccountChange()
    }
}
