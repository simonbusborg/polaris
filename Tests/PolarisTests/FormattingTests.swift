import XCTest
@testable import Polaris

final class FormattingTests: XCTestCase {

    func testShortDuration() {
        XCTAssertEqual(StatusItemController.shortDuration(minutes: 45), "45min")
        XCTAssertEqual(StatusItemController.shortDuration(minutes: 60), "1h")
        XCTAssertEqual(StatusItemController.shortDuration(minutes: 135), "2h15m")
    }

    func testVersionComparison() {
        XCTAssertTrue(UpdateChecker.isVersion("2.0.0", newerThan: "1.9.9"))
        XCTAssertTrue(UpdateChecker.isVersion("1.10.0", newerThan: "1.9.1"))
        XCTAssertTrue(UpdateChecker.isVersion("1.0.1", newerThan: "1.0"))
        XCTAssertFalse(UpdateChecker.isVersion("1.0.0", newerThan: "1.0.0"))
        XCTAssertFalse(UpdateChecker.isVersion("1.9.1", newerThan: "2.0.0"))
    }

    func testStatusKeyStripsPrefixes() {
        XCTAssertEqual(car(status: "CHARGING_STATUS_CHARGING").statusKey, "CHARGING")
        XCTAssertEqual(car(status: "CHARGING_STATUS_V2_SMART_CHARGING").statusKey, "SMART_CHARGING")
        XCTAssertEqual(car(status: "CHARGING_STATUS_IDLE").statusKey, "IDLE")
    }

    func testIsCharging() {
        XCTAssertTrue(car(status: "CHARGING_STATUS_CHARGING").isCharging)
        XCTAssertTrue(car(status: "CHARGING_STATUS_V2_SMART_CHARGING").isCharging)
        XCTAssertFalse(car(status: "CHARGING_STATUS_IDLE").isCharging)
        XCTAssertFalse(car(status: "CHARGING_STATUS_DONE").isCharging)
    }

    private func car(status: String) -> CarData {
        CarData(batteryPercentage: 50, rangeKm: 200,
                chargingStatus: status, estimatedChargingTimeToFullMinutes: nil,
                modelName: nil, modelYear: nil, registrationNo: nil, vin: nil,
                odometerKm: nil, daysToService: nil, distanceToServiceKm: nil,
                serviceWarning: false, fluidWarnings: [], imageData: nil,
                lastUpdated: Date())
    }
}
