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
        XCTAssertEqual(t.tyreWarnings, [])
        XCTAssertFalse(t.batteryWarning)
    }

    func testTyreAndBatteryWarnings() {
        let health: [String: Any] = [
            "tyrePressureWarningFrontLeft": "TYRE_PRESSURE_WARNING_FRONT_LEFT_LOW",
            "tyrePressureWarningFrontRight": "TYRE_PRESSURE_WARNING_FRONT_RIGHT_NO_WARNING",
            "tyrePressureWarningRearLeft": "TYRE_PRESSURE_WARNING_REAR_LEFT_NO_WARNING",
            "tyrePressureWarningRearRight": "TYRE_PRESSURE_WARNING_REAR_RIGHT_LOW",
            "twelveVoltBatteryWarning": "TWELVE_VOLT_BATTERY_WARNING_LOW_VOLTAGE"
        ]
        let t = PolestarDataPortal.telemetry(battery: battery, odometer: nil, health: health)
        XCTAssertEqual(t.tyreWarnings, ["Front left", "Rear right"])
        XCTAssertTrue(t.batteryWarning)
    }

    func testNoWarningAndUnspecifiedTyresDontAppear() {
        let health: [String: Any] = [
            "tyrePressureWarningFrontLeft": "TYRE_PRESSURE_WARNING_FRONT_LEFT_NO_WARNING",
            "tyrePressureWarningFrontRight": "TYRE_PRESSURE_WARNING_FRONT_RIGHT_UNSPECIFIED",
            "twelveVoltBatteryWarning": "TWELVE_VOLT_BATTERY_WARNING_NO_WARNING"
        ]
        let t = PolestarDataPortal.telemetry(battery: battery, odometer: nil, health: health)
        XCTAssertEqual(t.tyreWarnings, [])
        XCTAssertFalse(t.batteryWarning)
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

    func testCredentialsSavedBeforeExpiryDatesStillDecode() throws {
        let old = Data(#"{"clientId":"id","clientSecret":"s3cret","accountId":"acct"}"#.utf8)
        let c = try JSONDecoder().decode(DataPortalCredentials.self, from: old)
        XCTAssertNil(c.expiresAt)
        XCTAssertFalse(c.isExpired())
    }
}

final class CredentialExpiryTests: XCTestCase {

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Copenhagen")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    func testDefaultExpiryIsNinetyDaysFromTheSaveDay() {
        let expiry = CredentialExpiry.defaultExpiry(savedAt: date(2026, 9, 27, 22), calendar: calendar)
        XCTAssertEqual(expiry, date(2026, 12, 26, 0))
    }

    func testDaysLeftCountsCalendarDays() {
        let expiry = date(2026, 12, 26, 0)
        XCTAssertEqual(CredentialExpiry.daysLeft(until: expiry, now: date(2026, 12, 25, 23), calendar: calendar), 1)
        XCTAssertEqual(CredentialExpiry.daysLeft(until: expiry, now: date(2026, 12, 26, 8), calendar: calendar), 0)
        XCTAssertEqual(CredentialExpiry.daysLeft(until: expiry, now: date(2026, 12, 28), calendar: calendar), -2)
    }

    func testRemindersFireAWeekAheadAndOnTheDay() {
        let r = CredentialExpiry.reminders(for: date(2026, 12, 26, 0), now: date(2026, 10, 29), calendar: calendar)
        XCTAssertEqual(r.map { $0.0 }, [.weekBefore, .onTheDay])
        XCTAssertEqual(r.map { $0.1 }, [date(2026, 12, 19, 9), date(2026, 12, 26, 9)])
    }

    func testRemindersAlreadyPastAreDropped() {
        let expiry = date(2026, 12, 26, 0)
        XCTAssertEqual(CredentialExpiry.reminders(for: expiry, now: date(2026, 12, 21), calendar: calendar).map { $0.0 },
                       [.onTheDay])
        XCTAssertTrue(CredentialExpiry.reminders(for: expiry, now: date(2026, 12, 26, 10), calendar: calendar).isEmpty)
    }

    func testARefusedCredentialPastItsDateReadsAsExpired() {
        var c = DataPortalCredentials(clientId: "id", clientSecret: "s", accountId: "a")
        c.expiresAt = Date().addingTimeInterval(-60)
        XCTAssertTrue(c.isExpired())
        c.expiresAt = Date().addingTimeInterval(86_400)
        XCTAssertFalse(c.isExpired())
    }
}

/// The domains added after battery: each maps into its own small struct on
/// `CarData`, and each is optional because a scope may not be granted.
final class DataPortalDomainTests: XCTestCase {

    func testAvailabilityUsageModeIsStripped() {
        let t = PolestarDataPortal.telemetry(battery: [:], odometer: nil, health: nil,
                                             availability: ["usageMode": "USAGE_MODE_DRIVING"])
        XCTAssertEqual(t.usageMode, "DRIVING")
    }

    func testClimateRunning() {
        let climate = PolestarDataPortal.climate(from: [
            "runningStatus": "RUNNING_STATUS_ON",
            "ventilation": "VENTILATION_HEATING",
            "currentCompartmentTemperatureCelsius": 12.5,
            "requestedCompartmentTemperatureCelsius": 21,
            "runtimeLeftMinutes": 18,
            "errors": ["ERROR_TYPE_UNSPECIFIED"],
            "warnings": ["WARNING_TYPE_RUN_TIME_NEARING_LIMIT"],
            "timestamp": ["seconds": "1789741417"]
        ])
        XCTAssertEqual(climate?.isRunning, true)
        XCTAssertEqual(climate?.ventilation, "HEATING")
        XCTAssertEqual(climate?.currentCelsius, 12.5)
        XCTAssertEqual(climate?.requestedCelsius, 21)
        XCTAssertEqual(climate?.minutesLeft, 18)
        // UNSPECIFIED is noise, the warning is not.
        XCTAssertEqual(climate?.problems, ["RUN_TIME_NEARING_LIMIT"])
    }

    func testClimateWithoutStatusIsAbsent() {
        XCTAssertNil(PolestarDataPortal.climate(from: ["ventilation": "VENTILATION_NEUTRAL"]))
    }

    func testExteriorOpeningsInMenuOrder() {
        let exterior = PolestarDataPortal.exterior(from: [
            "centralLock": "LOCK_STATUS_UNLOCKED",
            "tailgate": "OPEN_STATUS_OPEN",
            "frontLeftDoor": "OPEN_STATUS_AJAR",
            "rearLeftWindow": "OPEN_STATUS_CLOSED",
            "sunroof": "OPEN_STATUS_UNSPECIFIED",
            "alarm": "ALARM_STATUS_IDLE"
        ])
        XCTAssertEqual(exterior?.locked, false)
        XCTAssertEqual(exterior?.openings, ["frontLeftDoor", "tailgate"])
        XCTAssertEqual(exterior?.alarmTriggered, false)
    }

    func testExteriorFromAModelThatDoesNotReportItIsAbsent() {
        XCTAssertNil(PolestarDataPortal.exterior(from: ["vin": "X"]))
    }

    func testLocationNeedsARealCoordinate() {
        let here = PolestarDataPortal.location(from: [
            "coordinate": ["latitude": 55.6761, "longitude": 12.5683],
            "heading": 270,
            "timestamp": ["seconds": "1789741417"]
        ])
        XCTAssertEqual(here?.latitude, 55.6761)
        XCTAssertEqual(here?.heading, 270)
        XCTAssertNil(PolestarDataPortal.location(from: ["coordinate": ["latitude": 0, "longitude": 0]]))
        XCTAssertNil(PolestarDataPortal.location(from: [:]))
    }

    func testTargetSocIsNested() {
        let t = PolestarDataPortal.telemetry(battery: [:], odometer: nil, health: nil,
                                             targetSoc: ["targetSoc": ["batteryChargeTargetLevel": 80]])
        XCTAssertEqual(t.targetSoc, 80)
    }
}
