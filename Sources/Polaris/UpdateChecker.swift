//
//  UpdateChecker.swift
//  Polaris (AppKit rewrite)
//
//  Once-a-day check against GitHub's releases API. No Sparkle, no
//  auto-download — a newer release just surfaces as a menu item that
//  opens the releases page.
//

import Foundation

final class UpdateChecker {

    private static let latestReleaseAPI =
        URL(string: "https://api.github.com/repos/simonbusborg/polaris/releases/latest")!
    static let releasesPage =
        URL(string: "https://github.com/simonbusborg/polaris/releases/latest")!

    private var lastCheck: Date? {
        get { UserDefaults.standard.object(forKey: "last_update_check") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "last_update_check") }
    }

    /// Calls `onUpdateFound` on the main thread when a newer release exists.
    func checkIfDue(onUpdateFound: @escaping (String) -> Void) {
        if let last = lastCheck, Date().timeIntervalSince(last) < 86_400 { return }
        lastCheck = Date()

        Task {
            var request = URLRequest(url: Self.latestReleaseAPI)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String
            else { return }

            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            if Self.isVersion(latest, newerThan: current) {
                await MainActor.run { onUpdateFound(latest) }
            }
        }
    }

    /// Numeric dotted-version comparison: "1.10.0" is newer than "1.9.1".
    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
