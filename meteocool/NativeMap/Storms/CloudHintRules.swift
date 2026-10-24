//
//  CloudHintRules.swift
//  meteocool
//
//  Which storm cores the flat map tags "3D" (core's `layers/cloudHints.ts`):
//  one per storm, a scan behind its radar or not, thinned at a wide zoom.
//

import Foundation
import MapKit

/// Which tags are drawn, apart from the map (`onePerStorm`, `thin`).
enum CloudHintRules {
    /// Below this the whole country is on screen (`MIN_ZOOM`, exclusive).
    static let minZoom = 5.0
    /// How far apart the tags are kept at a wide zoom, in pixels at the
    /// whole level's scale (`SPACING_PX`); from 9 only overlap counts.
    static let spacingPx: [Int: Double] = [5: 128, 6: 96, 7: 67, 8: 42]
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

    /// A pill's size in points (`pillSvg`), which close up only overlap.
    static let pill = (width: 34.0, height: 18.0)

    /// The tags kept at `zoom`, in precedence order (`thin`, `declutter`):
    /// to zoom 8 each at least the whole level's spacing from every one kept
    /// before it, so the same tags stay put while the map pans; from 9 any
    /// that would not overlap one kept before, at the zoom shown.
    static func thin(_ tags: [Tag], zoom: Double) -> [Tag] {
        let ordered = tags.sorted(by: precedes)
        let level = Int(floor(zoom + 1e-6))
        // A pixel at OpenLayers' zoom, in MapKit's 2^28-point world.
        let clear: (MKMapPoint, MKMapPoint) -> Bool
        if let px = spacingPx[max(level, Int(minZoom))] {
            let spacing = px * pow(2, Double(20 - level))
            clear = { hypot($0.x - $1.x, $0.y - $1.y) >= spacing }
        } else {
            let point = pow(2, 20 - zoom)
            clear = { abs($0.x - $1.x) >= pill.width * point || abs($0.y - $1.y) >= pill.height * point }
        }
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
