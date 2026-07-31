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
    let rangeMiles: Int?
    let chargingStatus: String
    let estimatedChargingTimeToFullMinutes: Int?
    let modelName: String?
    let lastUpdated: Date

    var isCharging: Bool {
        chargingStatus == "CHARGING_STATUS_CHARGING"
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

final class PolestarAPI {

    // Official Polestar endpoints only.
    private let apiBaseURL = URL(string: "https://pc-api.polestar.com/eu-north-1/mystar-v2/")!
    private let oidcProviderURL = "https://polestarid.eu.polestar.com"
    private let oidcClientId = "l3oopkc_10"
    private let oidcRedirectUri = "https://www.polestar.com/sign-in-callback"
    private let oidcScope = "openid profile email customer:attributes"

    private var accessToken: String?
    private var refreshToken: String?
    private var tokenExpiry: Date?

    private var tokenEndpoint: String?
    private var authorizationEndpoint: String?

    private var session: URLSession

    private(set) var modelName: String?

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
        // Model name is nice-to-have; ignore failures.
        modelName = try? await fetchModelName(vin: vin)
    }

    func fetchCarData(vin: String) async throws -> CarData {
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
          }
        }
        """
        let json = try await graphQL(query: query, variables: ["vins": [vin]], token: token)

        guard let data = json["data"] as? [String: Any],
              let telematics = data["carTelematicsV2"] as? [String: Any],
              let batteries = telematics["battery"] as? [[String: Any]],
              let battery = batteries.first
        else { throw PolestarError.parse("Unexpected telematics response") }

        let rangeKm = battery["estimatedDistanceToEmptyKm"] as? Int ?? 0
        return CarData(
            batteryPercentage: battery["batteryChargeLevelPercentage"] as? Double ?? 0,
            rangeKm: rangeKm,
            rangeMiles: Int((Double(rangeKm) * 0.621371).rounded()),
            chargingStatus: battery["chargingStatusV2"] as? String ?? "Unknown",
            estimatedChargingTimeToFullMinutes: battery["estimatedChargingTimeToFullMinutes"] as? Int,
            modelName: modelName,
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
        else { throw PolestarError.http("Token exchange failed") }

        accessToken = access
        refreshToken = json["refresh_token"] as? String
        tokenExpiry = Date().addingTimeInterval(TimeInterval(expiresIn))
    }

    private func refreshTokenIfNeeded() async throws {
        guard let expiry = tokenExpiry, expiry.timeIntervalSinceNow < 300 else { return }
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
    }

    // MARK: - GraphQL

    private func fetchModelName(vin: String) async throws -> String? {
        guard let token = accessToken else { return nil }
        // Current schema: modelName is a flat field (the old
        // content{model{name}} structure no longer exists).
        let query = """
        query GetConsumerCarsV2 {
          getConsumerCarsV2 {
            vin
            modelName
          }
        }
        """
        let json = try await graphQL(query: query, variables: nil, token: token)
        guard let data = json["data"] as? [String: Any],
              let cars = data["getConsumerCarsV2"] as? [[String: Any]],
              let car = cars.first(where: { ($0["vin"] as? String) == vin })
        else { return nil }
        return car["modelName"] as? String
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
            throw PolestarError.http("GraphQL request failed (status \((response as? HTTPURLResponse)?.statusCode ?? -1))")
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
