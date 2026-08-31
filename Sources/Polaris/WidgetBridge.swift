//
//  WidgetBridge.swift
//  Polaris (AppKit rewrite)
//
//  Publishes each poll to the shared container so the widget has something
//  to draw. Everything here is best-effort: a build with no App Group (no
//  Team ID at build time) writes nothing, and the app carries on exactly as
//  it did before the widget existed.
//

import Foundation
import WidgetKit
import PolarisShared

enum WidgetBridge {

    private static var lastWritten: WidgetSnapshot?
    /// Byte count of the render already in the container. The image is a
    /// megabyte of PNG that only changes when the car does, so it is written
    /// once and then left alone.
    private static var lastImageBytes: Int?

    static func publish(_ data: CarData) {
        guard SharedStore.containerURL != nil else { return }

        if let image = data.imageData {
            if image.count != lastImageBytes {
                do {
                    try SharedStore.saveImage(image)
                    lastImageBytes = image.count
                } catch {
                    // Not worth surfacing: the widget falls back to a symbol.
                    lastImageBytes = nil
                }
            }
        } else {
            // Switching cars empties the render until the new one downloads.
            // Better a blank space than the previous car on the desktop.
            SharedStore.removeImage()
            lastImageBytes = nil
        }

        let snapshot = WidgetSnapshot(
            batteryPercentage: data.batteryPercentage,
            rangeKm: data.rangeKm,
            statusKey: data.statusKey,
            isDriving: data.isDriving,
            isPluggedIn: data.isPluggedIn,
            fullInMinutes: data.estimatedChargingTimeToFullMinutes,
            chargingPowerWatts: data.grpcExtras?.chargingPowerWatts,
            carTitle: [data.modelName, data.modelYear].compactMap { $0 }.joined(separator: " · "),
            modelName: data.modelName,
            registrationNo: data.registrationNo,
            odometerKm: data.odometerKm,
            carReportedAt: data.carReportedAt,
            writtenAt: Date(),
            unit: Preferences.distanceUnit,
            hasImage: SharedStore.hasImage
        )

        // A poll every five minutes that changed nothing is not worth a
        // reload — the timestamp on the widget's face keeps ticking on its
        // own, because it's rendered as a relative date rather than baked in.
        if let last = lastWritten, snapshot.sameData(as: last) { return }

        do {
            try SharedStore.save(snapshot)
            lastWritten = snapshot
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            NSLog("Polaris: couldn't write the widget snapshot — \(error.localizedDescription)")
        }
    }

    /// Called when the last car goes away. A widget still cheerfully showing
    /// 78% for a car you just signed out of is worse than an empty one.
    static func clear() {
        lastWritten = nil
        lastImageBytes = nil
        SharedStore.clear()
        WidgetCenter.shared.reloadAllTimelines()
    }
}
