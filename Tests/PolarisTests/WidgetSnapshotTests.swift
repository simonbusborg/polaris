//
//  WidgetSnapshotTests.swift
//  PolarisTests
//
//  The snapshot is a file format shared by two processes, which makes it the
//  one place where a silent change breaks something nobody is looking at:
//  the app keeps working perfectly while the widget quietly shows nothing.
//

import XCTest
import PolarisShared

final class WidgetSnapshotTests: XCTestCase {

    private func snapshot(battery: Double = 78, driving: Bool = false,
                          status: String = "IDLE",
                          unit: DistanceUnit = .kilometers,
                          written: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> WidgetSnapshot {
        WidgetSnapshot(batteryPercentage: battery, rangeKm: 412, statusKey: status,
                       isDriving: driving, isPluggedIn: false, fullInMinutes: nil,
                       chargingPowerWatts: nil, carTitle: "Polestar 4 · 2026",
                       modelName: "Polestar 4", registrationNo: "AB12345",
                       odometerKm: 23412, carReportedAt: nil, writtenAt: written,
                       unit: unit, hasImage: false)
    }

    func testSurvivesARoundTrip() throws {
        let original = snapshot()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(WidgetSnapshot.self,
                                          from: encoder.encode(original))
        XCTAssertEqual(restored, original)
    }

    /// A poll that changed nothing must not cost a widget reload, but a poll
    /// that moved the battery must.
    func testSameDataIgnoresOnlyTheWriteTime() {
        let first = snapshot()
        let later = snapshot(written: Date(timeIntervalSince1970: 1_700_003_600))
        XCTAssertTrue(later.sameData(as: first))
        XCTAssertFalse(snapshot(battery: 77).sameData(as: first))
    }

    /// Charging status stays IDLE while the car is moving, so driving has to
    /// win — the same inference the menu bar makes.
    func testDrivingOutranksTheChargingStatus() {
        XCTAssertEqual(snapshot(driving: true).statusText, "In use")
        XCTAssertEqual(snapshot().statusText, "Idle")
        XCTAssertEqual(snapshot(status: "CHARGING").statusText, "Charging")
    }

    func testRangeFollowsTheUnitTheAppWrote() {
        XCTAssertEqual(snapshot().rangeText, "412 km")
        XCTAssertEqual(snapshot(unit: .miles).rangeText, "256 mi")
    }

    func testChargingCoversSmartCharging() {
        XCTAssertTrue(snapshot(status: "SMART_CHARGING").isCharging)
        XCTAssertFalse(snapshot(status: "DONE").isCharging)
    }
}
