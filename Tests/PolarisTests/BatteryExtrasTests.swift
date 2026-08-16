import XCTest
@testable import Polaris

/// Covers the charging type field and the wire-format handling of 64-bit
/// values. Nothing Polaris shows is a double today, but the battery message is
/// full of them, and the parser used to drop their payloads — a field sitting
/// after one would still be misread if that regressed.
final class BatteryExtrasTests: XCTestCase {

    private enum Encoded {
        case varint(UInt64)
        case double(Double)
    }

    /// Builds a proto3 wire-format message the way the battery service would.
    private func message(_ fields: [(number: Int, value: Encoded)]) -> Data {
        var out = Data()
        for field in fields {
            switch field.value {
            case .varint(let v):
                out.append(Protobuf.varint(UInt64(field.number << 3 | 0)))
                out.append(Protobuf.varint(v))
            case .double(let d):
                out.append(Protobuf.varint(UInt64(field.number << 3 | 1)))
                withUnsafeBytes(of: d.bitPattern.littleEndian) { out.append(contentsOf: $0) }
            }
        }
        return out
    }

    func testParsesChargingFields() {
        let data = message([
            (2, .double(75)),     // battery_charge_level_percentage
            (6, .varint(1)),      // charger_connection_status = CONNECTED
            (10, .varint(11000)), // charging_power_watts
            (17, .varint(3)),     // charging_type = DC
            (18, .varint(400))    // charging_voltage_volts
        ])

        let extras = PolestarGRPC.parseBattery(data)

        XCTAssertEqual(extras.chargerConnectionStatus, "CONNECTED")
        XCTAssertEqual(extras.chargingPowerWatts, 11000)
        XCTAssertEqual(extras.chargingVoltageVolts, 400)
        XCTAssertEqual(extras.chargingType, "DC")
    }

    func testChargingTypeNoneAndUnspecifiedAreDropped() {
        for raw: UInt64 in [0, 1] {
            let extras = PolestarGRPC.parseBattery(message([(17, .varint(raw))]))
            XCTAssertNil(extras.chargingType, "raw \(raw) should not produce a row")
        }
        XCTAssertEqual(PolestarGRPC.parseBattery(message([(17, .varint(2))])).chargingType, "AC")
        XCTAssertEqual(PolestarGRPC.parseBattery(message([(17, .varint(4))])).chargingType, "WIRELESS")
    }

    /// Fields after a 64-bit one must still parse — the parser previously
    /// advanced past those eight bytes without recording them.
    func testFieldsFollowingADoubleStillParse() {
        let extras = PolestarGRPC.parseBattery(message([(2, .double(75)), (10, .varint(7200))]))
        XCTAssertEqual(extras.chargingPowerWatts, 7200)
    }

    /// A real car reported `2=75.0d`, matching the 75% the menu showed.
    func testDecodesDoublePayload() {
        let fields = Protobuf.fields(message([(2, .double(75))]))
        XCTAssertEqual(fields.first?.double ?? 0, 75, accuracy: 0.0001)
    }

    /// A varint field has no double in it, however the bytes happen to land.
    func testDoubleIsNilForOtherWireTypes() {
        XCTAssertNil(Protobuf.fields(message([(10, .varint(11000))])).first?.double)
    }
}
