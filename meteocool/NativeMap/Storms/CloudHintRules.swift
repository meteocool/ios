//
//  CloudHintRules.swift
//  meteocool
//
//  Which storm cores the flat map tags "3D" (core's `layers/cloudHints.ts`):
//  one per storm, a scan behind its radar or not, one per neighbourhood,
//  current before stale (`lib/staleTint.ts`; its grey is not ported: the
//  storms stay in colour).
//

import Foundation
import MapKit

/// Which tags are drawn, apart from the map (`onePerStorm`, `thin`).
enum CloudHintRules {
    /// Below this the whole country is on screen (`MIN_ZOOM`, exclusive).
    static let minZoom = 5.0
    /// How far apart the tags are kept, in pixels at the whole level's
    /// scale (`SPACING_PX`): two or three to a screen at every zoom, which
    /// says "these have volumes" once per neighbourhood, and the 3D map
    /// shows the rest. Between levels the screen spacing grows to twice it.
    static let spacingPx = 160.0
    /// Peaks are bucketed, so a handful of pills are drawn (`DBZ_STEP`).
    static let dbzStep = 5.0

    struct Tag: Equatable {
        let cloud: RadarVolume
        let stale: Bool
        var peak: Double { cloud.peakDbz ?? 0 }
    }

    /// The strongest tile of each storm, by its `system`, in the order given.
    static func onePerStorm(_ clouds: [RadarVolume]) -> [RadarVolume] {
        var strongest: [String: Int] = [:]
        for (i, cloud) in clouds.enumerated() {
            let storm = cloud.system ?? cloud.path
            if let held = strongest[storm], (cloud.peakDbz ?? 0) <= (clouds[held].peakDbz ?? 0) { continue }
            strongest[storm] = i
        }
        let kept = Set(strongest.values)
        return clouds.indices.filter(kept.contains).map { clouds[$0] }
    }

    /// Current before stale, then the strongest (`tagPrecedence`).
    static func precedes(_ a: Tag, _ b: Tag) -> Bool {
        if a.stale != b.stale { return !a.stale }
        return a.peak > b.peak
    }

    /// Whether a volume is from an older scan than its own network's radar
    /// (`isVolumeBehind`); never when either is unknown.
    static func isBehind(_ cloud: RadarVolume, liveScans: [String: Int]) -> Bool {
        guard let scan = scanTime(cloud.referenceTime), let radar = liveScans[cloud.network.isEmpty ? "de" : cloud.network] else {
            return false
        }
        return scan < radar
    }

    /// A list's or a volume's ISO time as a unix second (`scanTime`).
    static func scanTime(_ value: String) -> Int? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return Int(date.timeIntervalSince1970) }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value).map { Int($0.timeIntervalSince1970) }
    }

    /// The tags kept at `zoom`, in precedence order (`thin`): each at least
    /// the spacing from every one kept before it, at the whole level's
    /// scale, so the same tags stay put while the map pans and change only
    /// as it crosses a level. Spaced that far, no two pills overlap, which
    /// core's declutter would otherwise see to.
    static func thin(_ tags: [Tag], zoom: Double) -> [Tag] {
        let ordered = tags.sorted(by: precedes)
        let level = Int(floor(zoom + 1e-6))
        // A pixel at OpenLayers' zoom, in MapKit's 2^28-point world.
        let spacing = spacingPx * pow(2, Double(20 - level))
        let clear = { (a: MKMapPoint, b: MKMapPoint) in hypot(a.x - b.x, a.y - b.y) >= spacing }
        var kept: [MKMapPoint] = []
        var out: [Tag] = []
        for tag in ordered {
            let p = MKMapPoint(CLLocationCoordinate2D(latitude: tag.cloud.lat, longitude: tag.cloud.lon))
            guard kept.allSatisfy({ clear($0, p) }) else { continue }
            kept.append(p)
            out.append(tag)
        }
        return out
    }
}
