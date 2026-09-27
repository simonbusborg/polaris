//
//  PolestarDataPortal.swift
//  Polaris (AppKit rewrite)
//
//  Client for Polestar's official Data Portal API — the EU Data Act
//  interface Polestar opened in September 2026. Opt-in: the owner creates a
//  credential at data-portal.polestar.com and pastes it into Settings; the
//  Polestar ID login stays the default and the fallback.
//
//  Why bother when the MyStar path works? This one is documented and
//  supported, it carries the charging power and charger state that the
//  GraphQL API dropped (so the reverse-engineered gRPC call becomes
//  unnecessary), and it needs no password. What it lacks: the car's model
//  name and studio image, which still come from the Polestar ID session.
//
//  Machine-to-machine OAuth2 with Polestar's own spellings: the token
//  endpoint takes and returns camelCase JSON rather than the RFC form
//  fields, and every call carries the portal's account ID in `x-client-id`.
//  Budget is 10,000 calls a day and 100 a minute per credential; Polaris at
//  its fastest pace uses a few hundred.
//

import Foundation
import PolarisShared

/// What the owner pastes from the portal's Credential page. Stored as one
/// Keychain item per account, so a household with two logins can hold two.
struct DataPortalCredentials: Codable, Equatable {
    let clientId: String
    let clientSecret: String
    /// Labelled "Account ID / x-client-id" on the portal's API page.
    let accountId: String

    var isComplete: Bool {
        !clientId.isEmpty && !clientSecret.isEmpty && !accountId.isEmpty
    }
}

/// One fetch's worth of telemetry, already shaped for `CarData`. Fields are
/// optional wherever the portal documents that a model may not report them.
struct DataPortalTelemetry {
    let batteryPercentage: Double
    let rangeKm: Int
    let chargingStatus: String
    let estimatedChargingTimeToFullMinutes: Int?
    let carReportedAt: Date?
    let extras: GrpcBatteryExtras
    let odometerMeters: Int?
    let odometerReportedAt: Date?
    let daysToService: Int?
    let distanceToServiceKm: Int?
    let serviceWarning: Bool
    let fluidWarnings: [String]
}

enum DataPortalError: Error, LocalizedError {
    case http(Int, String)
    case parse(String)
    case unauthorized
    case vehicleNotShared(String)
    /// 202: Polestar accepted the request but has no reading yet. Treated as
    /// "try the other path this round" rather than as a failure to show.
    case pending

    var errorDescription: String? {
        switch self {
        case .http(let code, let m): return String(format: L("Data Portal HTTP %d: %@"), code, m)
        case .parse(let m): return String(format: L("Data Portal parse error: %@"), m)
        case .unauthorized: return L("Data Portal rejected the credentials — check them in Settings")
        case .vehicleNotShared(let vin):
            return String(format: L("Data Portal credential has no access to %@"), vin)
        case .pending: return L("Data Portal has no reading yet")
        }
    }
}

final class PolestarDataPortal {

    static let baseURL = URL(string: "https://pc-api.polestar.com/eu-north-1/data-portal/m2m")!

    /// Scopes Polaris asks for. The portal only issues what the credential
    /// was created with; asking for more than it holds fails the token call,
    /// so this list has to match what the Settings pane tells people to tick.
    static let scopes = [
        "pdp-telemetry/battery",
        "pdp-telemetry/odometer",
        "pdp-telemetry/health"
    ]

    let credentials: DataPortalCredentials
    private let session: URLSession
    private var accessToken: String?
    private var tokenExpiry: Date?

    init(credentials: DataPortalCredentials) {
        self.credentials = credentials
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
    }

    // MARK: - Public

    /// VINs this credential may read. Used by Settings to confirm a pasted
    /// credential actually covers the selected car before it is saved.
    func vehicles() async throws -> [String] {
        let json = try await get("v1/vehicles")
        guard let vins = json["data"] as? [String] else {
            throw DataPortalError.parse("vehicles: expected a list of VINs")
        }
        return vins
    }

    func fetchTelemetry(vin: String) async throws -> DataPortalTelemetry {
        // Battery is the one that matters; the other two degrade to nil.
        let battery = try await get("v1/vehicles/\(vin)/telemetry/battery")
        guard let batteryData = battery["data"] as? [String: Any] else {
            throw DataPortalError.parse("battery: missing data")
        }
        let odometer = try? await get("v1/vehicles/\(vin)/telemetry/odometer")
        let health = try? await get("v1/vehicles/\(vin)/telemetry/health")
        return Self.telemetry(battery: batteryData,
                              odometer: odometer?["data"] as? [String: Any],
                              health: health?["data"] as? [String: Any])
    }

    // MARK: - Parsing (pure, so the tests can feed it captured responses)

    static func telemetry(battery: [String: Any],
                          odometer: [String: Any]?,
                          health: [String: Any]?) -> DataPortalTelemetry {
        let summary = PolestarAPI.healthSummary(health)
        return DataPortalTelemetry(
            batteryPercentage: number(battery["batteryChargeLevelPercentage"]) ?? 0,
            rangeKm: number(battery["estimatedDistanceToEmptyKm"]).map { Int($0) } ?? 0,
            chargingStatus: battery["chargingStatusV2"] as? String
                ?? battery["chargingStatus"] as? String ?? "Unknown",
            estimatedChargingTimeToFullMinutes:
                number(battery["estimatedChargingTimeToFullMinutes"]).map { Int($0) },
            carReportedAt: PolestarAPI.reportedAt(battery),
            extras: extras(from: battery),
            odometerMeters: number(odometer?["odometerMeters"]).map { Int($0) },
            odometerReportedAt: PolestarAPI.reportedAt(odometer),
            daysToService: number(health?["daysToService"]).map { Int($0) },
            distanceToServiceKm: number(health?["distanceToServiceKm"]).map { Int($0) },
            serviceWarning: summary.warning,
            fluidWarnings: summary.fluids
        )
    }

    /// The battery message carries the same fields the gRPC service did,
    /// under the same names, so the menu's charger and power rows keep
    /// reading from `GrpcBatteryExtras` whichever path filled it.
    static func extras(from battery: [String: Any]) -> GrpcBatteryExtras {
        let connection = enumCase(battery["chargerConnectionStatus"],
                                  prefix: "CHARGER_CONNECTION_STATUS_")
        var type = enumCase(battery["chargingType"], prefix: "CHARGING_TYPE_")
        if type == "NONE" { type = nil }
        return GrpcBatteryExtras(
            chargerConnectionStatus: connection,
            chargingPowerWatts: number(battery["chargingPowerWatts"]).map { Int($0) },
            chargingCurrentAmps: number(battery["chargingCurrentAmps"]).map { Int($0) },
            chargingVoltageVolts: number(battery["chargingVoltageVolts"]).map { Int($0) },
            chargingType: type
        )
    }

    /// Strips the protobuf-style prefix and drops UNSPECIFIED, which the car
    /// sends for "no opinion" and which no row should ever show.
    static func enumCase(_ raw: Any?, prefix: String) -> String? {
        guard let s = raw as? String else { return nil }
        let value = s.hasPrefix(prefix) ? String(s.dropFirst(prefix.count)) : s
        return (value.isEmpty || value == "UNSPECIFIED") ? nil : value
    }

    /// The portal serialises numbers as JSON numbers or, for int64, as
    /// strings. Accept both, as the GraphQL parser has had to.
    static func number(_ raw: Any?) -> Double? {
        switch raw {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let s as String: return Double(s)
        default: return nil
        }
    }

    /// Token response, camelCase. Returns nil when the shape is wrong.
    static func parseToken(_ json: [String: Any]) -> (token: String, expiresIn: TimeInterval)? {
        guard let token = json["accessToken"] as? String, !token.isEmpty else { return nil }
        return (token, number(json["expiresIn"]) ?? 3600)
    }

    // MARK: - Transport

    private func get(_ path: String) async throws -> [String: Any] {
        let token = try await validToken()
        var request = URLRequest(url: Self.baseURL.appendingPathComponent(path))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.accountId, forHTTPHeaderField: "x-client-id")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200:
            break
        case 202, 204:
            throw DataPortalError.pending
        case 401, 403:
            // Tokens live an hour; a rejected one is dropped so the next
            // round mints a fresh one instead of repeating the failure.
            accessToken = nil
            throw DataPortalError.unauthorized
        default:
            throw DataPortalError.http(status, Self.message(in: data))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DataPortalError.parse("\(path): not a JSON object")
        }
        return json
    }

    private func validToken() async throws -> String {
        if let accessToken, let tokenExpiry, tokenExpiry > Date().addingTimeInterval(60) {
            return accessToken
        }
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("token"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "clientId": credentials.clientId,
            "clientSecret": credentials.clientSecret,
            "scope": Self.scopes.joined(separator: " ")
        ])

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw DataPortalError.unauthorized
        }
        guard status == 200 else {
            throw DataPortalError.http(status, Self.message(in: data))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let parsed = Self.parseToken(json)
        else { throw DataPortalError.parse("token: missing accessToken") }

        accessToken = parsed.token
        tokenExpiry = Date().addingTimeInterval(parsed.expiresIn)
        return parsed.token
    }

    private static func message(in data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let m = (json["message"] ?? json["error"]) as? String {
            return m
        }
        return String(data: data.prefix(200), encoding: .utf8) ?? ""
    }
}
