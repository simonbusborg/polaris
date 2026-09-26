//
//  MCPServer.swift
//  PolarisMCPKit
//
//  Just enough of the Model Context Protocol to serve three read-only tools
//  over stdio: newline-delimited JSON-RPC, initialize, tools/list and
//  tools/call. Hand-rolled rather than pulling in an SDK, because the whole
//  surface is a page and a dependency here would ship inside the app bundle.
//
//  stdout belongs to the protocol. Nothing else may print to it.
//

import Foundation
import PolarisShared

public struct MCPServer {

    /// Where the car's data comes from. A closure, so tests can hand it a
    /// snapshot instead of touching the shared container.
    public typealias Source = () -> SharedStore.SnapshotState

    let source: Source
    let now: () -> Date

    public init(source: @escaping Source = { SharedStore.snapshotState() },
                now: @escaping () -> Date = Date.init) {
        self.source = source
        self.now = now
    }

    static let supportedProtocols = ["2025-06-18", "2025-03-26", "2024-11-05"]

    // MARK: - Tool catalogue

    private static let readOnly: [String: Any] = ["readOnlyHint": true, "openWorldHint": false]

    static let tools: [[String: Any]] = [
        [
            "name": "get_status",
            "title": "Car status",
            "description": "Battery %, estimated range, charging state, charging power, time to full and whether the car is plugged in. Includes the timestamp the car last reported so staleness is visible.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
            "annotations": readOnly,
        ],
        [
            "name": "get_odometer",
            "title": "Odometer",
            "description": "Total distance driven, in km, with the timestamp of the car's last report.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
            "annotations": readOnly,
        ],
        [
            "name": "check_trip",
            "title": "Check a trip against range",
            "description": "Compares the car's current range with a trip, keeping a 15% buffer. You supply distance_km (estimate it yourself); this tool does not look up routes. Returns OK, TIGHT (within range but eats the buffer) or NO.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "destination": ["type": "string", "description": "Where the trip goes; echoed back for context only"],
                    "distance_km": ["type": "number", "exclusiveMinimum": 0, "description": "One-way distance in km"],
                    "return_trip": ["type": "boolean", "default": false, "description": "True if the car must also come back without charging"],
                ],
                "required": ["destination", "distance_km"],
            ],
            "annotations": readOnly,
        ],
    ]

    // MARK: - Dispatch

    /// One line in, at most one line out. Notifications (no id) get nothing
    /// back, which is the protocol's rule and not politeness.
    public func handle(line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return encode(error: nil, code: -32700, message: "Parse error")
        }
        let id = object["id"]
        guard let method = object["method"] as? String else {
            return id == nil ? nil : encode(error: id, code: -32600, message: "Invalid request")
        }
        // A request without an id is a notification; never answer it.
        guard let id else { return nil }

        switch method {
        case "initialize":
            let params = object["params"] as? [String: Any]
            let asked = params?["protocolVersion"] as? String
            let version = asked.flatMap { Self.supportedProtocols.contains($0) ? $0 : nil } ?? Self.supportedProtocols[0]
            return encode(result: [
                "protocolVersion": version,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "polaris", "version": "0.1.0"],
            ], id: id)
        case "ping":
            return encode(result: [String: Any](), id: id)
        case "tools/list":
            return encode(result: ["tools": Self.tools], id: id)
        case "tools/call":
            let params = object["params"] as? [String: Any] ?? [:]
            return encode(result: call(name: params["name"] as? String,
                                       arguments: params["arguments"] as? [String: Any] ?? [:]),
                          id: id)
        default:
            return encode(error: id, code: -32601, message: "Method not found")
        }
    }

    // MARK: - Tools

    func call(name: String?, arguments: [String: Any]) -> [String: Any] {
        guard let name, Self.tools.contains(where: { $0["name"] as? String == name }) else {
            return failure("Unknown tool.")
        }

        // Validate before touching the snapshot, so a bad call says what is
        // wrong with the call rather than blaming the car.
        var trip: (destination: String, distance: Double, returnTrip: Bool)?
        if name == "check_trip" {
            guard let destination = (arguments["destination"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !destination.isEmpty else {
                return failure("destination is required.")
            }
            guard let distance = (arguments["distance_km"] as? NSNumber)?.doubleValue,
                  distance > 0, distance.isFinite else {
                return failure("distance_km must be a positive number.")
            }
            trip = (destination, distance, (arguments["return_trip"] as? Bool) ?? false)
        }

        let snapshot: WidgetSnapshot
        switch source() {
        case .ok(let s):
            snapshot = s
        case .noFile:
            return failure("Polaris has not fetched anything yet. Open Polaris, sign in, and try again in a minute.")
        case .noContainer:
            return failure("This build of Polaris has no shared storage, so there is nothing to read. Install a release build.")
        case .unreadable:
            return failure("Polaris wrote data this helper cannot read. Update Polaris so the app and the helper match.")
        }

        let current = now()
        switch name {
        case "get_status": return success(MCPTools.status(snapshot, now: current))
        case "get_odometer": return success(MCPTools.odometer(snapshot, now: current))
        default:
            let t = trip!
            return success(MCPTools.tripCheck(snapshot, destination: t.destination,
                                              distanceKm: t.distance, returnTrip: t.returnTrip,
                                              now: current))
        }
    }

    private func success(_ value: [String: Any]) -> [String: Any] {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        return ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]]]
    }

    private func failure(_ message: String) -> [String: Any] {
        ["isError": true, "content": [["type": "text", "text": message]]]
    }

    // MARK: - Encoding

    private func encode(result: [String: Any], id: Any) -> String? {
        serialise(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func encode(error id: Any?, code: Int, message: String) -> String? {
        serialise(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]])
    }

    private func serialise(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Loop

    /// Reads stdin to the end. Stdout is flushed per message, because a
    /// client waiting on a buffered reply looks exactly like a hang.
    public func run() {
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let reply = handle(line: trimmed) {
                FileHandle.standardOutput.write(Data((reply + "\n").utf8))
            }
        }
    }
}
