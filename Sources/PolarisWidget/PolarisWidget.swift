//
//  PolarisWidget.swift
//  Polaris
//
//  The desktop face of Polaris. It reads the snapshot the app wrote into the
//  shared container and draws it — it never talks to Polestar. Two processes
//  refreshing the same OAuth session would race each other's token refresh
//  and one of them would get signed out, so the widget is deliberately a
//  view of the app's last poll rather than a second client.
//
//  Nothing here can make data appear: if Polaris hasn't run and polled, the
//  widget says so instead of inventing a state.
//

import WidgetKit
import SwiftUI
import AppKit
import ImageIO
import PolarisShared

// MARK: - Timeline

struct CarEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    let carImage: Image?
    /// Whether the shared container resolved at all. Without it there is
    /// nowhere to read from, which is a different problem from an app that
    /// simply hasn't polled yet — and the two used to render identically.
    let hasContainer: Bool
}

struct CarProvider: TimelineProvider {

    /// The gallery preview, and what's on screen for the instant before the
    /// real snapshot loads. Plausible numbers rather than zeroes, because a
    /// widget showing 0% in the picker looks broken.
    private var placeholderEntry: CarEntry {
        CarEntry(date: Date(), snapshot: .placeholder, carImage: nil, hasContainer: true)
    }

    private func currentEntry(family: WidgetFamily) -> CarEntry {
        let snapshot = SharedStore.loadSnapshot()
        var image: Image?
        // Only the large widget draws the car, and only it pays for loading
        // it: an extension has a hard memory ceiling, and a studio render is
        // several megabytes of PNG that decodes to a great deal more.
        if family != .systemSmall, snapshot?.hasImage == true {
            image = Self.carImage()
        }
        return CarEntry(date: Date(), snapshot: snapshot, carImage: image,
                        hasContainer: SharedStore.containerURL != nil)
    }

    /// Decoded straight to the size it's drawn at. ImageIO reads the header
    /// and produces the thumbnail without ever holding the full-resolution
    /// bitmap, which is the difference between a widget that renders and one
    /// the system kills for using too much memory.
    private static func carImage(maxPixels: Int = 800) -> Image? {
        guard let data = SharedStore.loadImage(),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source, 0, options as CFDictionary) else { return nil }
        return Image(nsImage: NSImage(cgImage: thumbnail, size: .zero))
    }

    func placeholder(in context: Context) -> CarEntry { placeholderEntry }

    func getSnapshot(in context: Context, completion: @escaping (CarEntry) -> Void) {
        completion(context.isPreview ? placeholderEntry : currentEntry(family: context.family))
    }

    /// The app reloads the timeline whenever it writes something new, so this
    /// schedule is only a safety net for a snapshot written while the widget
    /// process wasn't around to be told.
    func getTimeline(in context: Context, completion: @escaping (Timeline<CarEntry>) -> Void) {
        let next = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [currentEntry(family: context.family)],
                            policy: .after(next)))
    }
}

// MARK: - Pieces

private extension WidgetSnapshot {
    static let placeholder = WidgetSnapshot(
        batteryPercentage: 78, rangeKm: 412, statusKey: "IDLE",
        isDriving: false, isPluggedIn: false, fullInMinutes: nil,
        chargingPowerWatts: nil, carTitle: "Polestar 4 · 2026",
        modelName: "Polestar 4", registrationNo: nil, odometerKm: 23412,
        carReportedAt: nil, writtenAt: Date(), unit: .kilometers, hasImage: false
    )

    /// Green while charging, orange when it's time to worry — the same three
    /// states the menu bar icon uses.
    var tint: Color {
        if isCharging { return .green }
        if batteryPercentage <= 20 { return .orange }
        return .accentColor
    }

    var percentText: String {
        String(format: "%.0f%%", batteryPercentage)
    }

    /// What the car itself last said, falling back to when we wrote the file.
    /// Shown as a relative date so it keeps counting without a reload.
    var asOf: Date { carReportedAt ?? writtenAt }
}

/// A flat capacity bar. Deliberately not a Gauge: those pick up the system
/// accent styling and stop matching the tint the state actually calls for.
private struct BatteryBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(tint)
                    .frame(width: max(2, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 6)
    }
}

private struct StatusLabel: View {
    let snapshot: WidgetSnapshot

    private var symbol: String {
        if snapshot.isCharging { return "bolt.fill" }
        if snapshot.isDriving { return "steeringwheel" }
        if snapshot.isPluggedIn == true { return "powerplug.fill" }
        return "parkingsign"
    }

    var body: some View {
        Label(snapshot.statusText, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(.caption)
            .foregroundStyle(snapshot.isCharging ? Color.green : .secondary)
    }
}

/// One key/value pair on the large widget. A struct rather than a tuple
/// because ForEach needs something identifiable to key on.
private struct Field: View, Identifiable {
    let key: String
    let value: String
    var id: String { key }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(key)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.callout)
                .fontWeight(.medium)
        }
    }
}

private struct NoData: View {
    let hasContainer: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: hasContainer ? "bolt.car" : "exclamationmark.triangle")
                .font(.title)
                .foregroundStyle(.secondary)
            if hasContainer {
                Text(L("No data yet"))
                    .font(.headline)
                Text(L("Open Polaris to sign in"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                // Deliberately not translated: no released build can show
                // this — it means the app was built without a Team ID, so
                // there is no App Group to read through. It is a message to
                // whoever built it, not to a user.
                Text("No App Group")
                    .font(.headline)
                Text("Built without a Team ID")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Small

struct SmallCarView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let name = snapshot.modelName, !name.isEmpty {
                Text(name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Text(snapshot.percentText)
                .font(.system(size: 38, weight: .semibold, design: .rounded))
                .minimumScaleFactor(0.6)
                .lineLimit(1)

            BatteryBar(fraction: snapshot.batteryPercentage / 100, tint: snapshot.tint)
                .padding(.vertical, 4)

            Text(snapshot.rangeText)
                .font(.headline)

            Spacer(minLength: 4)

            HStack(spacing: 4) {
                StatusLabel(snapshot: snapshot)
                Spacer(minLength: 0)
                Text(snapshot.asOf, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Large

struct LargeCarView: View {
    let snapshot: WidgetSnapshot
    let carImage: Image?

    /// Everything the car actually reported, in the order it matters. Rows
    /// the car said nothing about are left out rather than shown empty.
    private var fields: [Field] {
        var rows = [
            Field(key: L("Range"), value: snapshot.rangeText),
            Field(key: L("Status"), value: snapshot.statusText)
        ]
        if snapshot.isCharging, let minutes = snapshot.fullInMinutes {
            rows.append(Field(key: L("Full in"),
                              value: CarFormat.shortDuration(minutes: minutes)))
        }
        if let watts = snapshot.chargingPowerWatts, watts > 0 {
            rows.append(Field(key: L("Power"), value: CarFormat.kilowatts(watts: watts)))
        }
        if let plugged = snapshot.isPluggedIn {
            rows.append(Field(key: L("Charger"),
                              value: plugged ? L("Connected") : L("Disconnected")))
        }
        if let odometer = snapshot.odometerKm {
            rows.append(Field(key: L("Odometer"),
                              value: CarFormat.distance(km: odometer, grouped: true,
                                                        unit: snapshot.unit)))
        }
        return rows
    }

    /// "Polestar 4 · 2026" when the car said so; the app writes an empty
    /// string when it knows neither.
    private var title: String {
        if let title = snapshot.carTitle, !title.isEmpty { return title }
        return "Polaris"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    if let plate = snapshot.registrationNo, !plate.isEmpty {
                        Text(plate)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 8)
                StatusLabel(snapshot: snapshot)
            }

            // The render is a transparent studio PNG of this exact
            // configuration, so it sits on the widget background rather than
            // in a frame of its own.
            if let carImage {
                carImage
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 96)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(snapshot.percentText)
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                Text(snapshot.rangeText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            BatteryBar(fraction: snapshot.batteryPercentage / 100, tint: snapshot.tint)

            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 8) {
                ForEach(fields) { $0 }
            }

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                Text(L("Updated"))
                Text(snapshot.asOf, style: .relative)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Widget

struct PolarisWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CarEntry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                switch family {
                case .systemSmall: SmallCarView(snapshot: snapshot)
                default: LargeCarView(snapshot: snapshot, carImage: entry.carImage)
                }
            } else {
                NoData(hasContainer: entry.hasContainer)
            }
        }
        .widgetURL(URL(string: "polaris://open"))
        .widgetBackground()
    }
}

private extension View {
    /// macOS 14 requires a widget to declare its own background; 13 doesn't
    /// have the modifier at all, and the deployment target is still 13.
    @ViewBuilder
    func widgetBackground() -> some View {
        if #available(macOS 14.0, *) {
            self.containerBackground(.fill.tertiary, for: .widget)
        } else {
            self.padding()
        }
    }
}

struct PolarisCarWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PolarisCar", provider: CarProvider()) { entry in
            PolarisWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Polaris")
        .description(L("Battery, range and charging status for your Polestar."))
        .supportedFamilies([.systemSmall, .systemLarge])
    }
}

@main
struct PolarisWidgetBundle: WidgetBundle {
    var body: some Widget {
        PolarisCarWidget()
    }
}
