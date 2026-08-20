//
//  LocalizationTests.swift
//  PolarisTests
//
//  The failure mode of a hand-maintained .strings file is silent: a missing
//  key just renders in English inside an otherwise translated menu, and
//  nobody notices until a user in that language complains. These tests make
//  it a build failure instead.
//

import XCTest
@testable import Polaris

final class LocalizationTests: XCTestCase {

    /// Package root, reached from this file rather than the working directory,
    /// which XCTest doesn't promise anything about.
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // PolarisTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // package root

    private static let languages = ["en", "da", "sv", "nb", "de", "es", "it",
                                    "nl", "fi", "fr", "pt", "pl"]

    private func keys(inLanguage lang: String) throws -> Set<String> {
        let url = Self.root
            .appendingPathComponent("Resources/\(lang).lproj/Localizable.strings")
        let data = try Data(contentsOf: url)
        let table = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: String]
        return Set((table ?? [:]).keys)
    }

    func testEveryLanguageCoversTheSameKeys() throws {
        let english = try keys(inLanguage: "en")
        XCTAssertFalse(english.isEmpty, "en.lproj failed to parse")
        for lang in Self.languages.dropFirst() {
            let translated = try keys(inLanguage: lang)
            XCTAssertEqual(english.subtracting(translated), [],
                           "\(lang) is missing translations")
            XCTAssertEqual(translated.subtracting(english), [],
                           "\(lang) has keys English doesn't")
        }
    }

    func testEveryLocalizedStringInTheSourceHasATranslation() throws {
        let sources = Self.root.appendingPathComponent("Sources/Polaris")
        let files = try FileManager.default.contentsOfDirectory(at: sources,
                                                               includingPropertiesForKeys: nil)
        // Every string literal appearing inside an L(...) call — the ternary in
        // the service row puts two of them in one call.
        // Parens inside a quoted key ("Update Available (v%@)…") must not end
        // the call, so quoted runs are matched as a unit.
        let call = try NSRegularExpression(
            pattern: #"\bL\(((?:"(?:[^"\\]|\\.)*"|[^()"])*)\)"#)
        let literal = try NSRegularExpression(pattern: #""([^"\\]*)""#)

        var used = Set<String>()
        for file in files where file.pathExtension == "swift"
            && file.lastPathComponent != "Localization.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for match in call.matches(in: text, range: range) {
                guard let args = Range(match.range(at: 1), in: text) else { continue }
                let argText = String(text[args])
                let argRange = NSRange(argText.startIndex..., in: argText)
                for lit in literal.matches(in: argText, range: argRange) {
                    if let r = Range(lit.range(at: 1), in: argText) {
                        used.insert(String(argText[r]))
                    }
                }
            }
        }

        XCTAssertFalse(used.isEmpty, "found no L() calls — the regex broke, not the app")
        let english = try keys(inLanguage: "en")
        XCTAssertEqual(used.subtracting(english), [],
                       "strings used in code but absent from Localizable.strings")
    }
}
