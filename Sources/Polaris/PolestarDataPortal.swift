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
    let tyreWarnings: [String]
    let batteryWarning: Bool
    /// From `availability`: DRIVING, ENGINE_ON, INACTIVE… nil when unknown.
    let usageMode: String?
    let climate: ClimateStatus?
    let exterior: ExteriorStatus?
    let location: CarLocation?
    /// Charge limit in percent, from `charging/target-soc`.
    let targetSoc: Int?
}

enum DataPortalError: Error, LocalizedError {
    case http(Int, String)
    case parse(String)
    case unauthorized
    case vehicleNotShared(String)
    /// 202: Polestar accepted the request but has no reading yet. Treated as
    /// "try the other path this round" rather than as a failure to show.
    case pending
    /// 403 or 404 on one domain: the credential wasn't granted that scope,
    /// or this model doesn't report it. Not an error to show, just a row
    /// that won't appear.
    case domainUnavailable

    var errorDescription: String? {
        switch self {
        case .http(let code, let m): return String(format: L("Data Portal HTTP %d: %@"), code, m)
        case .parse(let m): return String(format: L("Data Portal parse error: %@"), m)
        case .unauthorized: return L("Data Portal rejected the credentials — check them in Settings")
        case .vehicleNotShared(let vin):
            return String(format: L("Data Portal credential has no access to %@"), vin)
        case .pending: return L("Data Portal has no reading yet")
        case .domainUnavailable: return L("Data Portal has no reading yet")
        }
    }
}

final class PolestarDataPortal {

    static let baseURL = URL(string: "https://pc-api.polestar.com/eu-north-1/data-portal/m2m")!

    /// How often each domain is worth asking for. Battery and availability
    /// go every refresh — that's what the menu bar is for. The rest change
    /// on the scale of a parking stop, and the budget is 10,000 calls a day:
    /// eight domains a minute through a long charge would spend it. Climate
    /// is the exception while it runs, when the countdown is the point.
    static let slowInterval: TimeInterval = 5 * 60

    let credentials: DataPortalCredentials
    private let session: URLSession
    private var accessToken: String?
    private var tokenExpiry: Date?
    /// Last good answer per path, for the slow domains.
    private var cache: [String: (at: Date, json: [String: Any]?)] = [:]

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
        // Battery is the one that matters; everything else degrades to nil.
        let battery = try await get("v1/vehicles/\(vin)/telemetry/battery")
        guard let batteryData = battery["data"] as? [String: Any] else {
            throw DataPortalError.parse("battery: missing data")
        }
        let base = "v1/vehicles/\(vin)/"
        let odometer = await data(base + "telemetry/odometer")
        let availability = await data(base + "telemetry/availability")
        let health = await data(base + "telemetry/health", every: Self.slowInterval)
        let exterior = await data(base + "telemetry/exterior", every: Self.slowInterval)
        let location = await data(base + "telemetry/location", every: Self.slowInterval)
        let targetSoc = await data(base + "charging/target-soc", every: Self.slowInterval)
        // Live while the climate runs, so the minutes-left row counts down.
        let climateLive = (cache[base + "telemetry/parking-climatization"]?.json)
            .flatMap { Self.climate(from: $0) }?.isRunning == true
        let climate = await data(base + "telemetry/parking-climatization",
                                 every: climateLive ? 0 : Self.slowInterval)
        return Self.telemetry(battery: batteryData, odometer: odometer, health: health,
                              availability: availability, climate: climate,
                              exterior: exterior, location: location, targetSoc: targetSoc)
    }

    /// The `data` object of a domain, or nil when it can't be had. A slow
    /// domain returns its cached answer until `every` has passed; a domain
    /// this credential or model lacks is remembered as nil for the same
    /// span, so a missing scope costs one request an interval, not one a
    /// refresh.
    private func data(_ path: String, every interval: TimeInterval = 0) async -> [String: Any]? {
        if let hit = cache[path], Date().timeIntervalSince(hit.at) < interval {
            return hit.json
        }
        do {
            let json = try await get(path)["data"] as? [String: Any]
            cache[path] = (Date(), json)
            return json
        } catch DataPortalError.domainUnavailable {
            cache[path] = (Date(), nil)
            return nil
        } catch {
            // Transient: keep the last good answer, if any, for this round.
            return cache[path]?.json
        }
    }

    // MARK: - Parsing (pure, so the tests can feed it captured responses)

    static func telemetry(battery: [String: Any],
                          odometer: [String: Any]?,
                          health: [String: Any]?,
                          availability: [String: Any]? = nil,
                          climate: [String: Any]? = nil,
                          exterior: [String: Any]? = nil,
                          location: [String: Any]? = nil,
                          targetSoc: [String: Any]? = nil) -> DataPortalTelemetry {
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
            fluidWarnings: summary.fluids,
            tyreWarnings: summary.tyres,
            batteryWarning: summary.batteryWarning,
            usageMode: enumCase(availability?["usageMode"], prefix: "USAGE_MODE_"),
            climate: climate.flatMap(Self.climate(from:)),
            exterior: exterior.flatMap(Self.exterior(from:)),
            location: location.flatMap(Self.location(from:)),
            targetSoc: number((targetSoc?["targetSoc"] as? [String: Any])?["batteryChargeTargetLevel"])
                .map { Int($0) }
        )
    }

    static func climate(from json: [String: Any]) -> ClimateStatus? {
        guard let status = enumCase(json["runningStatus"], prefix: "RUNNING_STATUS_") else { return nil }
        let problems = ((json["errors"] as? [String]) ?? []).compactMap { enumCase($0, prefix: "ERROR_TYPE_") }
            + ((json["warnings"] as? [String]) ?? []).compactMap { enumCase($0, prefix: "WARNING_TYPE_") }
        return ClimateStatus(
            runningStatus: status,
            ventilation: enumCase(json["ventilation"], prefix: "VENTILATION_"),
            currentCelsius: number(json["currentCompartmentTemperatureCelsius"]),
            requestedCelsius: number(json["requestedCompartmentTemperatureCelsius"]),
            minutesLeft: number(json["runtimeLeftMinutes"]).map { Int($0) },
            problems: problems,
            reportedAt: PolestarAPI.reportedAt(json))
    }

    /// Every part of the shell the API reports, in the order the menu lists
    /// them when open. Field names double as localisation keys via
    /// `CarFormat.openingName`.
    static let exteriorParts = [
        "frontLeftDoor", "frontRightDoor", "rearLeftDoor", "rearRightDoor",
        "hood", "tailgate", "tankLid", "sunroof",
        "frontLeftWindow", "frontRightWindow", "rearLeftWindow", "rearRightWindow"
    ]

    static func exterior(from json: [String: Any]) -> ExteriorStatus? {
        let lock = enumCase(json["centralLock"], prefix: "LOCK_STATUS_")
        let openings = exteriorParts.filter {
            let state = enumCase(json[$0], prefix: "OPEN_STATUS_")
            return state == "OPEN" || state == "AJAR"
        }
        // A car that reported neither a lock state nor any part is one that
        // doesn't speak this domain; nothing to show.
        guard lock != nil || exteriorParts.contains(where: { json[$0] != nil }) else { return nil }
        return ExteriorStatus(
            locked: lock.map { $0 == "LOCKED" },
            openings: openings,
            alarmTriggered: enumCase(json["alarm"], prefix: "ALARM_STATUS_") == "TRIGGERED",
            reportedAt: PolestarAPI.reportedAt(json))
    }

    static func location(from json: [String: Any]) -> CarLocation? {
        guard let c = json["coordinate"] as? [String: Any],
              let lat = number(c["latitude"]), let lon = number(c["longitude"]),
              lat != 0 || lon != 0
        else { return nil }
        return CarLocation(latitude: lat, longitude: lon,
                           heading: number(json["heading"]),
                           reportedAt: PolestarAPI.reportedAt(json))
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
        case 401:
            // Tokens live an hour; a rejected one is dropped so the next
            // round mints a fresh one instead of repeating the failure.
            accessToken = nil
            throw DataPortalError.unauthorized
        case 403, 404:
            // The token is fine; this scope wasn't granted, or the model
            // doesn't report the domain. `vehicles` is the exception: a
            // credential that can't list its cars is one that doesn't work.
            if path == "v1/vehicles" { throw DataPortalError.unauthorized }
            throw DataPortalError.domainUnavailable
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
        // No `scope`: the spec marks it optional, and naming one the
        // credential wasn't created with fails the whole token call rather
        // than that one domain. Left out, the token carries whatever the
        // owner ticked, and the domains they didn't simply answer 403.
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "clientId": credentials.clientId,
            "clientSecret": credentials.clientSecret
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
