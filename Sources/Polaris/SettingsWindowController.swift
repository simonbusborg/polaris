//
//  SettingsWindowController.swift
//  Polaris (AppKit rewrite)
//
//  A small programmatic settings window: email, password (Keychain),
//  VIN, menu bar display option, launch at login.
//

import AppKit

final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    private let emailField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let vinField = NSTextField()
    private let displayPopup = NSPopUpButton()
    private let unitPopup = NSPopUpButton()
    private let launchCheckbox = NSButton(checkboxWithTitle: L("Launch at login"), target: nil, action: nil)
    private let notifyStartCheckbox = NSButton(checkboxWithTitle: L("Charging started"), target: nil, action: nil)
    private let notifyDoneCheckbox = NSButton(checkboxWithTitle: L("Charging complete"), target: nil, action: nil)
    private let notifyProblemCheckbox = NSButton(checkboxWithTitle: L("Charging problems"), target: nil, action: nil)
    private let autoCheckCheckbox = NSButton(checkboxWithTitle: L("Check automatically"), target: nil, action: nil)
    private let autoInstallCheckbox = NSButton(checkboxWithTitle: L("Download and install automatically"), target: nil, action: nil)

    /// Sparkle isn't running under `swift run`, so the two update rows are
    /// left out entirely rather than shown dead.
    private let updater: Updater?

    private let addCarButton = NSButton(title: L("Add Car…"), target: nil, action: nil)
    private let removeCarButton = NSButton(title: L("Remove Car"), target: nil, action: nil)

    /// Set while the form holds a login for a car being added, so saving
    /// creates a second account instead of overwriting the current one.
    private var isAddingCar = false

    private let onSave: () -> Void

    init(updater: Updater? = nil, onSave: @escaping () -> Void) {
        self.updater = (updater?.isAvailable == true) ? updater : nil
        self.onSave = onSave

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
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

    // MARK: - UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

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

        // Selection travels by index, not by title: a translated title can no
        // longer be fed back through init(rawValue:).
        displayPopup.removeAllItems()
        for option in DisplayOption.allCases {
            displayPopup.addItem(withTitle: option.title)
        }
        unitPopup.removeAllItems()
        for unit in DistanceUnit.allCases {
            unitPopup.addItem(withTitle: unit.title)
        }

        let grid = NSGridView(views: [
            [label(L("Email:")), emailField],
            [label(L("Password:")), passwordField],
            [label(L("VIN:")), vinField],
            [label(L("Show in bar:")), displayPopup],
            [label(L("Distances:")), unitPopup],
            [NSGridCell.emptyContentView, launchCheckbox],
            [label(L("Notify about:")), notifyStartCheckbox],
            [NSGridCell.emptyContentView, notifyDoneCheckbox],
            [NSGridCell.emptyContentView, notifyProblemCheckbox]
        ])
        if updater != nil {
            grid.addRow(with: [label(L("Updates:")), autoCheckCheckbox])
            grid.addRow(with: [NSGridCell.emptyContentView, autoInstallCheckbox])
        }
        grid.rowSpacing = 12
        grid.columnSpacing = 10
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        // Text fields stretch with the window; popups and checkboxes keep
        // their natural width.
        for control in [displayPopup, unitPopup, launchCheckbox, notifyStartCheckbox,
                        notifyDoneCheckbox, notifyProblemCheckbox,
                        autoCheckCheckbox, autoInstallCheckbox] {
            grid.cell(for: control)?.xPlacement = .leading
        }
        // Extra air between the account fields and the app options, and
        // before the notification group. Tighter rows inside that group.
        grid.row(at: 3).topPadding = 10
        grid.row(at: 6).topPadding = 10
        grid.row(at: 7).topPadding = -6
        grid.row(at: 8).topPadding = -6
        if updater != nil {
            grid.row(at: 9).topPadding = 10
            grid.row(at: 10).topPadding = -6
        }
        grid.translatesAutoresizingMaskIntoConstraints = false

        let saveButton = NSButton(title: L("Save"), target: self, action: #selector(saveAction))
        saveButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: L("Cancel"), target: self, action: #selector(cancelAction))
        cancelButton.keyEquivalent = "\u{1b}"

        addCarButton.target = self
        addCarButton.action = #selector(addCarAction)
        removeCarButton.target = self
        removeCarButton.action = #selector(removeCarAction)

        let buttons = NSStackView(views: [cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let accountButtons = NSStackView(views: [addCarButton, removeCarButton])
        accountButtons.orientation = .horizontal
        accountButtons.spacing = 8
        accountButtons.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(grid)
        content.addSubview(buttons)
        content.addSubview(accountButtons)
        NSLayoutConstraint.activate([
            accountButtons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            accountButtons.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            buttons.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])

        window?.setContentSize(NSSize(width: 420, height: content.fittingSize.height))
    }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.alignment = .right
        return l
    }

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
        if let updater {
            autoCheckCheckbox.state = updater.automaticallyChecks ? .on : .off
            autoInstallCheckbox.state = updater.automaticallyDownloads ? .on : .off
        }
    }

    // MARK: - Actions

    @objc private func saveAction() {
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
        if displayPopup.indexOfSelectedItem >= 0 {
            Preferences.displayOption = DisplayOption.allCases[displayPopup.indexOfSelectedItem]
        }
        if unitPopup.indexOfSelectedItem >= 0 {
            Preferences.distanceUnit = DistanceUnit.allCases[unitPopup.indexOfSelectedItem]
        }
        Preferences.launchAtLogin = (launchCheckbox.state == .on)
        Preferences.notifyChargingStarted = (notifyStartCheckbox.state == .on)
        Preferences.notifyChargingComplete = (notifyDoneCheckbox.state == .on)
        Preferences.notifyChargingProblem = (notifyProblemCheckbox.state == .on)
        if let updater {
            updater.automaticallyChecks = (autoCheckCheckbox.state == .on)
            updater.automaticallyDownloads = (autoInstallCheckbox.state == .on)
        }

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

        window?.orderOut(nil)
        onSave()
    }

    @objc private func cancelAction() {
        window?.orderOut(nil)
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
        window?.orderOut(nil)
        onSave()
    }
}
