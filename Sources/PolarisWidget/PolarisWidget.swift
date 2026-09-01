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

/// Why there's nothing to draw. Only the first of these is a state a user
/// can be in; the other two mean the build or the container is wrong, and
/// saying so is faster than reading logs.
enum WidgetProblem {
    case nothingPolledYet
    case noContainer
    case unreadable(String)
}

struct CarEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    let carImage: Image?
    let problem: WidgetProblem?
}

struct CarProvider: TimelineProvider {

    /// The gallery preview, and what's on screen for the instant before the
    /// real snapshot loads. Plausible numbers rather than zeroes, because a
    /// widget showing 0% in the picker looks broken.
    private var placeholderEntry: CarEntry {
        CarEntry(date: Date(), snapshot: .placeholder, carImage: nil, problem: nil)
    }

    private func currentEntry(family: WidgetFamily) -> CarEntry {
        let snapshot: WidgetSnapshot?
        let problem: WidgetProblem?
        switch SharedStore.snapshotState() {
        case .ok(let value): snapshot = value; problem = nil
        case .noFile: snapshot = nil; problem = .nothingPolledYet
        case .noContainer: snapshot = nil; problem = .noContainer
        case .unreadable(let why): snapshot = nil; problem = .unreadable(why)
        }

        var image: Image?
        // Only the large widget draws the car, and only it pays for loading
        // it: an extension has a hard memory ceiling, and a studio render is
        // several megabytes of PNG that decodes to a great deal more.
        if family != .systemSmall, snapshot?.hasImage == true {
            image = Self.carImage()
        }
        return CarEntry(date: Date(), snapshot: snapshot, carImage: image, problem: problem)
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

    /// The widget picker asks for this one. Real data if we have it — seeing
    /// your own car in the gallery is the point of the thing — and the
    /// invented one only when there's nothing to show yet.
    func getSnapshot(in context: Context, completion: @escaping (CarEntry) -> Void) {
        let entry = currentEntry(family: context.family)
        completion(entry.snapshot == nil && context.isPreview ? placeholderEntry : entry)
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
        // Eight minutes old, not this instant: a preview built at "now"
        // renders its timestamp as "in 0 sec", which reads like a bug in the
        // widget picker where first impressions are made.
        carReportedAt: nil, writtenAt: Date().addingTimeInterval(-8 * 60),
        unit: .kilometers, hasImage: false
    )

    /// Green while charging, orange when it's time to worry, and otherwise
    /// the accent the user chose in System Settings — the same three states
    /// the menu reads by.
    var tint: Color {
        if isCharging { return .green }
        if batteryPercentage <= 20 { return .orange }
        return .accentColor
    }

    var percentText: String {
        String(format: "%.0f%%", batteryPercentage)
    }

    /// "Polestar 4 · 2026" when the car said so; the app writes an empty
    /// string when it knows neither.
    var displayTitle: String {
        if let carTitle, !carTitle.isEmpty { return carTitle }
        return "Polaris"
    }

    /// What the car itself last said, falling back to when we wrote the file.
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
        // The boxed variant, not the bare glyph: on its own the P reads as a
        // stray letter next to the status word rather than as a sign.
        return "parkingsign.square"
    }

    var body: some View {
        Label(snapshot.statusText, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(.caption)
            .foregroundStyle(snapshot.isCharging ? Color.green : Color.secondary)
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
    let problem: WidgetProblem

    private var isNormal: Bool {
        if case .nothingPolledYet = problem { return true }
        return false
    }

    // Only the first case is translated. The other two cannot happen in a
    // released build — they mean the app was built or installed wrong — and
    // they are addressed to whoever built it, not to anyone driving the car.
    private var title: String {
        switch problem {
        case .nothingPolledYet: return L("No data yet")
        case .noContainer: return "No container"
        case .unreadable: return "Can't read the snapshot"
        }
    }

    private var detail: String {
        switch problem {
        case .nothingPolledYet: return L("Open Polaris to sign in")
        case .noContainer: return "The App Group didn't resolve"
        case .unreadable(let why): return why
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: isNormal ? "bolt.car" : "exclamationmark.triangle")
                .font(.title)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.7)
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
                // .relative(presentation:) rather than the .relative *style*,
                // which renders "5 hrs, 31 min" — indistinguishable from a
                // time to full on a car that happens to be charging.
                Text(snapshot.asOf, format: .relative(presentation: .numeric,
                                                      unitsStyle: .narrow))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Medium

/// The size most people actually keep on a desktop: the car beside the
/// numbers rather than above them. Everything the small one shows, with room
/// for the render and no scrolling of the eye.
struct MediumCarView: View {
    let snapshot: WidgetSnapshot
    let carImage: Image?

    var body: some View {
        HStack(spacing: 14) {
            if let carImage {
                carImage
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 150, maxHeight: 104)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.displayTitle)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                Spacer(minLength: 2)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(snapshot.percentText)
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(snapshot.rangeText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                BatteryBar(fraction: snapshot.batteryPercentage / 100, tint: snapshot.tint)
                    .padding(.vertical, 3)

                Spacer(minLength: 2)

                HStack(spacing: 4) {
                    StatusLabel(snapshot: snapshot)
                    Spacer(minLength: 0)
                    Text(snapshot.asOf, format: .relative(presentation: .numeric,
                                                          unitsStyle: .narrow))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Large

struct LargeCarView: View {
    let snapshot: WidgetSnapshot
    let carImage: Image?

    /// Everything the car actually reported, in the order it matters. Rows
    /// the car said nothing about are left out rather than shown empty.
    /// Range and status are already on the face of the widget, above this
    /// grid — repeating them here filled two of the four slots with things
    /// the eye had just read.
    private var fields: [Field] {
        var rows: [Field] = []
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(snapshot.displayTitle)
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
            // in a frame of its own. It is given no fixed height: it takes
            // whatever the rows below leave, which is most of the card on an
            // idle car and less once charging adds a second row to the grid.
            if let carImage {
                carImage
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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

            // With a render above, the slack belongs to it and the timestamp
            // follows the grid. Without one there is nothing to grow, so the
            // spacer goes back in to hold the timestamp at the bottom edge.
            if carImage == nil {
                Spacer(minLength: 0)
            }

            HStack(spacing: 4) {
                Text(L("Updated"))
                Text(snapshot.asOf, format: .relative(presentation: .numeric,
                                                      unitsStyle: .abbreviated))
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
                case .systemSmall:
                    SmallCarView(snapshot: snapshot)
                case .systemMedium:
                    MediumCarView(snapshot: snapshot, carImage: entry.carImage)
                default:
                    LargeCarView(snapshot: snapshot, carImage: entry.carImage)
                }
            } else {
                NoData(problem: entry.problem ?? .nothingPolledYet)
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
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct PolarisWidgetBundle: WidgetBundle {
    var body: some Widget {
        PolarisCarWidget()
    }
}
