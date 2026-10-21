//
//  PointRules.swift
//  meteocool
//
//  The rules behind a held point: when a hold counts, where the point menu
//  goes, how a point is written in a link, and whether the radar is dry
//  there.
//

import Foundation

/// core's hold on the map (`lib/LayerManager.ts:81-82`): this long without
/// moving further than this, in screen points, asks about the point.
enum LongPress {
    static let duration: TimeInterval = 0.45
    static let slop: Double = 10
}

/// Where the point menu goes around the held point, so it stays on screen
/// (core's `PointMenu.svelte:38-51, 90-114`): above the point, or below it
/// near the top, leaning inwards near either side with the notch and the dot
/// still on the point.
///
/// No app dependencies here: `scripts/check.sh` compiles this file alone.
enum PointMenuLayout {
    /// Room the menu needs above the point, and to either side of it.
    static let needsAbove = 170.0
    static let needsSide = 120.0
    /// More above it for the share row: a row's height.
    static let shareEntry = 56.0
    /// How far past the point the menu's edge goes when it leans: clear of
    /// its 20 pt corner, so the notch comes off a straight edge.
    static let lean = 30.0
    static let notchHalf = 9.0
    static let dotHalf = 7.0
    /// The card's width, at least and at most.
    static let minWidth = 232.0
    static let maxWidth = 280.0

    enum Side: Equatable, Sendable { case left, center, right }

    struct Placement: Equatable, Sendable {
        /// Under the point, notch up, rather than over it.
        let below: Bool
        let side: Side
        /// How far in from the card's leaning edge the point is.
        let lean: Double
    }

    /// `x`, `y`: the point in the map view; `width`: the map view's.
    /// `menuHeight`: the menu as laid out, which grows with the text size
    /// (core's fixed room when unknown). `safeTop`, `bottom`: where the map
    /// view's safe area starts and ends, so the menu never goes under the
    /// status bar or the home indicator. Over the point while it fits there,
    /// else under it where there is more room.
    static func placement(x: Double, y: Double, width: Double, shareAvailable: Bool,
                          menuHeight: Double? = nil, safeTop: Double = 0, bottom: Double = .infinity) -> Placement {
        let needed = menuHeight.map { $0 + dotHalf + 8 } ?? needsAbove + (shareAvailable ? shareEntry : 0)
        let above = y - safeTop
        let below = above < needed && bottom - y > above
        let side: Side = x < needsSide ? .left : (x > width - needsSide ? .right : .center)
        let room = side == .left ? x - 8 : width - x - 8
        return Placement(below: below, side: side, lean: side == .center ? 0 : max(0, min(lean, room)))
    }
}

/// The parts of core's links (`lib/deepLink.ts`) a held point and the other
/// maps read and write: `layer`, `point`, and the order core writes them in.
///
/// No app dependencies here: `scripts/check.sh` compiles this file alone.
enum PointLink {
    /// The parameters core owns, in the order it writes them; anything else
    /// (`share_lang`) goes first, in its own order.
    static let order = ["layer", "latLonZ", "pitch", "bearing", "overlays", "t", "point", "storm", "cell", "details",
                        "cloud", "cut", "shared"]

    /// A `layer=` value worth looking up (core's `LAYER`): a plain word.
    static func validLayer(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 32 && text.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
    }

    /// A number as JavaScript's `Number()` reads a link's value; nil for
    /// anything that is not one.
    static func finite(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let value = Double(trimmed), value.isFinite else { return nil }
        return value
    }

    /// `point=lat,lon` (core's `parsePair`): both valid, or nothing.
    static func parsePair(_ text: String?) -> (latitude: Double, longitude: Double)? {
        let parts = (text ?? "").split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, let lat = finite(parts[0]), let lon = finite(parts[1]),
              (-90 ... 90).contains(lat), (-180 ... 180).contains(lon) else { return nil }
        return (lat, lon)
    }

    /// `toFixed`, without the "-0.00000" it can answer.
    static func fixed(_ value: Double, _ digits: Int) -> String {
        let text = String(format: "%.\(digits)f", value)
        if text.hasPrefix("-"), text.dropFirst().allSatisfy({ $0 == "0" || $0 == "." }) { return String(text.dropFirst()) }
        return text
    }

    /// A point as `point=` spells it: five decimals, a metre.
    static func pair(latitude: Double, longitude: Double) -> String {
        fixed(latitude, 5) + "," + fixed(longitude, 5)
    }

    /// A view as `latLonZ=` spells it.
    static func view(latitude: Double, longitude: Double, zoom: Double) -> String {
        fixed(latitude, 5) + "," + fixed(longitude, 5) + "," + fixed(zoom, 2)
    }

    /// A query value with its commas and slashes left readable, as core writes them.
    static func encode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#?")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// A link's search with `changes` applied (nil removes a parameter), in
    /// core's order (`linkSearch`).
    static func search(_ search: String, changing changes: [String: String?]) -> String {
        let query = search.hasPrefix("?") ? String(search.dropFirst()) : search
        var foreign: [(String, String)] = []
        var owned: [String: String] = [:]
        for item in URLComponents(string: "?" + query)?.queryItems ?? [] {
            let value = item.value ?? ""
            if order.contains(item.name) {
                if owned[item.name] == nil { owned[item.name] = value }
            } else {
                foreign.append((item.name, value))
            }
        }
        for (key, value) in changes {
            if order.contains(key) { owned[key] = value } else if let value { foreign.append((key, value)) }
        }
        let parts = foreign.map { "\(encode($0.0))=\(encode($0.1))" }
            + order.compactMap { key in owned[key].map { "\(key)=\(encode($0))" } }
        return parts.isEmpty ? "" : "?" + parts.joined(separator: "&")
    }
}

/// Where the radar networks are at all (core's `radarExtents4326` in
/// `NowcastPlayback.svelte`, boxes from `layers/extents.ts`): min lon, min
/// lat, max lon, max lat.
///
/// No app dependencies here: `scripts/check.sh` compiles this file alone.
enum RadarExtents {
    static let boxes: [[Double]] = [
        [2.8125, 45, 19.6875, 56.25], // DWD
        [2.8, 43.7, 13.1, 49.6], // ch
        [-8.1, 39.6, 12.7, 52.5], // fr
        [10.1, 47.1, 20.5, 52.1], // cz
        [12.0, 47.8, 25.6, 56.8], // pl
        [-0.6, 47.6, 9.1, 53.5], // be
        [13.8, 46.0, 24.3, 51.5], // sk
        [18.2, 52.3, 29.1, 57.9], // lt
        [20.1, 56.2, 29.9, 61.7], // ee
        [-12.7, 50.4, -2.4, 55.7], // ie
        [10.9, 40.6, 21.9, 48.2], // hr
        [4.8, 52.9, 18.7, 59.7], // dk
        [1.0, 49.5, 8.8, 55.3], // nl
        [17.0, 57.8, 34.7, 70.8], // fi
        [8.8, 54.0, 27.2, 70.0], // se
        [0.4, 56.2, 35.5, 72.8], // no
    ]

    /// Whether a position is inside any network's box (core's `covers`).
    static func covers(latitude: Double, longitude: Double) -> Bool {
        boxes.contains { longitude >= $0[0] && longitude <= $0[2] && latitude >= $0[1] && latitude <= $0[3] }
    }

    /// Whether a view's box touches any network's (core's `overlaps`); false
    /// means "no radar here".
    static func overlapsAny(minLon: Double, minLat: Double, maxLon: Double, maxLat: Double) -> Bool {
        boxes.contains { $0[0] <= maxLon && $0[2] >= minLon && $0[1] <= maxLat && $0[3] >= minLat }
    }
}

/// Whether a radar series sampled at one point has no rain there (core's
/// `lib/dryness.ts`): at least one reading, and every one at or below 0 dBZ.
/// No reading at all is unknown, not dry.
enum Dryness {
    static func isDry(_ readings: [Double?]) -> Bool {
        let finite = readings.compactMap { $0 }.filter(\.isFinite)
        return !finite.isEmpty && finite.allSatisfy { $0 <= 0 }
    }
}
