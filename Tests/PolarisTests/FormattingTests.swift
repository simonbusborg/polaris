import XCTest
@testable import Polaris

final class FormattingTests: XCTestCase {

    func testShortDuration() {
        XCTAssertEqual(StatusItemController.shortDuration(minutes: 45), "45min")
        XCTAssertEqual(StatusItemController.shortDuration(minutes: 60), "1h")
        XCTAssertEqual(StatusItemController.shortDuration(minutes: 135), "2h15m")
    }

    func testBatteryColor() {
        XCTAssertEqual(StatusItemController.batteryColor(percentage: 15, charging: true), .systemGreen)
        XCTAssertEqual(StatusItemController.batteryColor(percentage: 15, charging: false), .systemOrange)
        XCTAssertEqual(StatusItemController.batteryColor(percentage: 80, charging: false), .controlAccentColor)
    }

    func testDistanceUnitConversion() {
        XCTAssertEqual(DistanceUnit.kilometers.convert(km: 412), 412)
        XCTAssertEqual(DistanceUnit.miles.convert(km: 412), 256)
        XCTAssertEqual(DistanceUnit.miles.convert(km: 0), 0)
    }

    func testDistanceFormatting() {
        XCTAssertEqual(StatusItemController.distance(km: 412, unit: .kilometers), "412 km")
        XCTAssertEqual(StatusItemController.distance(km: 412, unit: .miles), "256 mi")
        // Grouped output is locale-dependent; assert on the pieces instead.
        let grouped = StatusItemController.distance(km: 23412, grouped: true, unit: .kilometers)
        XCTAssertTrue(grouped.hasSuffix(" km"))
        XCTAssertTrue(grouped.contains("23"))
        XCTAssertTrue(grouped.contains("412"))
    }

    func testLegacyRangeDisplayOptionStillResolves() {
        UserDefaults.standard.set("Range (km)", forKey: "statusbar_display_option")
        XCTAssertEqual(Preferences.displayOption, .rangeKm)
        UserDefaults.standard.removeObject(forKey: "statusbar_display_option")
    }

    func testKilowattsFormatting() {
        XCTAssertEqual(StatusItemController.kilowatts(watts: 7200), "7.2 kW")
        XCTAssertEqual(StatusItemController.kilowatts(watts: 11000), "11 kW")
        XCTAssertEqual(StatusItemController.kilowatts(watts: 150000), "150 kW")
        XCTAssertEqual(StatusItemController.kilowatts(watts: 900), "0.9 kW")
    }

    func testProtobufVarintRoundTrip() {
        for value: UInt64 in [0, 1, 127, 128, 300, 7200, UInt64(Int32.max)] {
            let encoded = Protobuf.varint(value)
            var message = Protobuf.varint(UInt64(5 << 3 | 0))  // field 5, wire 0
            message.append(encoded)
            let fields = Protobuf.fields(message)
            XCTAssertEqual(fields.count, 1)
            XCTAssertEqual(fields.first?.number, 5)
            XCTAssertEqual(fields.first?.varint, value)
        }
    }

    func testProtobufStringFieldAndFrame() {
        let message = Protobuf.stringField(2, "LPSVSESEKML123456")
        let fields = Protobuf.fields(message)
        XCTAssertEqual(fields.first?.number, 2)
        XCTAssertEqual(fields.first.map { String(decoding: $0.data, as: UTF8.self) },
                       "LPSVSESEKML123456")

        let framed = Protobuf.grpcFrame(message)
        XCTAssertEqual(framed[0], 0)  // uncompressed
        let length = Int(framed[1]) << 24 | Int(framed[2]) << 16 | Int(framed[3]) << 8 | Int(framed[4])
        XCTAssertEqual(length, message.count)
        XCTAssertEqual(framed.count, message.count + 5)
    }

    func testGrpcBatteryParse() {
        // Battery { charger_connection_status(6)=CONNECTED,
        //           charging_power_watts(10)=7200, charging_current_amps(11)=16,
        //           charging_voltage_volts(18)=230 }
        var battery = Data()
        battery.append(Protobuf.varint(UInt64(6 << 3 | 0)));  battery.append(Protobuf.varint(1))
        battery.append(Protobuf.varint(UInt64(10 << 3 | 0))); battery.append(Protobuf.varint(7200))
        battery.append(Protobuf.varint(UInt64(11 << 3 | 0))); battery.append(Protobuf.varint(16))
        battery.append(Protobuf.varint(UInt64(18 << 3 | 0))); battery.append(Protobuf.varint(230))

        let extras = PolestarGRPC.parseBattery(battery)
        XCTAssertEqual(extras.chargerConnectionStatus, "CONNECTED")
        XCTAssertEqual(extras.chargingPowerWatts, 7200)
        XCTAssertEqual(extras.chargingCurrentAmps, 16)
        XCTAssertEqual(extras.chargingVoltageVolts, 230)
    }

    func testIsPluggedIn() {
        func car(connection: String?) -> CarData {
            CarData(batteryPercentage: 50, rangeKm: 200,
                    chargingStatus: "CHARGING_STATUS_IDLE", estimatedChargingTimeToFullMinutes: nil,
                    modelName: nil, modelYear: nil, registrationNo: nil, vin: nil,
                    ownerFirstName: nil,
                    odometerKm: nil, daysToService: nil, distanceToServiceKm: nil,
                    serviceWarning: false, fluidWarnings: [], imageData: nil,
                    lastUpdated: Date(), carReportedAt: nil,
                    grpcExtras: connection.map {
                        GrpcBatteryExtras(chargerConnectionStatus: $0, chargingPowerWatts: nil,
                                          chargingCurrentAmps: nil, chargingVoltageVolts: nil)
                    })
        }
        XCTAssertEqual(car(connection: "CONNECTED").isPluggedIn, true)
        XCTAssertEqual(car(connection: "FAULT").isPluggedIn, true)
        XCTAssertEqual(car(connection: "DISCONNECTED").isPluggedIn, false)
        XCTAssertNil(car(connection: nil).isPluggedIn)
    }

    func testMenuBarIcon() {
        func car(status: String, battery: Double, connection: String?) -> CarData {
            CarData(batteryPercentage: battery, rangeKm: 200,
                    chargingStatus: status, estimatedChargingTimeToFullMinutes: nil,
                    modelName: nil, modelYear: nil, registrationNo: nil, vin: nil,
                    ownerFirstName: nil,
                    odometerKm: nil, daysToService: nil, distanceToServiceKm: nil,
                    serviceWarning: false, fluidWarnings: [], imageData: nil,
                    lastUpdated: Date(), carReportedAt: nil,
                    grpcExtras: connection.map {
                        GrpcBatteryExtras(chargerConnectionStatus: $0, chargingPowerWatts: nil,
                                          chargingCurrentAmps: nil, chargingVoltageVolts: nil)
                    })
        }
        // Charging: filled bolted car, regardless of level.
        XCTAssertEqual(StatusItemController.icon(for: car(status: "CHARGING_STATUS_CHARGING",
                                                          battery: 15, connection: "CONNECTED")),
                       "bolt.car.fill")
        // Plugged in, not charging: bolt.
        XCTAssertEqual(StatusItemController.icon(for: car(status: "CHARGING_STATUS_IDLE",
                                                          battery: 15, connection: "CONNECTED")),
                       "bolt.car")
        // Unplugged: plain car, regardless of level. Unknown plug state too.
        XCTAssertEqual(StatusItemController.icon(for: car(status: "CHARGING_STATUS_IDLE",
                                                          battery: 15, connection: "DISCONNECTED")),
                       "car")
        XCTAssertEqual(StatusItemController.icon(for: car(status: "CHARGING_STATUS_IDLE",
                                                          battery: 80, connection: nil)),
                       "car")
        // No data yet.
        XCTAssertEqual(StatusItemController.icon(for: nil), "car")
    }

    func testVersionComparison() {
        XCTAssertTrue(UpdateChecker.isVersion("2.0.0", newerThan: "1.9.9"))
        XCTAssertTrue(UpdateChecker.isVersion("1.10.0", newerThan: "1.9.1"))
        XCTAssertTrue(UpdateChecker.isVersion("1.0.1", newerThan: "1.0"))
        XCTAssertFalse(UpdateChecker.isVersion("1.0.0", newerThan: "1.0.0"))
        XCTAssertFalse(UpdateChecker.isVersion("1.9.1", newerThan: "2.0.0"))
    }

    func testGreetingUsesSystemLanguage() {
        XCTAssertEqual(StatusItemController.greeting("Simon", languageCode: "da-DK"), "Hej, Simon")
        XCTAssertEqual(StatusItemController.greeting("Simon", languageCode: "en-US"), "Hi, Simon")
        XCTAssertEqual(StatusItemController.greeting("Simon", languageCode: "xx"), "Hi, Simon")
        XCTAssertEqual(StatusItemController.greeting("Simon", languageCode: nil), "Hi, Simon")
    }

    func testDemoVinAliasesRealVin() {
        XCTAssertEqual(PolestarAPI.apiVin("DEMO-YSM4ZPAA9TF452140"), "YSM4ZPAA9TF452140")
        XCTAssertEqual(PolestarAPI.apiVin("YSM4ZPAA9TF452140"), "YSM4ZPAA9TF452140")
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
                ownerFirstName: nil,
                odometerKm: nil, daysToService: nil, distanceToServiceKm: nil,
                serviceWarning: false, fluidWarnings: [], imageData: nil,
                lastUpdated: Date(), carReportedAt: nil, grpcExtras: nil)
    }
}
