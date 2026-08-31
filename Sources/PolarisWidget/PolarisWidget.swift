//
//  PolarisWidget.swift
//  Polaris
//
//  Spike. This widget shows no car data on purpose — its only job is to
//  answer the one question that decides whether a widget is possible at
//  all: does a Developer ID build survive notarization with an App Group
//  entitlement, and can the sandboxed extension actually reach the shared
//  container at runtime? Everything it renders is the answer to that.
//
//  The real widget will read a snapshot the app writes into this container
//  and never call PolestarAPI itself. Two processes refreshing the same
//  OAuth token independently is the failure mode worth designing out.
//

import WidgetKit
import SwiftUI

/// On macOS an App Group identifier has to carry the Team ID prefix, which
/// belongs in a secret rather than in source. The Makefile substitutes the
/// assembled identifier into the appex's Info.plist at build time, and it
/// is read back here — a build without a Team ID gets no group at all, and
/// says so rather than resolving something plausible and wrong.
private var appGroup: String? {
    let value = Bundle.main.object(forInfoDictionaryKey: "PolarisAppGroup") as? String
    return (value?.isEmpty ?? true) ? nil : value
}

/// Resolve the shared container and write to it. Resolving alone isn't
/// proof: an unauthorized entitlement can still hand back a URL, and the
/// write is what fails.
private func probeContainer() -> String {
    guard let group = appGroup else {
        return "No App Group — built without a Team ID."
    }
    guard let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: group) else {
        return "Entitlement rejected — no container for \(group)"
    }
    let probe = url.appendingPathComponent("widget-probe.txt")
    do {
        try ISO8601DateFormatter().string(from: Date())
            .write(to: probe, atomically: true, encoding: .utf8)
        return "Container writable\n\(url.path)"
    } catch {
        return "Resolved but not writable\n\(error.localizedDescription)"
    }
}

struct ProbeEntry: TimelineEntry {
    let date: Date
    let result: String
}

struct ProbeProvider: TimelineProvider {
    func placeholder(in context: Context) -> ProbeEntry {
        ProbeEntry(date: Date(), result: "Checking…")
    }

    func getSnapshot(in context: Context, completion: @escaping (ProbeEntry) -> Void) {
        completion(ProbeEntry(date: Date(), result: probeContainer()))
    }

    // .never: the probe is a one-shot answer, not something to poll.
    func getTimeline(in context: Context, completion: @escaping (Timeline<ProbeEntry>) -> Void) {
        let entry = ProbeEntry(date: Date(), result: probeContainer())
        completion(Timeline(entries: [entry], policy: .never))
    }
}

struct ProbeView: View {
    let entry: ProbeEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Polaris spike")
                .font(.headline)
            Text(entry.result)
                .font(.caption)
                .monospaced()
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetBackground()
    }
}

private extension View {
    /// macOS 14 requires a widget to declare its own background; 13 doesn't
    /// have the modifier at all. The deployment target is still 13.
    @ViewBuilder
    func widgetBackground() -> some View {
        if #available(macOS 14.0, *) {
            self.containerBackground(.fill.tertiary, for: .widget)
        } else {
            self.padding()
        }
    }
}

struct PolarisProbeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PolarisProbe", provider: ProbeProvider()) { entry in
            ProbeView(entry: entry)
        }
        .configurationDisplayName("Polaris (spike)")
        .description("Reports whether the shared container is reachable.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct PolarisWidgetBundle: WidgetBundle {
    var body: some Widget {
        PolarisProbeWidget()
    }
}
