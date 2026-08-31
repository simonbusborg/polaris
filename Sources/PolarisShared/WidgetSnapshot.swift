//
//  WidgetSnapshot.swift
//  PolarisShared
//
//  The one channel between Polaris and its widget. The app writes what it
//  has just fetched; the widget only ever reads. That direction is the whole
//  design: an extension refreshing on its own would mean two processes
//  holding the same OAuth session and racing each other's token refresh, and
//  the loser gets signed out. The widget is a view of the app's last poll,
//  never a second client.
//

import Foundation

/// What the widget needs to draw itself, and nothing more — no VIN, no
/// tokens, no account. The container is readable by anything in the app
/// group, so it stays free of anything worth stealing.
public struct WidgetSnapshot: Codable, Equatable {
    public var batteryPercentage: Double
    public var rangeKm: Int
    /// Charging status with the API's prefixes already stripped, e.g. "IDLE".
    public var statusKey: String
    public var isDriving: Bool
    public var isPluggedIn: Bool?
    public var fullInMinutes: Int?
    public var chargingPowerWatts: Int?
    /// "Polestar 4 · 2026" — whatever the menu calls this car.
    public var carTitle: String?
    /// Just "Polestar 4". The small widget has no room for the model year.
    public var modelName: String?
    public var registrationNo: String?
    public var odometerKm: Int?
    /// When the car itself last reported, which is what the widget shows.
    /// A garaged car can be hours stale, and hiding that would be a lie.
    public var carReportedAt: Date?
    public var writtenAt: Date
    public var unit: DistanceUnit
    public var hasImage: Bool

    public init(batteryPercentage: Double, rangeKm: Int, statusKey: String,
                isDriving: Bool, isPluggedIn: Bool?, fullInMinutes: Int?,
                chargingPowerWatts: Int?, carTitle: String?, modelName: String?,
                registrationNo: String?,
                odometerKm: Int?, carReportedAt: Date?, writtenAt: Date,
                unit: DistanceUnit, hasImage: Bool) {
        self.batteryPercentage = batteryPercentage
        self.rangeKm = rangeKm
        self.statusKey = statusKey
        self.isDriving = isDriving
        self.isPluggedIn = isPluggedIn
        self.fullInMinutes = fullInMinutes
        self.chargingPowerWatts = chargingPowerWatts
        self.carTitle = carTitle
        self.modelName = modelName
        self.registrationNo = registrationNo
        self.odometerKm = odometerKm
        self.carReportedAt = carReportedAt
        self.writtenAt = writtenAt
        self.unit = unit
        self.hasImage = hasImage
    }

    public var isCharging: Bool {
        statusKey == "CHARGING" || statusKey == "SMART_CHARGING"
    }

    /// Driving wins over the charging status, which stays IDLE while the car
    /// is moving — the same inference the menu bar makes.
    public var statusText: String {
        isDriving ? L("In use") : CarFormat.humanStatus(statusKey)
    }

    public var rangeText: String {
        CarFormat.distance(km: rangeKm, unit: unit)
    }

    /// Ignores `writtenAt`, so a poll that changed nothing doesn't count as
    /// a change. The app uses this to decide whether to spend a widget
    /// reload — every five minutes, forever, on identical data would be
    /// nothing but battery.
    public func sameData(as other: WidgetSnapshot) -> Bool {
        var mine = self
        mine.writtenAt = other.writtenAt
        return mine == other
    }
}

/// The app group container, and the two files in it.
public enum SharedStore {

    private static let snapshotName = "snapshot.json"
    private static let imageName = "car.png"

    /// On macOS an App Group identifier carries the Team ID prefix, which is
    /// a secret rather than something to hard-code. The Makefile substitutes
    /// the assembled identifier into both Info.plists at build time and it is
    /// read back here — a build without a Team ID has no group at all, and
    /// every call below turns into a no-op rather than a wrong guess.
    public static var appGroup: String? {
        let value = Bundle.main.object(forInfoDictionaryKey: "PolarisAppGroup") as? String
        return (value?.isEmpty ?? true) ? nil : value
    }

    public static var containerURL: URL? {
        guard let group = appGroup else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Why the widget has nothing to draw. An empty widget with one face for
    /// four different causes is what made the first round of this a guessing
    /// game, so the reason travels with the failure.
    public enum SnapshotState {
        case ok(WidgetSnapshot)
        /// No App Group at all — built without a Team ID.
        case noContainer
        /// The container is there but the app has never written to it.
        case noFile
        /// Written, but this build can't read it: a format the app and the
        /// widget disagree about, or a sandbox refusing the read.
        case unreadable(String)
    }

    public static func snapshotState() -> SnapshotState {
        guard let url = containerURL?.appendingPathComponent(snapshotName) else {
            return .noContainer
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return .noFile }
        do {
            return .ok(try decoder.decode(WidgetSnapshot.self, from: Data(contentsOf: url)))
        } catch {
            return .unreadable(String(describing: error).prefix(120).description)
        }
    }

    public static func loadSnapshot() -> WidgetSnapshot? {
        if case .ok(let snapshot) = snapshotState() { return snapshot }
        return nil
    }

    /// Atomic because the widget can wake up mid-write; a half-written file
    /// would decode to nil and blank the widget for one refresh.
    public static func save(_ snapshot: WidgetSnapshot) throws {
        guard let url = containerURL?.appendingPathComponent(snapshotName) else { return }
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    public static func loadImage() -> Data? {
        guard let url = containerURL?.appendingPathComponent(imageName) else { return nil }
        return try? Data(contentsOf: url)
    }

    public static var hasImage: Bool {
        guard let url = containerURL?.appendingPathComponent(imageName) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    public static func removeImage() {
        guard let url = containerURL?.appendingPathComponent(imageName) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    public static func saveImage(_ data: Data) throws {
        guard let url = containerURL?.appendingPathComponent(imageName) else { return }
        try data.write(to: url, options: .atomic)
    }

    /// Signing out or removing the last car has to take the car off the
    /// desktop too — a widget still showing 78% for a car you no longer have
    /// is worse than an empty one.
    public static func clear() {
        guard let container = containerURL else { return }
        for name in [snapshotName, imageName] {
            try? FileManager.default.removeItem(at: container.appendingPathComponent(name))
        }
    }
}
