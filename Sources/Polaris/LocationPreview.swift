//
//  LocationPreview.swift
//  Polaris (AppKit rewrite)
//
//  Turns the car's coordinate into something a person can read: a street
//  and town from Apple's reverse geocoder, and a small map from MapKit's
//  snapshotter. Both are Apple system services and both receive the
//  coordinate, which is the one place Polaris sends anything about the car
//  to someone other than Polestar. It's a rounded position of a parked car,
//  sent only while the Data Portal location scope is on, and the README
//  says so.
//
//  Results are cached per position for the life of the process: the car
//  reports the same spot for hours, and a lookup per menu build would be
//  wasteful and, for the geocoder, rate-limited.
//

import AppKit
import Contacts
import CoreLocation
import MapKit

final class LocationPreview {

    static let shared = LocationPreview()

    struct Entry {
        var address: String?
        /// The bare snapshot; the pin and caption are drawn per menu build
        /// because the caption is an age and ages.
        var map: NSImage?
    }

    /// Called on the main queue when a lookup lands, so the menu can be
    /// rebuilt with the address in place of the coordinate.
    var onUpdate: (() -> Void)?

    private var entries: [String: Entry] = [:]
    private var inFlight: Set<String> = []
    private let geocoder = CLGeocoder()

    static let mapSize = NSSize(width: 280, height: 140)

    /// Four decimals is about ten metres: the car re-reporting from the
    /// same bay hits the cache, a different street does not.
    private static func key(_ l: CarLocation, dark: Bool) -> String {
        String(format: "%.4f,%.4f,%@", l.latitude, l.longitude, dark ? "dark" : "light")
    }

    func entry(for location: CarLocation, dark: Bool) -> Entry? {
        entries[Self.key(location, dark: dark)]
    }

    /// Starts whatever is missing for this position. Safe to call on every
    /// menu build; it returns at once when the entry is complete or pending.
    func prepare(_ location: CarLocation, dark: Bool) {
        let key = Self.key(location, dark: dark)
        let have = entries[key] ?? Entry()
        guard have.address == nil || have.map == nil, !inFlight.contains(key) else { return }
        inFlight.insert(key)

        let group = DispatchGroup()
        var entry = have
        let coordinate = CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)

        if entry.address == nil {
            group.enter()
            geocoder.reverseGeocodeLocation(CLLocation(latitude: location.latitude,
                                                       longitude: location.longitude)) { placemarks, _ in
                DispatchQueue.main.async {
                    entry.address = placemarks?.first.flatMap(Self.describe)
                    group.leave()
                }
            }
        }

        if entry.map == nil {
            group.enter()
            let options = MKMapSnapshotter.Options()
            options.region = MKCoordinateRegion(center: coordinate,
                                                latitudinalMeters: 500, longitudinalMeters: 500)
            options.size = Self.mapSize
            options.pointOfInterestFilter = .excludingAll
            options.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            MKMapSnapshotter(options: options).start(with: .main) { snapshot, _ in
                entry.map = snapshot.map { Self.pinned($0, at: coordinate) }
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.entries[key] = entry
            self.inFlight.remove(key)
            // A lookup that failed is retried on the next build; one that
            // succeeded is what the menu has been waiting for.
            if entry.address != nil || entry.map != nil { self.onUpdate?() }
        }
    }

    // MARK: - Rendering

    /// "Hjallesevej 12, Odense" — the first line of the postal address in
    /// the locale's own order (number before or after the street), and the
    /// town. Falls back to whatever the placemark can offer.
    static func describe(_ placemark: CLPlacemark) -> String? {
        var street: String?
        if let postal = placemark.postalAddress {
            street = CNPostalAddressFormatter().string(from: postal)
                .components(separatedBy: "\n").first?
                .trimmingCharacters(in: .whitespaces)
        }
        if street?.isEmpty != false {
            street = [placemark.thoroughfare, placemark.subThoroughfare].compactMap { $0 }.joined(separator: " ")
        }
        let parts = [street, placemark.locality ?? placemark.subAdministrativeArea]
            .compactMap { $0 }.filter { !$0.isEmpty }
        if parts.isEmpty { return placemark.name }
        // A town-only answer for a rural spot is still better than a coordinate.
        return parts.joined(separator: ", ")
    }

    /// The snapshot with a marker at the car's position.
    private static func pinned(_ snapshot: MKMapSnapshotter.Snapshot, at coordinate: CLLocationCoordinate2D) -> NSImage {
        let image = NSImage(size: snapshot.image.size)
        image.lockFocus()
        snapshot.image.draw(in: NSRect(origin: .zero, size: image.size))
        let p = snapshot.point(for: coordinate)
        // AppKit's origin is bottom-left; the snapshot's point is top-left.
        let centre = NSPoint(x: p.x, y: image.size.height - p.y)
        let outer = NSBezierPath(ovalIn: NSRect(x: centre.x - 8, y: centre.y - 8, width: 16, height: 16))
        NSColor.white.setFill(); outer.fill()
        let inner = NSBezierPath(ovalIn: NSRect(x: centre.x - 5.5, y: centre.y - 5.5, width: 11, height: 11))
        NSColor.controlAccentColor.setFill(); inner.fill()
        image.unlockFocus()
        return image
    }

    /// The map with an age caption in the corner, when the reading is old
    /// enough to need one. Drawn fresh per build; cheap, no network.
    static func captioned(_ map: NSImage, caption: String) -> NSImage {
        guard !caption.isEmpty else { return map }
        let image = NSImage(size: map.size)
        image.lockFocus()
        map.draw(in: NSRect(origin: .zero, size: map.size))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let text = NSAttributedString(string: caption, attributes: attributes)
        let size = text.size()
        let pad: CGFloat = 5
        let box = NSRect(x: map.size.width - size.width - pad * 2 - 6, y: 6,
                         width: size.width + pad * 2, height: size.height + 4)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        text.draw(at: NSPoint(x: box.minX + pad, y: box.minY + 2))
        image.unlockFocus()
        return image
    }
}
