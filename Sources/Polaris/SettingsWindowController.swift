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
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 240),
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
            [label("Email"), emailField],
            [label("Password"), passwordField],
            [label("VIN"), vinField],
            [label("Show in bar"), displayPopup],
            [NSGridCell.emptyContentView, launchCheckbox]
        ])
        grid.rowSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 230

        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveAction))
        saveButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelAction))

        let buttons = NSStackView(views: [cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let root = NSStackView(views: [grid, buttons])
        root.orientation = .vertical
        root.alignment = .trailing
        root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
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

        window?.orderOut(nil)
        onSave()
    }

    @objc private func cancelAction() {
        window?.orderOut(nil)
    }
}
