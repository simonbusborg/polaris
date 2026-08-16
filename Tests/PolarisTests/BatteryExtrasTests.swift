import XCTest
@testable import Polaris

/// Covers the gRPC battery fields Polaris reads beyond charge level: the
/// charging type and the average consumption double. The double is the
/// interesting one — it is the first wire-type-1 field the parser has had to
/// hand back rather than skip.
final class BatteryExtrasTests: XCTestCase {

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

    private enum Encoded {
        case varint(UInt64)
        case double(Double)
    }

    func testParsesChargingTypeAndConsumption() {
        let data = message([
            (3, .double(18.4)),   // average_energy_consumption_kwh_per_100_km
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
        XCTAssertEqual(extras.averageConsumptionKwhPer100Km ?? 0, 18.4, accuracy: 0.0001)
    }

    func testChargingTypeNoneAndUnspecifiedAreDropped() {
        for raw: UInt64 in [0, 1] {
            let extras = PolestarGRPC.parseBattery(message([(17, .varint(raw))]))
            XCTAssertNil(extras.chargingType, "raw \(raw) should not produce a row")
        }
        XCTAssertEqual(PolestarGRPC.parseBattery(message([(17, .varint(2))])).chargingType, "AC")
        XCTAssertEqual(PolestarGRPC.parseBattery(message([(17, .varint(4))])).chargingType, "WIRELESS")
    }

    /// A car with no consumption history reports 0.0, which must not render as
    /// a confident "0.0 kWh/100km".
    func testZeroConsumptionIsTreatedAsAbsent() {
        XCTAssertNil(PolestarGRPC.parseBattery(message([(3, .double(0))])).averageConsumptionKwhPer100Km)
    }

    /// Fields after a 64-bit one must still parse — the parser previously
    /// skipped those eight bytes without recording them.
    func testFieldsFollowingADoubleStillParse() {
        let extras = PolestarGRPC.parseBattery(message([(3, .double(21.7)), (10, .varint(7200))]))
        XCTAssertEqual(extras.chargingPowerWatts, 7200)
    }

    func testConsumptionFormatting() {
        XCTAssertEqual(StatusItemController.consumption(kwhPer100Km: 18.4, unit: .kilometers),
                       "18.4 kWh/100km")
        // 18.4 kWh per 100 km is 29.6 kWh per 100 miles.
        XCTAssertEqual(StatusItemController.consumption(kwhPer100Km: 18.4, unit: .miles),
                       "29.6 kWh/100mi")
    }
}
