//
//  ClaudeDesktopConfigTests.swift
//  PolarisTests
//
//  The file being edited belongs to somebody else's app and holds the user's
//  other servers, so what is pinned here is mostly what must NOT change:
//  everything that isn't our one key, and any file we can't parse.
//

import XCTest
@testable import Polaris

final class ClaudeDesktopConfigTests: XCTestCase {

    private let helper = "/Applications/Polaris.app/Contents/MacOS/PolarisMCP"

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func servers(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(object(data)["mcpServers"] as? [String: Any])
    }

    func testAddsToAMissingOrEmptyFile() throws {
        for input in [nil, Data(), Data("  \n".utf8)] as [Data?] {
            let out = try ClaudeDesktopConfig.adding(to: input, helper: helper)
            let entry = try XCTUnwrap(servers(out)["polaris"] as? [String: Any])
            XCTAssertEqual(entry["command"] as? String, helper)
        }
    }

    func testKeepsOtherServersAndOtherSettings() throws {
        let existing = Data(#"""
        {"theme":"dark","mcpServers":{"notion":{"command":"npx","args":["-y","x"]}}}
        """#.utf8)
        let out = try ClaudeDesktopConfig.adding(to: existing, helper: helper)
        XCTAssertEqual(try object(out)["theme"] as? String, "dark")
        let all = try servers(out)
        XCTAssertEqual(Set(all.keys), ["notion", "polaris"])
        XCTAssertEqual((all["notion"] as? [String: Any])?["command"] as? String, "npx")
    }

    func testCreatesMcpServersWhenTheFileHasOnlyOtherKeys() throws {
        let out = try ClaudeDesktopConfig.adding(to: Data(#"{"theme":"dark"}"#.utf8), helper: helper)
        XCTAssertEqual(Set(try servers(out).keys), ["polaris"])
    }

    func testRefusesAFileItCannotParse() {
        XCTAssertThrowsError(try ClaudeDesktopConfig.adding(to: Data("{ not json".utf8), helper: helper)) {
            XCTAssertEqual($0 as? ClaudeDesktopConfig.ConfigError, .unreadable)
        }
        // Valid JSON, wrong shape: not ours to overwrite either.
        XCTAssertThrowsError(try ClaudeDesktopConfig.adding(to: Data("[]".utf8), helper: helper))
        XCTAssertThrowsError(try ClaudeDesktopConfig.adding(to: Data(#"{"mcpServers":[]}"#.utf8), helper: helper))
    }

    func testRunningTwiceChangesNothing() throws {
        let once = try ClaudeDesktopConfig.adding(to: nil, helper: helper)
        let twice = try ClaudeDesktopConfig.adding(to: once, helper: helper)
        // Compared as dictionaries: key order in a description is not stable.
        XCTAssertTrue(NSDictionary(dictionary: try object(once)).isEqual(to: try object(twice)))
    }

    func testRemoveTakesOnlyOurEntry() throws {
        let existing = Data(#"""
        {"mcpServers":{"notion":{"command":"npx"},"polaris":{"command":"/old"}}}
        """#.utf8)
        let out = try ClaudeDesktopConfig.removing(from: existing)
        XCTAssertEqual(Set(try servers(out).keys), ["notion"])
    }

    func testStateTellsAddedFromMovedFromMissing() throws {
        let added = try ClaudeDesktopConfig.adding(to: nil, helper: helper)
        XCTAssertEqual(ClaudeDesktopConfig.state(of: added, helper: helper), .added)
        XCTAssertEqual(ClaudeDesktopConfig.state(of: added, helper: "/Users/me/Polaris.app/Contents/MacOS/PolarisMCP"),
                       .outOfDate)
        XCTAssertEqual(ClaudeDesktopConfig.state(of: nil, helper: helper), .notAdded)
        XCTAssertEqual(ClaudeDesktopConfig.state(of: Data("garbage".utf8), helper: helper), .notAdded)
    }
}
