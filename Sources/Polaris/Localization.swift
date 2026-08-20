//
//  Localization.swift
//  Polaris (AppKit rewrite)
//
//  The app follows the system language: macOS picks the matching .lproj in
//  Contents/Resources on its own, so there is no language setting to expose.
//  Keys are the English source text, which means an untranslated string
//  degrades to English rather than to a missing-key placeholder.
//

import Foundation

func L(_ key: String, _ comment: String = "") -> String {
    NSLocalizedString(key, comment: comment)
}
