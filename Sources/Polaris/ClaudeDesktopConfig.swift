//
//  ClaudeDesktopConfig.swift
//  Polaris
//
//  Adds and removes Polaris's entry in Claude Desktop's settings file, so
//  nobody has to edit JSON by hand. The file is the user's and holds their
//  other servers, so the rule throughout is: change our one key or change
//  nothing. A file that doesn't parse is left exactly as it was, because
//  "fixing" someone else's config is how their other tools stop working.
//
//  Polaris is not sandboxed, which is the only reason it can reach another
//  app's Application Support folder at all.
//

import Foundation

enum ClaudeDesktopConfig {

    static let serverName = "polaris"

    enum State: Equatable {
        case notAdded
        case added
        /// There is an entry but it names a helper that is no longer where
        /// the app is — Polaris was moved or reinstalled elsewhere.
        case outOfDate
    }

    enum ConfigError: Error, Equatable {
        case claudeNotInstalled
        /// The file exists but isn't a JSON object we can safely merge into.
        case unreadable
    }

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
    }

    static var url: URL { directory.appendingPathComponent("claude_desktop_config.json") }

    /// The helper inside the running bundle, or nil under `swift run`, where
    /// there is no bundle and so no stable path to hand to another app.
    static var helperPath: String? {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return nil }
        let helper = bundle.appendingPathComponent("Contents/MacOS/PolarisMCP").path
        return FileManager.default.isExecutableFile(atPath: helper) ? helper : nil
    }

    // MARK: - Pure merging (no I/O, so it is testable without a Claude install)

    private static func parse(_ data: Data?) throws -> [String: Any] {
        guard let data, !data.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigError.unreadable
        }
        return object
    }

    private static func servers(in root: [String: Any]) throws -> [String: Any] {
        guard let existing = root["mcpServers"] else { return [:] }
        // A key that is there but not an object is somebody's mistake or a
        // format we don't know; either way it is not ours to overwrite.
        guard let dict = existing as? [String: Any] else { throw ConfigError.unreadable }
        return dict
    }

    private static func serialise(_ root: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: root,
                                   options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    static func state(of data: Data?, helper: String) -> State {
        guard let root = try? parse(data),
              let entry = (try? servers(in: root))?[serverName] as? [String: Any] else {
            return .notAdded
        }
        return (entry["command"] as? String) == helper ? .added : .outOfDate
    }

    static func adding(to data: Data?, helper: String) throws -> Data {
        var root = try parse(data)
        var all = try servers(in: root)
        all[serverName] = ["command": helper]
        root["mcpServers"] = all
        return try serialise(root)
    }

    static func removing(from data: Data?) throws -> Data {
        var root = try parse(data)
        var all = try servers(in: root)
        all.removeValue(forKey: serverName)
        // Leave an empty mcpServers behind rather than deleting the key: the
        // user may have put it there themselves.
        if root["mcpServers"] != nil { root["mcpServers"] = all }
        return try serialise(root)
    }

    // MARK: - Disk

    private static func current() -> Data? {
        try? Data(contentsOf: url)
    }

    static func currentState(helper: String) -> State {
        state(of: current(), helper: helper)
    }

    static func install(helper: String) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw ConfigError.claudeNotInstalled
        }
        let existing = current()
        let updated = try adding(to: existing, helper: helper)
        try backUp(existing)
        try updated.write(to: url, options: .atomic)
    }

    static func remove() throws {
        guard let existing = current() else { return }
        let updated = try removing(from: existing)
        try backUp(existing)
        try updated.write(to: url, options: .atomic)
    }

    /// One backup, made the first time we touch the file and never replaced:
    /// a second run would otherwise overwrite the user's original with a copy
    /// that already contains our entry.
    private static func backUp(_ existing: Data?) throws {
        guard let existing, !existing.isEmpty else { return }
        let backup = url.appendingPathExtension("polaris-backup")
        if !FileManager.default.fileExists(atPath: backup.path) {
            try existing.write(to: backup, options: .atomic)
        }
    }
}
