import XCTest
@testable import Polaris

/// The Data Portal speaks the same protobuf-derived JSON as the GraphQL API,
/// with the same two quirks: int64s arrive as strings, and enums carry their
/// type name as a prefix. These pin the mapping into `CarData`'s shapes so a
/// captured response can be replayed without a credential or a network.
final class DataPortalTests: XCTestCase {

    private let battery: [String: Any] = [
        "batteryChargeLevelPercentage": 72.5,
        "estimatedDistanceToEmptyKm": 310,
        "chargingStatusV2": "CHARGING_STATUS_CHARGING",
        "estimatedChargingTimeToFullMinutes": 42,
        "chargerConnectionStatus": "CHARGER_CONNECTION_STATUS_CONNECTED",
        "chargingPowerWatts": 10800,
        "chargingCurrentAmps": 16,
        "chargingVoltageVolts": "400",
        "chargingType": "CHARGING_TYPE_AC",
        "timestamp": ["seconds": "1789741417", "nanos": 962000000]
    ]

    func testMapsBatteryIntoTelemetry() {
        let t = PolestarDataPortal.telemetry(battery: battery, odometer: nil, health: nil)
        XCTAssertEqual(t.batteryPercentage, 72.5)
        XCTAssertEqual(t.rangeKm, 310)
        XCTAssertEqual(t.chargingStatus, "CHARGING_STATUS_CHARGING")
        XCTAssertEqual(t.estimatedChargingTimeToFullMinutes, 42)
        XCTAssertEqual(t.carReportedAt?.timeIntervalSince1970, 1_789_741_417)
        XCTAssertEqual(t.extras.chargerConnectionStatus, "CONNECTED")
        XCTAssertEqual(t.extras.chargingPowerWatts, 10800)
        XCTAssertEqual(t.extras.chargingCurrentAmps, 16)
        XCTAssertEqual(t.extras.chargingVoltageVolts, 400)   // string int64
        XCTAssertEqual(t.extras.chargingType, "AC")
        XCTAssertNil(t.odometerMeters)
        XCTAssertFalse(t.serviceWarning)
        XCTAssertEqual(t.fluidWarnings, [])
    }

    func testOdometerAndHealthAreOptionalExtras() {
        let odometer: [String: Any] = [
            "odometerMeters": "45120500",
            "timestamp": ["seconds": 1_789_741_000]
        ]
        let health: [String: Any] = [
            "daysToService": 120,
            "distanceToServiceKm": 8000,
            "serviceWarning": "SERVICE_WARNING_REGULAR_MAINTENANCE_ALMOST_TIME_FOR_SERVICE",
            "brakeFluidLevelWarning": "BRAKE_FLUID_LEVEL_WARNING_NO_WARNING",
            "oilLevelWarning": "OIL_LEVEL_WARNING_TOO_LOW"
        ]
        let t = PolestarDataPortal.telemetry(battery: battery, odometer: odometer, health: health)
        XCTAssertEqual(t.odometerMeters, 45_120_500)
        XCTAssertEqual(t.odometerReportedAt?.timeIntervalSince1970, 1_789_741_000)
        XCTAssertEqual(t.daysToService, 120)
        XCTAssertEqual(t.distanceToServiceKm, 8000)
        XCTAssertTrue(t.serviceWarning)
        XCTAssertEqual(t.fluidWarnings, ["Oil too low"])
    }

    /// A parked car says NONE for the charging type and UNSPECIFIED for the
    /// charger; neither deserves a row, so both map to nil like the gRPC path.
    func testIdleEnumsDropToNil() {
        var idle = battery
        idle["chargingType"] = "CHARGING_TYPE_NONE"
        idle["chargerConnectionStatus"] = "CHARGER_CONNECTION_STATUS_UNSPECIFIED"
        idle["chargingStatusV2"] = "CHARGING_STATUS_IDLE"
        let extras = PolestarDataPortal.extras(from: idle)
        XCTAssertNil(extras.chargingType)
        XCTAssertNil(extras.chargerConnectionStatus)
    }

    func testTokenResponseUsesCamelCase() {
        let ok = PolestarDataPortal.parseToken(["accessToken": "abc", "expiresIn": 3600, "tokenType": "Bearer"])
        XCTAssertEqual(ok?.token, "abc")
        XCTAssertEqual(ok?.expiresIn, 3600)
        // The RFC spelling is not what this endpoint returns; refuse it
        // loudly rather than proceeding with an empty token.
        XCTAssertNil(PolestarDataPortal.parseToken(["access_token": "abc", "expires_in": 3600]))
    }

    func testCredentialsRoundTripAsJSON() throws {
        let c = DataPortalCredentials(clientId: "id", clientSecret: "s3cret", accountId: "acct")
        let data = try JSONEncoder().encode(c)
        XCTAssertEqual(try JSONDecoder().decode(DataPortalCredentials.self, from: data), c)
        XCTAssertFalse(DataPortalCredentials(clientId: "id", clientSecret: "", accountId: "acct").isComplete)
    }
}
