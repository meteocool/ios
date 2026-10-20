//
//  RadarFrames.swift
//  meteocool
//
//  The radar timeline the native map plays: core's `/v3/radar/timeseries`
//  and the layers each of its steps draws.
//

import Foundation

/// One radar frame, as `/v3/radar/timeseries` publishes it (core's
/// `spec/api.openapi.json`, `RadarFrame`).
struct RadarFrame: Decodable, Sendable, Equatable {
    let processedTime: Int
    let upstreamTime: Int?
    let tileId: String
    /// `observation`, or `nowcast_phys` for a forecast lead.
    let source: String
    /// The reading at the point the series was asked for.
    let dbz: Double?
    let tiles: [String: TileRows]?
    let values: Values?

    struct Values: Decodable, Sendable, Equatable {
        let tileId: String
        let encoding: String
    }

    /// The tiles holding raw values (RVP6, one byte per pixel), the only
    /// kind the native map draws; nil for a frame that has none.
    var valueTileId: String? {
        guard let values, values.encoding == "rvp6-u8" else { return nil }
        return values.tileId
    }

    /// Where its tiles are: observations in `meteoradar`, forecasts in
    /// `meteonowcast` (core's `RadarCapability`).
    var bucket: String { source == "observation" ? "meteoradar" : "meteonowcast" }

    var isObservation: Bool { source == "observation" }
}

/// Which tiles of one zoom level a frame has (core's `lib/tileIndex.ts`):
/// the rectangle they fall in, XYZ x and TMS y, and one bit per tile of it,
/// row major from the corner, most significant bit first, base64.
struct TileRows: Decodable, Sendable, Equatable {
    let x: Int
    let y: Int
    let w: Int
    let h: Int
    let bits: Data

    enum CodingKeys: String, CodingKey { case x, y, w, h, bits }

    init(x: Int, y: Int, w: Int, h: Int, bits: Data) {
        (self.x, self.y, self.w, self.h, self.bits) = (x, y, w, h, bits)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decode(Int.self, forKey: .x)
        y = try c.decode(Int.self, forKey: .y)
        w = try c.decode(Int.self, forKey: .w)
        h = try c.decode(Int.self, forKey: .h)
        bits = Data(base64Encoded: try c.decode(String.self, forKey: .bits)) ?? Data()
    }

    func has(x tileX: Int, tmsY: Int) -> Bool {
        let column = tileX - x, row = tmsY - y
        guard column >= 0, row >= 0, column < w, row < h else { return false }
        let at = row * w + column
        guard at >> 3 < bits.count else { return false }
        return bits[bits.startIndex + at >> 3] & (0x80 >> UInt8(at & 7)) != 0
    }
}

/// A frame's tile index by zoom level.
struct TileIndex: Sendable, Equatable {
    let levels: [Int: TileRows]

    init(_ raw: [String: TileRows]?) {
        var levels: [Int: TileRows] = [:]
        for (key, rows) in raw ?? [:] { if let z = Int(key) { levels[z] = rows } }
        self.levels = levels
    }

    /// Whether the frame has tile `z`/`x`/`y` (XYZ). True for a zoom the
    /// index says nothing about: then only asking tells.
    func has(z: Int, x: Int, y: Int) -> Bool {
        guard let rows = levels[z] else { return true }
        return rows.has(x: x, tmsY: (1 << z) - 1 - y)
    }

    /// The deepest zoom it has tiles at, nil without an index.
    var deepestZoom: Int? { levels.keys.max() }
}

/// `/v3/radar/timeseries` (core's `RadarFrames`).
struct RadarSeries: Decodable, Sendable {
    /// DWD's composite (HX) on observed steps, WN on forecast ones, by unix second.
    let frames: [String: RadarFrame?]
    /// Each country network's composites on observed steps.
    let networks: [String: [String: RadarFrame]]?
    /// `nowcast_<code>` runs for the networks, with `products=nowcast`.
    let products: [String: [String: RadarFrame]]?
    let serverTime: Int
    let replay: Bool?

    static func decode(_ data: Data) throws -> RadarSeries {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(RadarSeries.self, from: data)
    }
}

/// How a layer is cut to where its network is the one drawn (core's
/// `spec/coverage.json`).
enum RadarClip: Sendable, Hashable {
    /// DWD's tile extent, less the `dwd_hole` of each network listed.
    case dwd(holes: [String])
    /// A network's `exclusive` ground.
    case exclusive(String)
}

/// One tiled layer a step draws.
struct RadarLayer: Sendable, Hashable {
    /// `de`, or a network code: tells a layer's frames apart from other
    /// layers', so a tile still loading can be stood in for by the same
    /// layer's tile from the step before.
    let key: String
    let bucket: String
    let tileId: String
    let index: TileIndex
    let maxZoom: Int
    let clip: RadarClip

    static func == (a: RadarLayer, b: RadarLayer) -> Bool {
        a.key == b.key && a.bucket == b.bucket && a.tileId == b.tileId && a.clip == b.clip
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(tileId)
    }

    /// Radar tiles start at zoom 3 (core's `layers/dwd.ts`).
    static let minZoom = 3
}

/// The five-minute steps of the player and what each of them draws, the
/// way core's `RadarCapability` composes them for the default product
/// (HX): exactly one network per pixel.
struct RadarTimeline: Sendable {
    static let stepSeconds = 300
    /// A network's newest frame stays on the live step this long (core's
    /// `layers/latestFrame.ts`).
    static let networkFreshness = 30 * 60

    /// Every step from two hours back to the last one with a frame.
    let steps: [Int]
    /// The newest observed step, "Now" on the player.
    let now: Int?
    let layers: [Int: [RadarLayer]]
    /// The reading at the asked point per step, for the player's bars.
    let dbz: [Int: Double]
    let serverTime: Int
    /// Steps after `now`: forecasts.
    func isForecast(_ step: Int) -> Bool { now.map { step > $0 } ?? false }

    static let empty = RadarTimeline(steps: [], now: nil, layers: [:], dbz: [:], serverTime: 0)

    /// The networks with a place in the composite, in core's priority order.
    static let networks = ["ch", "fr", "cz", "pl", "be", "sk", "lt", "ee", "ie", "hr", "dk", "nl", "fi", "se", "no"]

    init(steps: [Int], now: Int?, layers: [Int: [RadarLayer]], dbz: [Int: Double], serverTime: Int) {
        self.steps = steps
        self.now = now
        self.layers = layers
        self.dbz = dbz
        self.serverTime = serverTime
    }

    /// Composes the series. `clock` is the device's time, which seeds the
    /// grid as in core (`regenerateGridConfig`): two hours either side of the
    /// current five-minute step. `network` is the one the series was asked
    /// for, whose nowcast gives the forecast steps' readings (core's
    /// `chartSeries`).
    init(series: RadarSeries, clock: Int, nowcast: Bool = true, network: String? = nil) {
        let grid = clock / Self.stepSeconds * Self.stepSeconds
        var frames: [Int: RadarFrame] = [:]
        for (key, frame) in series.frames {
            if let step = Int(key), let frame { frames[step] = frame }
        }
        func byStep(_ raw: [String: RadarFrame]?) -> [Int: RadarFrame] {
            var out: [Int: RadarFrame] = [:]
            for (key, frame) in raw ?? [:] { if let step = Int(key) { out[step] = frame } }
            return out
        }
        var networkFrames: [String: [Int: RadarFrame]] = [:]
        for code in Self.networks { networkFrames[code] = byStep(series.networks?[code]) }
        var nowcastFrames: [String: [Int: RadarFrame]] = [:]
        if nowcast {
            for code in Self.networks { nowcastFrames[code] = byStep(series.products?["nowcast_\(code)"]) }
        }

        let now = frames.filter { $0.value.isObservation && $0.value.valueTileId != nil }.keys.max()
            ?? frames.keys.filter { $0 <= series.serverTime }.max()
        let last = frames.filter { $0.value.valueTileId != nil }.keys.max()

        // The live step shows each network's newest composite, whatever step
        // it falls on, while it is fresh.
        var newest: [String: RadarFrame] = [:]
        for code in Self.networks {
            let limit = now ?? series.serverTime
            guard let latest = networkFrames[code]?.filter({ $0.key <= limit }).max(by: { $0.key < $1.key }),
                  series.serverTime - max(latest.key, latest.value.upstreamTime ?? latest.key) < Self.networkFreshness else { continue }
            newest[code] = latest.value
        }

        var steps: [Int] = []
        var layers: [Int: [RadarLayer]] = [:]
        var dbz: [Int: Double] = [:]
        var carried: [RadarLayer] = []
        var step = grid - 7200
        let end = max(min(last ?? grid, grid + 7200), now ?? grid)
        while step <= end {
            steps.append(step)
            if let reading = frames[step]?.dbz { dbz[step] = reading }
            if let network, let run = nowcastFrames[network]?[step], frames[step]?.isObservation != true,
               let reading = run.dbz {
                dbz[step] = reading
            }
            if let frame = frames[step], let tileId = frame.valueTileId {
                var drawn: [RadarLayer] = []
                var holes: [String] = []
                if frame.isObservation {
                    for code in Self.networks {
                        let network = step == now ? newest[code] : networkFrames[code]?[step]
                        // On the live step DWD gives way to every network,
                        // which brings its own newest frame (core's `holes`).
                        if step == now || network != nil { holes.append(code) }
                        guard let network, let layer = Self.layer(code, network, maxZoom: 8, clip: .exclusive(code)) else { continue }
                        drawn.append(layer)
                    }
                } else {
                    for code in Self.networks {
                        guard let run = nowcastFrames[code]?[step],
                              let layer = Self.layer(code, run, maxZoom: 8, clip: .exclusive(code)) else { continue }
                        holes.append(code)
                        drawn.append(layer)
                    }
                }
                let index = TileIndex(frame.tiles)
                // HX is 250 m and tiled to 9, WN 1 km and tiled to 8.
                let depth = index.deepestZoom ?? (frame.isObservation ? 9 : 8)
                drawn.append(RadarLayer(key: "de", bucket: frame.bucket, tileId: tileId, index: index,
                                        maxZoom: depth, clip: .dwd(holes: holes)))
                carried = drawn
            }
            // A missing scan plays through on the frame before it.
            layers[step] = carried
            step += Self.stepSeconds
        }
        self.init(steps: steps, now: now, layers: layers, dbz: dbz, serverTime: series.serverTime)
    }

    private static func layer(_ code: String, _ frame: RadarFrame, maxZoom: Int, clip: RadarClip) -> RadarLayer? {
        guard let tileId = frame.valueTileId else { return nil }
        let index = TileIndex(frame.tiles)
        return RadarLayer(key: code, bucket: frame.bucket, tileId: tileId, index: index,
                          maxZoom: min(index.deepestZoom ?? maxZoom, 9), clip: clip)
    }

    /// The step closest to `time`, within the timeline.
    func step(nearest time: Int) -> Int? {
        steps.min { abs($0 - time) < abs($1 - time) }
    }

    /// The player's label for a step, as core writes it (`lib/timeline.ts`):
    /// "Now", "-2h", "+45m", "+1h30m".
    func offsetLabel(_ step: Int, now nowLabel: String) -> String {
        guard let now else { return "" }
        let minutes = (step - now) / 60
        if minutes == 0 { return nowLabel }
        let sign = minutes < 0 ? "-" : "+"
        let h = abs(minutes) / 60, m = abs(minutes) % 60
        if h == 0 { return "\(sign)\(m)m" }
        return m == 0 ? "\(sign)\(h)h" : "\(sign)\(h)h\(m)m"
    }
}
