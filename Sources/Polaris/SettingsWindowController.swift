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
    private let launchCheckbox = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)

    private let onSave: () -> Void

    init(onSave: @escaping () -> Void) {
        self.onSave = onSave

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Polaris Settings"
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
        passwordField.placeholderString = "Polestar password"
        vinField.placeholderString = "Vehicle VIN"

        displayPopup.removeAllItems()
        for option in DisplayOption.allCases {
            displayPopup.addItem(withTitle: option.rawValue)
        }

        let grid = NSGridView(views: [
            [label("Email:"), emailField],
            [label("Password:"), passwordField],
            [label("VIN:"), vinField],
            [label("Show in bar:"), displayPopup],
            [NSGridCell.emptyContentView, launchCheckbox]
        ])
        grid.rowSpacing = 12
        grid.columnSpacing = 10
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        // Text fields stretch with the window; the popup and checkbox keep
        // their natural width.
        grid.cell(for: displayPopup)?.xPlacement = .leading
        grid.cell(for: launchCheckbox)?.xPlacement = .leading
        // Extra air between the account fields and the app options.
        grid.row(at: 3).topPadding = 10
        grid.translatesAutoresizingMaskIntoConstraints = false

        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveAction))
        saveButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelAction))
        cancelButton.keyEquivalent = "\u{1b}"

        let buttons = NSStackView(views: [cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        buttons.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(grid)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
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
        emailField.stringValue = Preferences.email
        passwordField.stringValue = ((try? Keychain.readPassword()) ?? nil) ?? ""
        vinField.stringValue = Preferences.vin
        displayPopup.selectItem(withTitle: Preferences.displayOption.rawValue)
        launchCheckbox.state = Preferences.launchAtLogin ? .on : .off
    }

    // MARK: - Actions

    @objc private func saveAction() {
        Preferences.email = emailField.stringValue.trimmingCharacters(in: .whitespaces)
        Preferences.vin = vinField.stringValue.trimmingCharacters(in: .whitespaces).uppercased()
        if let title = displayPopup.titleOfSelectedItem,
           let option = DisplayOption(rawValue: title) {
            Preferences.displayOption = option
        }
        Preferences.launchAtLogin = (launchCheckbox.state == .on)

        let password = passwordField.stringValue
        if password.isEmpty {
            Keychain.deletePassword()
        } else {
            do {
                try Keychain.savePassword(password)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't save password to Keychain"
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
}
