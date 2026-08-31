//
//  Localization.swift
//  PolarisShared
//
//  Lives in the shared target because the widget needs the same lookup:
//  NSLocalizedString resolves against Bundle.main, which is the app for the
//  app and the .appex for the widget, so each bundle carries its own copy of
//  the .lproj folders and the same key works in both.
//
//  The app follows the system language: macOS picks the matching .lproj in
//  Contents/Resources on its own, so there is no language setting to expose.
//  Keys are the English source text, which means an untranslated string
//  degrades to English rather than to a missing-key placeholder.
//

import Foundation

public func L(_ key: String, _ comment: String = "") -> String {
    NSLocalizedString(key, comment: comment)
}
