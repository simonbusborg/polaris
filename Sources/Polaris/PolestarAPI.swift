//
//  PolestarAPI.swift
//  Polaris (AppKit rewrite)
//
//  API flow originally ported from VoltStar (github.com/Michiel1992/voltstarP),
//  which uses Polestar's official endpoints and the community-known OAuth
//  client. Same proven flow: OIDC discovery -> authorize (PKCE) ->
//  form login -> code exchange -> GraphQL. No third-party endpoints.
//

import Foundation
import CryptoKit

struct CarData {
    let batteryPercentage: Double
    let rangeKm: Int
    let chargingStatus: String
    let estimatedChargingTimeToFullMinutes: Int?
    let modelName: String?
    let modelYear: String?
    let registrationNo: String?
    let vin: String?
    let ownerFirstName: String?
    let odometerKm: Int?
    let daysToService: Int?
    let distanceToServiceKm: Int?
    let serviceWarning: Bool
    let fluidWarnings: [String]
    let imageData: Data?
    let lastUpdated: Date

    /// Status with the CHARGING_STATUS_ / CHARGING_STATUS_V2_ prefix stripped,
    /// e.g. "CHARGING", "IDLE", "DONE".
    var statusKey: String {
        chargingStatus
            .replacingOccurrences(of: "CHARGING_STATUS_V2_", with: "")
            .replacingOccurrences(of: "CHARGING_STATUS_", with: "")
    }

    var isCharging: Bool {
        statusKey == "CHARGING" || statusKey == "SMART_CHARGING"
    }
}

enum PolestarError: Error, LocalizedError {
    case http(String)
    case parse(String)
    case authenticationFailed
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .http(let m): return "HTTP error: \(m)"
        case .parse(let m): return "Parse error: \(m)"
        case .authenticationFailed: return "Authentication failed — check email/password"
        case .notConfigured: return "Not configured — open Settings"
        }
    }
}

/// One car on the account, for the menu's car switcher.
struct CarSummary: Equatable {
    let vin: String
    let title: String   // e.g. "Polestar 4 · 2026"
}

final class PolestarAPI {

    /// Cars on the account (populated by fetchCarInfo). More than one
    /// makes the menu show a switcher.
    private(set) var cars: [CarSummary] = []

    /// Developer aid: `defaults write com.weareheavy.polaris debug_demo_car -bool YES`
    /// adds a pretend second car that mirrors the real car's data, so the
    /// multi-car UI can be exercised with a single-car account.
    private var demoCarEnabled: Bool {
        UserDefaults.standard.bool(forKey: "debug_demo_car")
    }
    static let demoVinPrefix = "DEMO-"

    /// Demo VINs are aliases for the real car — resolve before hitting the API.
    static func apiVin(_ vin: String) -> String {
        vin.hasPrefix(demoVinPrefix) ? String(vin.dropFirst(demoVinPrefix.count)) : vin
    }

    // Official Polestar endpoints only.
    private let apiBaseURL = URL(string: "https://pc-api.polestar.com/eu-north-1/mystar-v2/")!
    // Public (unauthenticated) API used by Polestar's own site for car images.
    // The x-api-key is a public AppSync key shipped in their web app.
    private let publicApiURL = URL(string: "https://pc-api.polestar.com/eu-north-1/mystar-public/")!
    private let publicApiKey = "da2-js63uvc7c5hwpdudt657d5lyou"
    private let oidcProviderURL = "https://polestarid.eu.polestar.com"
    private let oidcClientId = "l3oopkc_10"
    private let oidcRedirectUri = "https://www.polestar.com/sign-in-callback"
    private let oidcScope = "openid profile email customer:attributes"

    private var accessToken: String?
    private var refreshToken: String?
    private var tokenExpiry: Date?

    private var tokenEndpoint: String?
    private var authorizationEndpoint: String?
    private var userinfoEndpoint: String?
    private var ownerFirstName: String?

    private var session: URLSession

    private(set) var modelName: String?
    private(set) var modelYear: String?
    private(set) var registrationNo: String?
    private var pno34: String?
    private var structureWeek: String?
    private var carImageData: Data?
    private var lastInfoVin: String?

    init() {
        // .ephemeral ships with its own in-memory cookie storage — do NOT
        // replace it with a hand-made HTTPCookieStorage(), which silently
        // drops cookies and breaks the two-step login (authorize sets a
        // session cookie the login POST must send back).
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        session = URLSession(configuration: config)
    }

    private func debugLog(_ message: String) {
        NSLog("[Polaris] \(message)")
    }

    var isAuthenticated: Bool { accessToken != nil }

    // MARK: - Public entry points

    func authenticate(email: String, password: String, vin: String) async throws {
        try await discoverOidcConfiguration()
        let code = try await obtainAuthorizationCode(email: email, password: password)
        try await exchangeCodeForToken(code)
        // Car identity, image, and owner name are nice-to-have; ignore failures.
        try? await fetchCarInfo(vin: vin)
        await fetchCarImage()
        await fetchOwnerInfo()
    }

    /// Resume the previous session using the refresh token stored in the
    /// Keychain — no password login, no HTML scraping. Throws when no session
    /// is stored or Polestar rejects it; the caller falls back to
    /// `authenticate`. A rejected token is deleted so it isn't retried.
    func restoreSession(vin: String) async throws {
        guard let stored = ((try? Keychain.readSessionToken()) ?? nil), !stored.isEmpty else {
            throw PolestarError.authenticationFailed
        }
        try await discoverOidcConfiguration()
        refreshToken = stored
        do {
            try await refreshAccessToken()
        } catch {
            Keychain.deleteSessionToken()
            refreshToken = nil
            throw error
        }
        debugLog("session restored from stored refresh token")
        try? await fetchCarInfo(vin: vin)
        await fetchCarImage()
        await fetchOwnerInfo()
    }

    /// Point the identity/image state at another of the account's cars.
    func selectCar(vin: String) async {
        try? await fetchCarInfo(vin: vin)
        await fetchCarImage()
    }

    func fetchCarData(vin rawVin: String) async throws -> CarData {
        let vin = Self.apiVin(rawVin)
        try await refreshTokenIfNeeded()
        guard let token = accessToken else { throw PolestarError.notConfigured }

        // Field names per Polestar's current schema (as used by pypolestar):
        // chargingStatus -> chargingStatusV2; the Miles field no longer exists.
        let query = """
        query CarTelematicsV2($vins: [String!]!) {
          carTelematicsV2(vins: $vins) {
            battery {
              vin
              batteryChargeLevelPercentage
              estimatedDistanceToEmptyKm
              chargingStatusV2
              estimatedChargingTimeToFullMinutes
              timestamp { seconds }
            }
            odometer {
              vin
              odometerMeters
              timestamp { seconds }
            }
            health {
              vin
              daysToService
              distanceToServiceKm
              serviceWarning
              brakeFluidLevelWarning
              engineCoolantLevelWarning
              oilLevelWarning
              timestamp { seconds }
            }
          }
        }
        """
        let json = try await graphQL(query: query, variables: ["vins": [vin]], token: token)

        guard let data = json["data"] as? [String: Any],
              let telematics = data["carTelematicsV2"] as? [String: Any],
              let batteries = telematics["battery"] as? [[String: Any]],
              let battery = batteries.first
        else { throw PolestarError.parse("Unexpected telematics response") }

        let odometer = (telematics["odometer"] as? [[String: Any]])?.first
        let health = (telematics["health"] as? [[String: Any]])?.first

        var odometerKm: Int?
        if let meters = odometer?["odometerMeters"] as? Int { odometerKm = meters / 1000 }

        let warning: Bool
        if let sw = health?["serviceWarning"] as? String {
            warning = !sw.contains("NO_WARNING") && !sw.contains("UNSPECIFIED")
        } else {
            warning = false
        }

        // Fluid warnings — only surfaced when the car actually complains.
        var fluids: [String] = []
        let fluidFields = [
            ("brakeFluidLevelWarning", "BRAKE_FLUID_LEVEL_WARNING_", "Brake fluid"),
            ("engineCoolantLevelWarning", "ENGINE_COOLANT_LEVEL_WARNING_", "Coolant"),
            ("oilLevelWarning", "OIL_LEVEL_WARNING_", "Oil")
        ]
        for (field, prefix, label) in fluidFields {
            guard let raw = health?[field] as? String,
                  !raw.contains("NO_WARNING"), !raw.contains("UNSPECIFIED") else { continue }
            let detail = raw.replacingOccurrences(of: prefix, with: "")
                .replacingOccurrences(of: "_", with: " ").lowercased()
            fluids.append("\(label) \(detail)")   // e.g. "Oil too low"
        }

        return CarData(
            batteryPercentage: battery["batteryChargeLevelPercentage"] as? Double ?? 0,
            rangeKm: battery["estimatedDistanceToEmptyKm"] as? Int ?? 0,
            chargingStatus: battery["chargingStatusV2"] as? String ?? "Unknown",
            estimatedChargingTimeToFullMinutes: battery["estimatedChargingTimeToFullMinutes"] as? Int,
            modelName: modelName,
            modelYear: modelYear,
            registrationNo: registrationNo,
            vin: vin,
            ownerFirstName: ownerFirstName,
            odometerKm: odometerKm,
            daysToService: health?["daysToService"] as? Int,
            distanceToServiceKm: health?["distanceToServiceKm"] as? Int,
            serviceWarning: warning,
            fluidWarnings: fluids,
            imageData: carImageData,
            lastUpdated: Date()
        )
    }

    // MARK: - OIDC / OAuth2 with PKCE

    private func discoverOidcConfiguration() async throws {
        let url = URL(string: "\(oidcProviderURL)/.well-known/openid-configuration")!
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw PolestarError.http("OIDC discovery failed")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokenEp = json["token_endpoint"] as? String,
              let authEp = json["authorization_endpoint"] as? String
        else { throw PolestarError.parse("Invalid OIDC configuration") }

        tokenEndpoint = tokenEp
        authorizationEndpoint = authEp
        userinfoEndpoint = json["userinfo_endpoint"] as? String
    }

    /// The OIDC userinfo endpoint returns profile claims (given_name etc.)
    /// for the logged-in Polestar ID — used to greet the owner by name.
    private func fetchOwnerInfo() async {
        guard ownerFirstName == nil, let token = accessToken,
              let endpoint = userinfoEndpoint, let url = URL(string: endpoint) else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { debugLog("userinfo: fetch failed"); return }
        ownerFirstName = (json["given_name"] as? String) ?? (json["firstname"] as? String)
    }

    private var codeVerifier = ""

    private func obtainAuthorizationCode(email: String, password: String) async throws -> String {
        guard let authEndpoint = authorizationEndpoint else { throw PolestarError.authenticationFailed }

        codeVerifier = Self.randomURLSafeString()
        let challenge = Self.codeChallenge(for: codeVerifier)
        let state = Self.randomURLSafeString()

        let queryItems = [
            URLQueryItem(name: "client_id", value: oidcClientId),
            URLQueryItem(name: "redirect_uri", value: oidcRedirectUri),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: oidcScope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "response_mode", value: "query")
        ]
        var components = URLComponents(string: authEndpoint)!
        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
                         forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PolestarError.http("Invalid response") }
        debugLog("authorize: status \(http.statusCode), url \(http.url?.absoluteString ?? "-")")

        // Already redirected to the callback with a code (existing session cookie)?
        if let code = Self.extractCode(from: http.url) { return code }

        // Otherwise parse the login form's resume path and POST credentials.
        let html = String(data: data, encoding: .utf8) ?? ""
        guard let resumePath = Self.extractResumePath(from: html) else {
            debugLog("authorize: no resume path in \(html.count)-byte response")
            throw PolestarError.parse("Could not find login form — Polestar may have changed their flow")
        }
        debugLog("authorize: resume path \(resumePath)")
        return try await performLogin(resumePath: resumePath, queryItems: queryItems,
                                      email: email, password: password)
    }

    private func performLogin(resumePath: String, queryItems: [URLQueryItem],
                              email: String, password: String) async throws -> String {
        // Like pypolestar: the login POST goes to the resume path WITH the
        // same OAuth query params as the authorize request.
        var components = URLComponents(string: "\(oidcProviderURL)\(resumePath)")!
        var items = components.queryItems ?? []
        items.append(contentsOf: queryItems)
        components.queryItems = items
        let loginURL = components.url!

        let (data, http) = try await postForm(
            to: loginURL,
            fields: ["pf.username": email, "pf.pass": password]
        )
        debugLog("login: status \(http.statusCode), url \(http.url?.absoluteString ?? "-")")

        if let code = Self.extractCode(from: http.url) { return code }

        // Polestar sometimes redirects back with a `uid` instead of a code —
        // an extra confirmation step. POST the confirmation, then the code
        // arrives on the following redirect. (Same handling as pypolestar.)
        if let uid = Self.queryValue("uid", from: http.url) {
            debugLog("login: uid confirmation required")
            let (_, confirmHTTP) = try await postForm(
                to: loginURL,
                fields: ["pf.submit": "true", "subject": uid]
            )
            debugLog("confirm: status \(confirmHTTP.statusCode), url \(confirmHTTP.url?.absoluteString ?? "-")")
            if let code = Self.extractCode(from: confirmHTTP.url) { return code }
        }

        let html = String(data: data, encoding: .utf8) ?? ""
        if html.contains("ERR001") {
            debugLog("login: Polestar returned ERR001 (bad credentials)")
            throw PolestarError.authenticationFailed
        }
        debugLog("login: no code or uid in response (\(html.count) bytes)")
        throw PolestarError.authenticationFailed
    }

    private func postForm(to url: URL, fields: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields
            .map { key, value in
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(key)=\(v)"
            }
            .joined(separator: "&")
        request.httpBody = Data(body.utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PolestarError.http("Invalid response") }
        return (data, http)
    }

    private static func queryValue(_ name: String, from url: URL?) -> String? {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        return components.queryItems?.first(where: { $0.name == name })?.value
    }

    private func exchangeCodeForToken(_ code: String) async throws {
        guard let tokenEndpoint else { throw PolestarError.authenticationFailed }
        var request = URLRequest(url: URL(string: tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data([
            "grant_type=authorization_code",
            "client_id=\(oidcClientId)",
            "code=\(code)",
            "redirect_uri=\(oidcRedirectUri)",
            "code_verifier=\(codeVerifier)"
        ].joined(separator: "&").utf8)

        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? Int
        else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            debugLog("token exchange failed (status \(status)): \(String(decoding: data.prefix(300), as: UTF8.self))")
            throw PolestarError.http("Token exchange failed")
        }

        accessToken = access
        refreshToken = json["refresh_token"] as? String
        tokenExpiry = Date().addingTimeInterval(TimeInterval(expiresIn))
        persistSession()
    }

    private func refreshTokenIfNeeded() async throws {
        guard let expiry = tokenExpiry, expiry.timeIntervalSinceNow < 300 else { return }
        try await refreshAccessToken()
    }

    private func refreshAccessToken() async throws {
        guard let tokenEndpoint, let refresh = refreshToken else { throw PolestarError.authenticationFailed }

        var request = URLRequest(url: URL(string: tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data([
            "grant_type=refresh_token",
            "client_id=\(oidcClientId)",
            "refresh_token=\(refresh)"
        ].joined(separator: "&").utf8)

        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? Int
        else { throw PolestarError.http("Token refresh failed") }

        accessToken = access
        if let newRefresh = json["refresh_token"] as? String { refreshToken = newRefresh }
        tokenExpiry = Date().addingTimeInterval(TimeInterval(expiresIn))
        persistSession()
    }

    /// Polestar rotates refresh tokens; keep the newest one in the Keychain
    /// so the next launch can skip the password login entirely.
    private func persistSession() {
        guard let refreshToken else { return }
        try? Keychain.saveSessionToken(refreshToken)
    }

    // MARK: - GraphQL

    private func fetchCarInfo(vin: String) async throws {
        guard let token = accessToken else { return }
        // registrationNo is the license plate. Keep this query minimal and
        // known-good: one rejected field fails the whole request and takes
        // the plate, model title, and car image down with it. Polestar
        // removed the configuration data (content{}, features) from this
        // schema around April 2026 — don't re-add those fields.
        let query = """
        query GetConsumerCarsV2 {
          getConsumerCarsV2 {
            vin
            modelName
            modelYear
            registrationNo
            pno34
            structureWeek
          }
        }
        """
        let json = try await graphQL(query: query, variables: nil, token: token)
        guard let data = json["data"] as? [String: Any],
              let accountCars = data["getConsumerCarsV2"] as? [[String: Any]],
              !accountCars.isEmpty
        else { return }

        cars = accountCars.compactMap { car in
            guard let carVin = car["vin"] as? String else { return nil }
            let name = car["modelName"] as? String
            let year = (car["modelYear"] as? String) ?? (car["modelYear"] as? Int).map(String.init)
            let title = [name, year].compactMap { $0 }.joined(separator: " · ")
            return CarSummary(vin: carVin, title: title.isEmpty ? carVin : title)
        }
        if demoCarEnabled, let real = cars.first {
            cars.append(CarSummary(vin: Self.demoVinPrefix + real.vin,
                                   title: real.title + " (demo)"))
        }

        // The selected car, or the first one when the VIN doesn't match
        // (e.g. a typo in Settings, or a demo VIN aliasing the real car).
        let wanted = Self.apiVin(vin)
        guard let car = accountCars.first(where: { ($0["vin"] as? String) == wanted })
            ?? accountCars.first else { return }

        // Switching cars invalidates the cached studio render.
        if (car["vin"] as? String) != lastInfoVin {
            carImageData = nil
            lastInfoVin = car["vin"] as? String
        }

        modelName = car["modelName"] as? String
        modelYear = (car["modelYear"] as? String) ?? (car["modelYear"] as? Int).map(String.init)
        registrationNo = car["registrationNo"] as? String
        pno34 = car["pno34"] as? String
        structureWeek = (car["structureWeek"] as? String) ?? (car["structureWeek"] as? Int).map(String.init)
    }

    /// Fetches a studio render of the exact car (correct paint/wheels) from
    /// Polestar's public image API, then downloads the image bytes once.
    private func fetchCarImage() async {
        guard carImageData == nil,
              let pno34, let structureWeek, let modelYear else { return }

        let query = """
        query GetCarImages($pno34: String!, $structureWeek: String!, $modelYear: String!, $locale: String!) {
          getCarImages(pno34: $pno34, structureWeek: $structureWeek, modelYear: $modelYear, locale: $locale) {
            transparent { url angle }
            opaque { url angle }
          }
        }
        """
        let body: [String: Any] = ["query": query, "variables": [
            "pno34": pno34, "structureWeek": structureWeek,
            "modelYear": modelYear, "locale": "en-GB"
        ]]

        var request = URLRequest(url: publicApiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(publicApiKey, forHTTPHeaderField: "x-api-key")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, _) = try? await session.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = json["data"] as? [String: Any],
              let images = payload["getCarImages"] as? [String: Any]
        else { debugLog("car image: query failed"); return }

        let transparent = images["transparent"] as? [[String: Any]] ?? []
        let opaque = images["opaque"] as? [[String: Any]] ?? []
        // Prefer a transparent render; pick the side profile (angle 0) when
        // available, falling back to the front three-quarter view (angle 1).
        // CAS angle order: 0 side, 1 front 3/4, 2 front, 3 rear 3/4, 4 rear, 5 top.
        let pool = transparent.isEmpty ? opaque : transparent
        let pick = pool.first(where: { ($0["angle"] as? Int) == 0 })
            ?? pool.first(where: { ($0["angle"] as? Int) == 1 })
            ?? pool.first
        guard let urlString = pick?["url"] as? String, let url = URL(string: urlString) else { return }

        if let (imageBytes, _) = try? await session.data(from: url) {
            carImageData = imageBytes
            debugLog("car image: downloaded \(imageBytes.count) bytes (angle \(pick?["angle"] as? Int ?? -1))")
        }
    }

    private func graphQL(query: String, variables: [String: Any]?, token: String) async throws -> [String: Any] {
        var body: [String: Any] = ["query": query]
        if let variables { body["variables"] = variables }

        var request = URLRequest(url: apiBaseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            // Validation errors come back as non-200 with the details in the
            // body — surface them instead of just the status code.
            let detail = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["errors"] as? [[String: Any]] }?
                .compactMap { $0["message"] as? String }
                .joined(separator: ", ")) ?? ""
            throw PolestarError.http("GraphQL request failed (status \((response as? HTTPURLResponse)?.statusCode ?? -1))"
                + (detail.isEmpty ? "" : ": \(detail)"))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PolestarError.parse("Invalid JSON")
        }
        if let errors = json["errors"] as? [[String: Any]] {
            let messages = errors.compactMap { $0["message"] as? String }.joined(separator: ", ")
            throw PolestarError.http("GraphQL: \(messages)")
        }
        return json
    }

    // MARK: - PKCE helpers

    private static func randomURLSafeString() -> String {
        var buffer = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        return Data(buffer).base64URLEncoded()
    }

    private static func codeChallenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
    }

    // MARK: - Parsing helpers

    private static func extractCode(from url: URL?) -> String? {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        return components.queryItems?.first(where: { $0.name == "code" })?.value
    }

    static func extractResumePath(from html: String) -> String? {
        let patterns = [
            // Current Polestar login page embeds:  action: "/as/xxx/resume/as/authorization.ping"
            // (same primary pattern as pypolestar)
            #"(?:url|action):\s*"([^"]+)""#,
            #"(?:resumePath|pf\.resumePath)\s*[:=]\s*['"]([^'"]+)['"]"#,
            #"action="([^"]+)""#,
            #"action:\s*'([^']+)'"#,
            #"url:\s*'([^']+)'"#,
            #"/as/[a-zA-Z0-9\-_./]+"#   // note the '.', or '.ping' gets truncated
        ]
        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(html.startIndex..., in: html)
            guard let match = regex.firstMatch(in: html, range: range) else { continue }
            let groupIndex = match.numberOfRanges > 1 ? 1 : 0
            guard let matchRange = Range(match.range(at: groupIndex), in: html) else { continue }
            let value = String(html[matchRange])
            // The last pattern matches a bare path; earlier ones capture attributes.
            if index == patterns.count - 1 || value.hasPrefix("/") {
                return value
            }
        }
        return nil
    }
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
