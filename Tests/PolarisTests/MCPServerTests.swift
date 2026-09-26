//
//  MCPServerTests.swift
//  PolarisTests
//
//  The helper answers from a snapshot, so the tests hand it one. The range
//  maths is the part worth pinning: a wrong verdict is the one failure here
//  that leaves someone at the side of a road.
//

import XCTest
import PolarisShared
@testable import PolarisMCPKit

final class MCPServerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func snapshot(battery: Double = 67, range: Int = 309, status: String = "IDLE",
                          reported: Date? = nil, written: Date? = nil,
                          odometer: Int? = 23_412) -> WidgetSnapshot {
        WidgetSnapshot(batteryPercentage: battery, rangeKm: range, statusKey: status,
                       isDriving: false, isPluggedIn: false, fullInMinutes: nil,
                       chargingPowerWatts: nil, carTitle: "Polestar 4 · 2026",
                       modelName: "Polestar 4", registrationNo: nil,
                       odometerKm: odometer,
                       carReportedAt: reported ?? now.addingTimeInterval(-600),
                       writtenAt: written ?? now.addingTimeInterval(-60),
                       unit: .kilometers, hasImage: false)
    }

    private func server(_ state: SharedStore.SnapshotState) -> MCPServer {
        MCPServer(source: { state }, now: { self.now })
    }

    private func reply(_ server: MCPServer, _ line: String) throws -> [String: Any] {
        let out = try XCTUnwrap(server.handle(line: line))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
    }

    /// The tool result is JSON inside a text block; unwrap it.
    private func toolJSON(_ response: [String: Any]) throws -> [String: Any] {
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func call(_ server: MCPServer, _ name: String, _ arguments: String = "{}") throws -> [String: Any] {
        try reply(server, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)}}"#)
    }

    // MARK: - Protocol

    func testInitializeEchoesASupportedVersion() throws {
        let r = try reply(server(.noFile), #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}"#)
        let result = try XCTUnwrap(r["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2024-11-05")
    }

    func testNotificationsGetNoReply() {
        XCTAssertNil(server(.noFile).handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
    }

    func testListsExactlyTheThreeReadOnlyTools() throws {
        let r = try reply(server(.noFile), #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let tools = try XCTUnwrap((r["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, ["get_status", "get_odometer", "check_trip"])
        for tool in tools {
            let annotations = try XCTUnwrap(tool["annotations"] as? [String: Any])
            XCTAssertEqual(annotations["readOnlyHint"] as? Bool, true)
        }
    }

    func testUnknownMethodIsAnError() throws {
        let r = try reply(server(.noFile), #"{"jsonrpc":"2.0","id":3,"method":"nope"}"#)
        XCTAssertEqual((r["error"] as? [String: Any])?["code"] as? Int, -32601)
    }

    // MARK: - Snapshot states

    func testNoSnapshotSaysPolarisHasNotFetched() throws {
        let r = try call(server(.noFile), "get_status")
        let result = try XCTUnwrap(r["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
    }

    // MARK: - Tools

    func testStatusCarriesUnitsAndBothAges() throws {
        let json = try toolJSON(call(server(.ok(snapshot())), "get_status"))
        XCTAssertEqual(json["battery_percent"] as? Double, 67)
        XCTAssertEqual(json["estimated_range_km"] as? Int, 309)
        XCTAssertEqual(json["plugged_in"] as? Bool, false)
        XCTAssertEqual(json["data_age_minutes"] as? Int, 10)
        XCTAssertEqual(json["reported_ago"] as? String, "10 min ago")
        XCTAssertNotNil(json["reported_at_local"])
        XCTAssertEqual(json["stale"] as? Bool, false)
        XCTAssertNotNil(json["polaris_last_updated"])
        XCTAssertNil(json["note"], "a fresh write needs no warning")
    }

    func testAgesAreReadableAsASentence() {
        XCTAssertEqual(MCPTools.ago(minutes: 0), "just now")
        XCTAssertEqual(MCPTools.ago(minutes: 35), "35 min ago")
        XCTAssertEqual(MCPTools.ago(minutes: 60), "1 h ago")
        XCTAssertEqual(MCPTools.ago(minutes: 537), "8 h 57 min ago")
        XCTAssertEqual(MCPTools.ago(minutes: 24 * 60 + 3 * 60), "1 d 3 h ago")
    }

    func testLocalTimeUsesTheGivenZoneNotUTC() throws {
        let cest = try XCTUnwrap(TimeZone(identifier: "Europe/Copenhagen"))
        // 10:40 UTC in late September is 12:40 in Denmark.
        let date = Date(timeIntervalSince1970: 1_790_419_200) // 2026-09-26T10:40:00Z
        XCTAssertEqual(MCPTools.local(date, timeZone: cest), "2026-09-26 12:40 GMT+2")
    }

    func testStatusFlagsAnAppThatStoppedWriting() throws {
        let old = now.addingTimeInterval(-3 * 3600)
        let json = try toolJSON(call(server(.ok(snapshot(written: old))), "get_status"))
        XCTAssertNotNil(json["note"])
    }

    func testStatusFlagsAStaleCar() throws {
        let old = now.addingTimeInterval(-7 * 3600)
        let json = try toolJSON(call(server(.ok(snapshot(reported: old))), "get_status"))
        XCTAssertEqual(json["stale"] as? Bool, true)
    }

    func testOdometer() throws {
        let json = try toolJSON(call(server(.ok(snapshot())), "get_odometer"))
        XCTAssertEqual(json["odometer_km"] as? Int, 23_412)
    }

    // MARK: - check_trip

    private func verdict(range: Int, distance: Double, back: Bool = false) throws -> [String: Any] {
        try toolJSON(call(server(.ok(snapshot(range: range))), "check_trip",
                          #"{"destination":"Aarhus","distance_km":\#(distance),"return_trip":\#(back)}"#))
    }

    func testOKWhenRangeCoversTheTripAndBuffer() throws {
        let json = try verdict(range: 309, distance: 200)   // needs 230
        XCTAssertEqual(json["verdict"] as? String, "OK")
        XCTAssertEqual(json["margin_km"] as? Double, 79)
    }

    func testTightWhenTheBufferIsEaten() throws {
        let json = try verdict(range: 309, distance: 280)   // 322 with buffer, 280 bare
        XCTAssertEqual(json["verdict"] as? String, "TIGHT")
    }

    func testNoWhenOutOfRange() throws {
        let json = try verdict(range: 309, distance: 320)
        XCTAssertEqual(json["verdict"] as? String, "NO")
        XCTAssertEqual(json["estimated_battery_at_end_percent"] as? Double, 0)
    }

    func testReturnTripDoublesTheDistance() throws {
        let json = try verdict(range: 309, distance: 200, back: true)   // 400 needed
        XCTAssertEqual(json["total_distance_km"] as? Double, 400)
        XCTAssertEqual(json["verdict"] as? String, "NO")
    }

    func testEstimatedBatteryAtTheEnd() throws {
        // Half the range used: half of 67% left, rounded.
        let json = try verdict(range: 300, distance: 150)
        XCTAssertEqual(json["estimated_battery_at_end_percent"] as? Double, 34)
    }

    func testRejectsANonPositiveDistanceBeforeReadingAnything() throws {
        let r = try call(server(.noFile), "check_trip", #"{"destination":"Aarhus","distance_km":0}"#)
        let result = try XCTUnwrap(r["result"] as? [String: Any])
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text.contains("distance_km"), "a bad call should be blamed on the call, not the car")
    }
}
