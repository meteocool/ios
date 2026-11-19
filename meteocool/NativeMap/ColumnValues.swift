//
//  ColumnValues.swift
//  meteocool
//
//  Echo tops and VIL as value tiles: core's `lib/columnValues.ts`.
//

import Foundation

/// One colour of a scale or a table: red, green, blue and alpha, 0 to 255,
/// not premultiplied.
struct ValueColour: Equatable, Sendable {
    var r: Int, g: Int, b: Int, a: Int

    init(_ r: Int, _ g: Int, _ b: Int, _ a: Int) {
        (self.r, self.g, self.b, self.a) = (r, g, b, a)
    }

    /// `#rrggbb` with an alpha.
    init(hex: String, alpha: Int = 255) {
        let value = Int(hex.dropFirst(), radix: 16) ?? 0
        self.init(value >> 16 & 0xFF, value >> 8 & 0xFF, value & 0xFF, alpha)
    }

    static let clear = ValueColour(0, 0, 0, 0)

    var components: [Int] { [r, g, b, a] }
}

/// Echo tops and VIL: a byte a pixel in a unit of its own, coloured here.
///
/// The backend reads, up the same tilts as its column maximum of every
/// network and in the same pass, how high the echo reaches 18, 45 and 50 dBZ
/// and how much liquid water the column holds. Each is a frame of its own
/// whose `values.encoding` names its bytes: `height-250m-u8`, a top in 250 m
/// steps above sea level, and `vil-0.5kg-u8`, VIL in half kilograms a square
/// metre, 1 to 254 either way. 0 draws nothing (no echo reached the
/// threshold, under 0.25 kg, or no radar), and so does 255, should a tile
/// ever carry the backend's own "no radar".
///
/// Each is drawn in a palette of its own, whatever the reader's reflectivity
/// palette is: a height or a weight in dBZ's colours would read as an echo's
/// strength. Viridis for the tops, plasma for VIL; the table the tiles are
/// coloured with and the legend are built from the same stops.
///
/// No app dependencies here: `scripts/check.sh` compiles this file alone.
enum ColumnEncoding: String, CaseIterable, Sendable {
    /// An echo top's frame: pixel × 250 m above sea level.
    case echoTop = "height-250m-u8"
    /// A VIL frame: pixel × 0.5 kg m⁻².
    case vil = "vil-0.5kg-u8"

    /// Whether a frame's encoding is an echo top's or VIL's (`isColumnEncoding`).
    init?(encoding: String?) {
        guard let encoding, let known = ColumnEncoding(rawValue: encoding) else { return nil }
        self = known
    }

    var scale: ColumnScale { self == .echoTop ? .echoTop : .vil }

    /// The backend's "no radar"; a tile carries 0 there instead, and either draws nothing.
    private static let notCovered = 255

    /// A byte as what it measures, in its scale's unit (km for a top, kg m⁻²
    /// for VIL); nil where nothing is drawn: 0, 255 and anything that is no byte.
    func value(_ byte: Int) -> Double? {
        guard byte > 0, byte < Self.notCovered else { return nil }
        return Double(byte) * scale.step
    }

    /// Byte to colour; 0 and 255 are transparent (`columnTable`).
    var table: [ValueColour] {
        (0 ..< 256).map { byte in value(byte).map(scale.colour) ?? .clear }
    }
}

/// How an encoding's bytes read, and how they are drawn.
struct ColumnScale: Sendable {
    /// What one step of the byte is, in `unit`.
    let step: Double
    /// What the legend's last number is followed by.
    let unit: String
    /// The colours, each at its value, spaced evenly along the legend: a value
    /// between two is coloured between them, one past either end as that end.
    let stops: [(value: Double, colour: ValueColour)]
    /// The values the legend names, each one of `stops`'.
    let ticks: [Double]

    /// An echo top, 0 to 16 km, in viridis from its second tenth: one tenth
    /// every 2 km. The lowest 2 km fade in, as every reflectivity palette's
    /// lowest values do; higher than 16 km is the top colour.
    static let echoTop = ColumnScale(step: 0.25, unit: "km", stops: [
        (0, ValueColour(hex: "#414487", alpha: 128)), (2, ValueColour(hex: "#355f8d")), (4, ValueColour(hex: "#2a788e")),
        (6, ValueColour(hex: "#21918c")), (8, ValueColour(hex: "#22a884")), (10, ValueColour(hex: "#44bf70")),
        (12, ValueColour(hex: "#7ad151")), (14, ValueColour(hex: "#bddf26")), (16, ValueColour(hex: "#fde725")),
    ], ticks: [0, 4, 8, 12, 16])

    /// VIL, 0.5 to 70 kg m⁻², in plasma: its eleven tenths, one at each
    /// stop, closest at the low end, where most rain is. The lowest values
    /// fade in, as for the tops.
    static let vil = ColumnScale(step: 0.5, unit: "kg/m²", stops: [
        (0.5, ValueColour(hex: "#0d0887", alpha: 128)), (1, ValueColour(hex: "#41049d", alpha: 200)), (2, ValueColour(hex: "#6a00a8")),
        (4, ValueColour(hex: "#8f0da4")), (7, ValueColour(hex: "#b12a90")), (10, ValueColour(hex: "#cc4778")), (15, ValueColour(hex: "#e16462")),
        (20, ValueColour(hex: "#f2844b")), (30, ValueColour(hex: "#fca636")), (45, ValueColour(hex: "#fcce25")), (70, ValueColour(hex: "#f0f921")),
    ], ticks: [1, 4, 10, 20, 45, 70])

    /// Where a value falls between two stops: the first stop's index, and how
    /// far on to the next, 0 to 1.
    private func segment(_ value: Double) -> (Int, Double) {
        if value <= stops[0].value { return (0, 0) }
        for i in 1 ..< stops.count where value <= stops[i].value {
            return (i - 1, (value - stops[i - 1].value) / (stops[i].value - stops[i - 1].value))
        }
        return (stops.count - 2, 1)
    }

    /// A value's colour, between its two stops' and clamped at either end (`colourAt`).
    func colour(_ value: Double) -> ValueColour {
        let (i, f) = segment(value)
        let (from, to) = (stops[i].colour.components, stops[i + 1].colour.components)
        let c = (0 ..< 4).map { Int((Double(from[$0]) + f * Double(to[$0] - from[$0])).rounded()) }
        return ValueColour(c[0], c[1], c[2], c[3])
    }

    /// Where a value falls along the legend, 0 at its left end and 1 at its
    /// right: the stops evenly spaced (`legendPosition`).
    func position(_ value: Double) -> Double {
        let (i, f) = segment(value)
        return (Double(i) + f) / Double(stops.count - 1)
    }

    /// The legend's strip and the values it names (`columnLegend`): colours
    /// sampled evenly along it, and each tick where it falls.
    func legend(samples: Int = 64) -> (colours: [(at: Double, colour: ValueColour)], ticks: [(value: Double, at: Double)], min: Double, max: Double) {
        let colours = (0 ... samples).map { i -> (at: Double, colour: ValueColour) in
            // Along the strip, back to a value: the stops are evenly spaced on it.
            let along = Double(i) / Double(samples) * Double(stops.count - 1)
            let at = min(Int(along.rounded(.down)), stops.count - 2)
            let value = stops[at].value + (along - Double(at)) * (stops[at + 1].value - stops[at].value)
            return (Double(i) / Double(samples), colour(value))
        }
        return (colours, ticks.map { ($0, position($0)) }, step, stops[stops.count - 1].value)
    }
}
