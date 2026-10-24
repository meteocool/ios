//
//  ThreeDStyle.swift
//  meteocool
//
//  The 3D map's look: core's basemap themes muted, its place-name tiers,
//  hillshade, strikes, box colours.
//

import Foundation

/// An RGBA colour, 0-1, straight (not premultiplied).
struct RGBA: Equatable, Sendable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double = 1

    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        (self.r, self.g, self.b, self.a) = (r, g, b, a)
    }

    /// `#rrggbb` or `#rrggbbaa`.
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: String(hex.dropFirst())).scanHexInt64(&value)
        if hex.count == 9 {
            self.init(Double(value >> 24 & 255) / 255, Double(value >> 16 & 255) / 255, Double(value >> 8 & 255) / 255,
                      Double(value & 255) / 255)
        } else {
            self.init(Double(value >> 16 & 255) / 255, Double(value >> 8 & 255) / 255, Double(value & 255) / 255)
        }
    }

    /// `rgba(r, g, b, a)` with 0-255 channels.
    static func css(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> RGBA { RGBA(r / 255, g / 255, b / 255, a) }

    var hex: String {
        let channel = { (v: Double) in String(format: "%02x", Int((min(max(v, 0), 1) * 255).rounded())) }
        return "#" + channel(r) + channel(g) + channel(b)
    }

    var premultiplied: SIMD4<Float> { SIMD4(Float(r * a), Float(g * a), Float(b * a), Float(a)) }
}

/// A basemap theme as core's `layers/base.ts` gives it, for the colours the
/// 3D map draws (light and dark; the busier OSM and CycleOSM themes are
/// flat-map only).
struct BasemapTheme: Equatable, Sendable {
    var earth: RGBA
    var water: RGBA
    var waterway: RGBA
    var landcover: [String: RGBA]
    var building: RGBA
    /// highway, major_road: colour and width.
    var roads: [(kind: String, colour: RGBA, width: Double)]
    var boundaryCountry: RGBA

    static func == (a: BasemapTheme, b: BasemapTheme) -> Bool {
        a.earth == b.earth && a.water == b.water && a.waterway == b.waterway && a.landcover == b.landcover
            && a.building == b.building && a.boundaryCountry == b.boundaryCountry
            && a.roads.map(\.kind) == b.roads.map(\.kind) && a.roads.map(\.colour) == b.roads.map(\.colour)
    }

    static let light = BasemapTheme(
        earth: RGBA(hex: "#f6f4f0"), water: RGBA(hex: "#cfe0ec"), waterway: RGBA(hex: "#bcd4e4"),
        landcover: ["forest": RGBA(hex: "#e8eee2"), "glacier": RGBA(hex: "#f2f6f8")], building: RGBA(hex: "#e9e5df"),
        roads: [("major_road", RGBA(hex: "#eae5db"), 1.1), ("highway", RGBA(hex: "#e3ddd2"), 1.6)],
        boundaryCountry: RGBA(hex: "#9a958c"))

    static let dark = BasemapTheme(
        earth: RGBA(hex: "#1c1f24"), water: RGBA(hex: "#16232e"), waterway: RGBA(hex: "#1d2f3d"),
        landcover: ["forest": RGBA(hex: "#1f262210"), "glacier": RGBA(hex: "#242a2f")], building: RGBA(hex: "#262a2f"),
        roads: [("major_road", RGBA(hex: "#2c3037"), 1.1), ("highway", RGBA(hex: "#33383f"), 1.6)],
        boundaryCountry: RGBA(hex: "#5c626b"))

    /// The same theme drained of some of its life (core's `muteTheme`):
    /// each colour desaturated by 0.35 then mixed 0.2 towards the earth;
    /// 8-digit colours, the earth and the borders as they are.
    func muted(amount: Double = 0.2) -> BasemapTheme {
        let into = earth
        func one(_ c: RGBA) -> RGBA {
            guard c.a >= 1 else { return c }
            let grey = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
            let flat = { (v: Double) in v + (grey - v) * 0.35 }
            let mix = { (v: Double, to: Double) in
                (min(max((flat(v) + (to - flat(v)) * amount) * 255, 0), 255)).rounded() / 255
            }
            return RGBA(mix(c.r, into.r), mix(c.g, into.g), mix(c.b, into.b))
        }
        var out = self
        out.water = one(water)
        out.waterway = one(waterway)
        out.landcover = landcover.mapValues(one)
        out.building = one(building)
        out.roads = roads.map { ($0.kind, one($0.colour), $0.width) }
        return out
    }

    static func of(dark: Bool) -> BasemapTheme { (dark ? Self.dark : Self.light).muted() }

    /// A road's width at a zoom: half at 6, 2.2 times at 14 (`widthByZoom`).
    static func width(_ base: Double, zoom: Double) -> Double {
        let t = min(max((zoom - 6) / 8, 0), 1)
        return base * (0.5 + (2.2 - 0.5) * t)
    }
}

/// Place names: core's `layers/labels.ts` and `placeLabels` (`maplibreStyle.ts`).
enum PlaceLabels {
    struct Tier: Equatable, Sendable {
        let size: Double
        let bold: Bool
        let halo: Double
        let rank: Int
        let muted: Bool
    }

    static let country = Tier(size: 18, bold: true, halo: 2.6, rank: 100, muted: false)
    static let region = Tier(size: 16, bold: false, halo: 2.2, rank: 90, muted: false)
    static let city = Tier(size: 13, bold: true, halo: 2.2, rank: 92, muted: false)
    static let locality = Tier(size: 12, bold: false, halo: 2.0, rank: 90, muted: true)
    static let micro = Tier(size: 11, bold: false, halo: 2.0, rank: 88, muted: true)

    static func tier(kind: String?, detail: String?) -> Tier {
        if kind == "country" { return country }
        switch detail {
        case "country": return country
        case "region": return region
        case "city": return city
        case "town": return locality
        case "village", "hamlet", "isolated_dwelling": return micro
        default: return locality
        }
    }

    /// The 3D map's own floor under the smaller places, in MapLibre zooms (`LABEL_FLOOR`).
    static func floor(kind: String?, detail: String?) -> Double {
        if kind == "country" || kind == "region" { return 0 }
        switch detail {
        case "city": return 0
        case "town": return 10
        case "village", "suburb", "quarter": return 12
        default: return 13
        }
    }

    /// Whether a place is named at tile zoom `zoom`: its `min_zoom` in the
    /// flat map's levels, and the floor.
    static func shows(kind: String?, detail: String?, minZoom: Double?, zoom: Double) -> Bool {
        if let minZoom, zoom + 1 < minZoom { return false }
        return zoom >= floor(kind: kind, detail: detail)
    }

    /// The name keys in order: the language, English, the local name (`placeNameKeys`).
    static func nameKeys(language: String) -> [String] { ["name:\(language)", "name:en", "name"] }

    static let lightInk = RGBA(hex: "#1b1e23"), lightMuted = RGBA(hex: "#3a4048"), lightHalo = RGBA.css(246, 244, 240, 0.85)
    static let darkInk = RGBA(hex: "#eef1f5"), darkMuted = RGBA(hex: "#ccd3dc"), darkHalo = RGBA.css(28, 31, 36, 0.85)
}

/// The rest of the 3D map's paint.
enum ThreeDPaint {
    /// The flat radar under the storms (`RADAR_OPACITY`).
    static let radarOpacity: Float = 0.35

    /// Hillshade, MapLibre's standard method, as core paints it (`layers/terrain.ts`).
    struct Hillshade {
        let shadow: RGBA
        let highlight: RGBA
        let accent: RGBA
        let exaggeration: Double
    }

    static func hillshade(dark: Bool) -> Hillshade {
        dark
            ? Hillshade(shadow: RGBA.css(0, 0, 0, 0.45), highlight: RGBA.css(255, 255, 255, 0.06),
                        accent: RGBA.css(0, 0, 0, 0.2), exaggeration: 0.35)
            : Hillshade(shadow: RGBA.css(60, 50, 40, 0.32), highlight: RGBA.css(255, 255, 255, 0.35),
                        accent: RGBA.css(60, 50, 40, 0.15), exaggeration: 0.3)
    }

    /// Where the light comes from, before the map's bearing is added.
    static let illuminationDegrees = 335.0

    /// A box's halo under its outline (`boxCasing`).
    static func boxCasing(dark: Bool) -> (colour: RGBA, width: Double) {
        dark ? (RGBA.css(255, 255, 255, 0.3), 4) : (RGBA.css(17, 20, 26, 0.16), 4)
    }

    static let boxWidth = 1.5
    /// How strongly a box is drawn: fainter under one that does not open (`RING_OPACITY`).
    static let boxOpacity = (openable: 0.9, unopenable: 0.45)

    /// A box's colour: the palette at its peak, between stops every 2.5 dBZ
    /// from 10 to 70 (`dbzRamp`). Never greyed: no storm in 3D is.
    static func boxColour(dbz: Double, palette: String) -> RGBA {
        let clamped = min(max(dbz, 10), 70)
        let lower = (clamped - 10) / 2.5
        let i = Int(lower.rounded(.down))
        let t = lower - Double(i)
        let a = Colormaps.colour(dbz: 10 + Double(i) * 2.5, palette: palette)
        let b = Colormaps.colour(dbz: 10 + Double(min(i + 1, 24)) * 2.5, palette: palette)
        let mix = { (x: UInt8, y: UInt8) in (Double(x) + (Double(y) - Double(x)) * t) / 255 }
        return RGBA(mix(a.x, b.x), mix(a.y, b.y), mix(a.z, b.z))
    }

    /// The legend's and the peel track's ramp, `count` colours from `low` to `high` dBZ.
    static func ramp(palette: String, low: Double, high: Double, count: Int) -> [RGBA] {
        (0 ..< count).map { i in
            let dbz = low + (high - low) * Double(i) / Double(max(count - 1, 1))
            let c = Colormaps.colour(dbz: dbz, palette: palette)
            return RGBA(Double(c.x) / 255, Double(c.y) / 255, Double(c.z) / 255)
        }
    }

    /// A strike's two circles (`STRIKE_COLOURS`), and how long one stays.
    static let strikeGlow = RGBA(hex: "#ffd166")
    static let strikeCore = RGBA(hex: "#fff8e1")
    static let strikeRim = RGBA(hex: "#f7b500")
    static let strikeMinutes = 10.0

    /// Radii by zoom: interpolate(5 → a, 12 → b).
    static func byZoom(_ zoom: Double, _ a: Double, _ b: Double) -> Double {
        a + (b - a) * min(max((zoom - 5) / 7, 0), 1)
    }

    /// The position dot (`ensureLocation`).
    static let dotFill = RGBA(hex: "#048ef9")
    static let dotRadius = 8.25
    static let dotStroke = 3.5
    static let accuracyFill = RGBA.css(255, 255, 255, 0.4)
    static let accuracyOutline = RGBA(hex: "#3399cc")

    /// KONRAD3D severity colours.
    static let severity = ["#2f9e44", "#f0b429", "#e03131", "#9c36b5"].map { RGBA(hex: $0) }
}
