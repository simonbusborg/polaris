//
//  Updater.swift
//  Polaris (AppKit rewrite)
//
//  In-app updates via Sparkle. The feed is an appcast published to GitHub
//  Pages and signed with an EdDSA key; Sparkle refuses anything whose
//  signature or Developer ID doesn't match, so a tampered feed can't push
//  a build at anyone.
//
//  Like notifications, none of this works outside a real .app bundle —
//  under `swift run` there is nothing to update, so the updater isn't
//  started at all.
//

import Foundation
import Sparkle

final class Updater {

    private let controller: SPUStandardUpdaterController?

    init() {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            controller = nil
            return
        }
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
    }

    /// False under `swift run`, where the menu item is pointless.
    var isAvailable: Bool { controller != nil }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// Sparkle owns these two settings — they live in its own defaults keys,
    /// not in `Preferences`, so that Sparkle's background scheduler and the
    /// checkboxes in Settings can never disagree about what's on.
    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloads: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }
}
