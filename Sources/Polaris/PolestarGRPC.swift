//
//  PolestarGRPC.swift
//  Polaris (AppKit rewrite)
//
//  Best-effort client for the Volvo/Polestar gRPC battery service — the
//  data the mystar-v2 GraphQL migration dropped (charger connection,
//  charging power/current/voltage) still lives here. Same Polestar ID
//  bearer token as the GraphQL API.
//
//  No gRPC library: a unary gRPC call is an HTTP/2 POST whose body is a
//  5-byte frame header plus a protobuf message, and URLSession speaks
//  HTTP/2 natively. The response is read as a byte stream so we can stop
//  after the first message frame instead of waiting for HTTP/2 trailers
//  (which URLSession never surfaces anyway).
//
//  Protocol shapes reconstructed by the pypolestar project from the
//  Polestar Android app (see pypolestar/proto).
//

import Foundation

/// The extra battery fields the gRPC service knows about. All optional —
/// every consumer must degrade gracefully when the service is unreachable.
struct GrpcBatteryExtras {
    /// "CONNECTED", "DISCONNECTED" or "FAULT" (UNSPECIFIED is dropped).
    let chargerConnectionStatus: String?
    let chargingPowerWatts: Int?
    let chargingCurrentAmps: Int?
    let chargingVoltageVolts: Int?
    /// "AC", "DC" or "WIRELESS". NONE and UNSPECIFIED both map to nil — the
    /// car reports NONE whenever it isn't charging, which is not worth a row.
    let chargingType: String?
}

final class PolestarGRPC {

    private let discoveryURL = URL(string: "https://cnepmob.volvocars.com")!
    private let batteryPath = "/services.vehiclestates.battery.BatteryService/GetLatestBattery"

    private var c3BaseURL: URL?
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
    }

    // MARK: - Public

    func fetchBattery(vin: String, accessToken: String) async throws -> GrpcBatteryExtras {
        let base = try await c3Host()
        var request = URLRequest(url: base.appendingPathComponent(batteryPath))
        request.httpMethod = "POST"
        request.setValue("application/grpc", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(vin, forHTTPHeaderField: "vin")

        // GetBatteryRequest { id = 1 (a fresh UUID), vin = 2 }
        var message = Data()
        message.append(Protobuf.stringField(1, UUID().uuidString))
        message.append(Protobuf.stringField(2, vin))
        request.httpBody = Protobuf.grpcFrame(message)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw PolestarError.http("gRPC battery HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        // gRPC errors come back as HTTP 200 with a grpc-status header/trailer
        // and no message frame; header-borne status is visible here.
        if let status = http.value(forHTTPHeaderField: "grpc-status"), status != "0" {
            throw PolestarError.http("gRPC status \(status)")
        }

        // Read exactly one frame: 1 flag byte + 4-byte big-endian length.
        var header = [UInt8]()
        var body = Data()
        var expected = -1
        for try await byte in bytes {
            if header.count < 5 {
                header.append(byte)
                if header.count == 5 {
                    guard header[0] == 0 else {
                        throw PolestarError.parse("gRPC: compressed frame not supported")
                    }
                    expected = Int(header[1]) << 24 | Int(header[2]) << 16
                             | Int(header[3]) << 8 | Int(header[4])
                    if expected == 0 { break }
                }
                continue
            }
            body.append(byte)
            if body.count == expected { break }
        }
        guard expected >= 0, body.count == expected else {
            throw PolestarError.parse("gRPC: truncated response frame")
        }

        // GetBatteryResponse { id = 1, vin = 2, battery = 3 }
        guard let batteryBytes = Protobuf.fields(body).first(where: { $0.number == 3 && $0.wire == 2 })?.data
        else { throw PolestarError.parse("gRPC: no battery in response") }
        Self.dumpFieldsIfDebugging(batteryBytes)
        return Self.parseBattery(batteryBytes)
    }

    // MARK: - Internals

    /// The battery service host is discovered, not fixed — Volvo's cnepmob
    /// endpoint hands out the current C3 gRPC host and port.
    private func c3Host() async throws -> URL {
        if let cached = c3BaseURL { return cached }
        var request = URLRequest(url: discoveryURL)
        request.setValue("application/volvo.cloud.cnepmob.v1+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let c3 = json["c3"] as? [String: Any],
              let host = c3["grpcHost"] as? String,
              let port = c3["grpcPort"] as? Int,
              let url = URL(string: "https://\(host):\(port)")
        else { throw PolestarError.parse("C3 discovery failed") }
        c3BaseURL = url
        return url
    }

    /// Developer aid: `defaults write com.weareheavy.polaris debug_grpc_fields
    /// -bool YES` logs which fields the battery message actually carries, so a
    /// missing row can be told apart from a field we read from the wrong
    /// number. Numbers and numeric values only — no VIN, no raw payloads.
    static func dumpFieldsIfDebugging(_ data: Data) {
        guard UserDefaults.standard.bool(forKey: "debug_grpc_fields") else { return }
        let summary = Protobuf.fields(data).map { field -> String in
            switch field.wire {
            case 0: return "\(field.number)=\(field.varint)"
            case 1: return "\(field.number)=\(field.double.map { String($0) } ?? "?")d"
            default: return "\(field.number):wire\(field.wire)"
            }
        }
        NSLog("[Polaris] battery fields: \(summary.joined(separator: " "))")
    }

    /// Battery (pccs.vehiclestates.entities.battery.v1) — the fields we use:
    /// 6 = charger_connection_status, 10 = charging_power_watts, 11 =
    /// charging_current_amps, 17 = charging_type, 18 = charging_voltage_volts.
    static func parseBattery(_ data: Data) -> GrpcBatteryExtras {
        var connection: String?
        var watts: Int?, amps: Int?, volts: Int?
        var type: String?
        for field in Protobuf.fields(data) {
            switch (field.number, field.wire) {
            case (6, 0):
                switch field.varint {
                case 1: connection = "CONNECTED"
                case 2: connection = "DISCONNECTED"
                case 3: connection = "FAULT"
                default: break
                }
            case (10, 0): watts = Int(field.varint)
            case (11, 0): amps = Int(field.varint)
            case (18, 0): volts = Int(field.varint)
            case (17, 0):
                switch field.varint {
                case 2: type = "AC"
                case 3: type = "DC"
                case 4: type = "WIRELESS"
                default: break
                }
            default: break
            }
        }
        return GrpcBatteryExtras(chargerConnectionStatus: connection,
                                 chargingPowerWatts: watts,
                                 chargingCurrentAmps: amps,
                                 chargingVoltageVolts: volts,
                                 chargingType: type)
    }
}

/// Just enough proto3 wire format for the battery service: varints,
/// length-delimited fields, and the gRPC message frame.
enum Protobuf {

    struct Field {
        let number: Int
        let wire: Int
        /// Value for wire type 0; 0 otherwise.
        let varint: UInt64
        /// Payload for wire types 1, 2 and 5; empty otherwise.
        let data: Data

        /// The proto3 `double` in a wire-type-1 field, little-endian.
        var double: Double? {
            guard wire == 1, data.count == 8 else { return nil }
            return Double(bitPattern: UInt64(littleEndian: data.withUnsafeBytes {
                $0.loadUnaligned(as: UInt64.self)
            }))
        }
    }

    static func varint(_ value: UInt64) -> Data {
        var v = value, out = Data()
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    /// A length-delimited (wire type 2) string field.
    static func stringField(_ number: Int, _ value: String) -> Data {
        let bytes = Data(value.utf8)
        var out = varint(UInt64(number << 3 | 2))
        out.append(varint(UInt64(bytes.count)))
        out.append(bytes)
        return out
    }

    /// gRPC framing: flag byte (0 = uncompressed) + 4-byte big-endian length.
    static func grpcFrame(_ message: Data) -> Data {
        var out = Data([0])
        let n = UInt32(message.count).bigEndian
        withUnsafeBytes(of: n) { out.append(contentsOf: $0) }
        out.append(message)
        return out
    }

    /// Flat parse of one message level. Unknown wire types end the parse
    /// (returning what was read so far) rather than misinterpreting bytes.
    static func fields(_ data: Data) -> [Field] {
        var fields: [Field] = []
        let bytes = [UInt8](data)
        var i = 0

        func readVarint() -> UInt64? {
            var result: UInt64 = 0, shift: UInt64 = 0
            while i < bytes.count, shift < 64 {
                let b = bytes[i]; i += 1
                result |= UInt64(b & 0x7F) << shift
                if b & 0x80 == 0 { return result }
                shift += 7
            }
            return nil
        }

        while i < bytes.count {
            guard let tag = readVarint() else { break }
            let number = Int(tag >> 3), wire = Int(tag & 7)
            switch wire {
            case 0:
                guard let v = readVarint() else { return fields }
                fields.append(Field(number: number, wire: 0, varint: v, data: Data()))
            case 1, 5:
                let width = wire == 1 ? 8 : 4
                guard i + width <= bytes.count else { return fields }
                fields.append(Field(number: number, wire: wire, varint: 0,
                                    data: Data(bytes[i..<i + width])))
                i += width
            case 2:
                guard let len = readVarint(), i + Int(len) <= bytes.count else { return fields }
                fields.append(Field(number: number, wire: 2, varint: 0,
                                    data: Data(bytes[i..<i + Int(len)])))
                i += Int(len)
            default:
                return fields
            }
        }
        return fields
    }
}
