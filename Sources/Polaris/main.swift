//
//  main.swift
//  Polaris (AppKit rewrite)
//
//  Pure AppKit menu bar app — no SwiftUI, no storyboards.
//

import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Accessory: no Dock icon, menu bar only.
app.setActivationPolicy(.accessory)
app.run()
