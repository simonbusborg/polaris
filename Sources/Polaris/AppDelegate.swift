//
//  AppDelegate.swift
//  Polaris (AppKit rewrite)
//

import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusController: StatusItemController!
    private var settingsController: SettingsWindowController?

    private let api = PolestarAPI()
    private let notifier = Notifier()
    private let updateChecker = UpdateChecker()
    private var refreshTimer: Timer?
    private var latest: CarData?
    private var lastError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        Preferences.migrateLegacyPassword()

        statusController = StatusItemController(
            onRefresh: { [weak self] in self?.refreshNow() },
            onSettings: { [weak self] in self?.showSettings() }
        )
        statusController.onSelectCar = { [weak self] vin in self?.switchCar(to: vin) }
        statusController.render(data: nil, error: nil, authenticated: false)
        notifier.requestAuthorizationIfNeeded()
        updateChecker.checkIfDue { [weak self] version in
            guard let self else { return }
            self.statusController.updateVersion = version
            self.statusController.render(data: self.latest, error: self.lastError,
                                         authenticated: self.api.isAuthenticated)
        }

        if hasCredentials {
            startSession()
        } else {
            showSettings()
        }
    }

    /// Menu-bar-only apps have no visible main menu, but key equivalents
    /// (⌘C/⌘V/⌘X/⌘A/⌘Z) are routed through NSApp.mainMenu — without an
    /// Edit menu, paste doesn't work in our settings window.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("Quit Polaris"),
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: L("Edit"))
        editMenu.addItem(withTitle: L("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: L("Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private var hasCredentials: Bool {
        guard !Preferences.email.isEmpty, !Preferences.vin.isEmpty else { return false }
        return ((try? Keychain.readPassword()) ?? nil)?.isEmpty == false
    }

    // MARK: - Session lifecycle

    func startSession() {
        guard hasCredentials,
              let pass = try? Keychain.readPassword()
        else {
            statusController.render(data: nil, error: L("Not configured"), authenticated: false)
            showSettings()
            return
        }
        let email = Preferences.email
        let vin = Preferences.vin

        // Ad-hoc builds have no stable code-signing identity, so the item a
        // previous version created triggers a keychain prompt once. Re-saving
        // after a successful read rebinds it to this binary — later launches
        // of this version read silently.
        try? Keychain.savePassword(pass)

        statusController.showLoading()
        Task {
            do {
                // Resume the stored session when possible; only replay the
                // full scripted password login when that fails.
                do {
                    try await api.restoreSession(vin: vin)
                } catch {
                    try await api.authenticate(email: email, password: pass, vin: vin)
                }
                let data = try await api.fetchCarData(vin: vin)
                await MainActor.run { self.apply(data) }
            } catch {
                await MainActor.run {
                    self.lastError = error.localizedDescription
                    self.statusController.render(data: self.latest, error: error.localizedDescription, authenticated: false)
                    // A dead session is "not signed in", not a transient
                    // error: open Settings so the fix is in reach instead
                    // of only an error row in the menu.
                    if Self.isSignedOut(error) { self.showSettings() }
                }
            }
        }
    }

    /// True when the session is gone rather than the network being flaky —
    /// no stored credentials, or Polestar rejecting the login.
    static func isSignedOut(_ error: Error) -> Bool {
        switch error {
        case PolestarError.notConfigured, PolestarError.authenticationFailed:
            return true
        default:
            return false
        }
    }

    func refreshNow() {
        guard api.isAuthenticated else { startSession(); return }
        let vin = Preferences.vin
        Task {
            do {
                let data = try await api.fetchCarData(vin: vin)
                await MainActor.run { self.apply(data) }
            } catch {
                await MainActor.run {
                    self.lastError = error.localizedDescription
                    self.statusController.render(data: self.latest, error: error.localizedDescription, authenticated: true)
                }
            }
        }
    }

    private func apply(_ data: CarData) {
        notifier.carDataDidUpdate(old: latest, new: data)
        latest = data
        lastError = nil
        statusController.cars = api.cars
        statusController.activeVin = Preferences.vin
        statusController.render(data: data, error: nil, authenticated: true)
        scheduleRefresh()
    }

    /// Point the app at another of the account's cars: persist the VIN,
    /// refetch identity + image, then reload live data.
    private func switchCar(to vin: String) {
        Preferences.vin = vin
        latest = nil   // old car's data must not seed notifications
        statusController.showLoading()
        Task {
            await api.selectCar(vin: vin)
            await MainActor.run { self.refreshNow() }
        }
    }

    /// Poll every minute while charging or driving (the numbers actually move,
    /// and a short cycle keeps "In use" from lingering after parking),
    /// every 5 minutes otherwise.
    private func scheduleRefresh() {
        let interval: TimeInterval = (latest?.isCharging == true || latest?.isDriving == true) ? 60 : 300
        if let timer = refreshTimer, timer.isValid, timer.timeInterval == interval { return }
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshNow()
        }
    }

    // MARK: - Settings

    func showSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController { [weak self] in
                self?.applyLaunchAtLogin()
                self?.startSession()
            }
        }
        settingsController?.show()
    }

    private func applyLaunchAtLogin() {
        // SMAppService only works from a real .app bundle (make app),
        // not when running the bare binary via `swift run`.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        do {
            if Preferences.launchAtLogin {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            NSLog("Launch-at-login change failed: \(error.localizedDescription)")
        }
    }
}
