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
    /// Every network's ground at once: the column maximum drawn around DMAX
    /// (core's `AROUND_DMAX`).
    case allNetworks
    /// The extent of every network, uncut: a product of all of them drawn
    /// whole (core's `EUROPE`).
    case whole
}

/// The observed pictures the reader can choose (core's `lib/observedProduct.ts`).
enum RadarProduct: String, CaseIterable, Sendable {
    /// The lowest scan of each national network.
    case hx
    /// All networks merged into one lowest-scan composite.
    case merged
    /// DWD's column maximum, with every network's around it.
    case dmax
    /// The column maximum of every network.
    case colmax

    /// The picker's groups, in order.
    static let groups: [(group: String, products: [RadarProduct])] = [("lowest", [.hx, .merged]), ("column", [.dmax, .colmax])]

    /// How far its newest scan may trail HX's before HX is drawn instead
    /// (`BEHIND_ALLOWED_S`).
    var allowedBehind: Int {
        switch self {
        case .hx: return .max
        case .merged, .dmax: return 600
        case .colmax: return 900
        }
    }

    /// What the timeseries is asked for with (`timeseriesProducts`).
    var timeseriesProducts: [String] {
        switch self {
        case .hx: return []
        case .dmax: return ["dmax", "colmax"]
        case .merged, .colmax: return [rawValue]
        }
    }

    init(setting: String?) {
        self = setting.flatMap(RadarProduct.init(rawValue:)) ?? .hx
    }
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
/// way core's `RadarCapability` composes them: exactly one network per
/// pixel, or the chosen product of all of them.
struct RadarTimeline: Sendable {
    static let stepSeconds = 300
    /// A network's newest frame stays on the live step this long (core's
    /// `layers/latestFrame.ts`).
    static let networkFreshness = 30 * 60

    /// The client grid: 49 five-minute steps, two hours either side of the
    /// clock's step (core's `regenerateGridConfig`).
    let steps: [Int]
    /// The clock's step, which the strip's labels count from.
    let gridNow: Int
    /// The newest observed step: the needle's rest and the live frame
    /// (core's `newestObservation`).
    let now: Int?
    /// The last step playback and scrubbing reach (`lastStepWithRuns`).
    let lastPlayable: Int?
    let layers: [Int: [RadarLayer]]
    /// The reading at the asked point per step, for the player's bars:
    /// 0 for dry, absent where nothing measured or forecast it.
    let dbz: [Int: Double]
    let serverTime: Int
    /// The backend replays a recorded day (demo).
    let replay: Bool
    /// The product chosen, and the one drawn (HX while the choice is behind).
    let product: RadarProduct
    let drawn: RadarProduct
    /// Unix seconds of the freshest and stalest scan in the drawn picture
    /// (`scanRange`); nil without one.
    let scanRange: (freshest: Int, stalest: Int)?
    /// The nowcast domains with a lead on each forecast step.
    let nowcastDomains: [Int: [String]]

    /// Steps after `now`: forecasts.
    func isForecast(_ step: Int) -> Bool { now.map { step > $0 } ?? false }
    func isPlayable(_ step: Int) -> Bool { lastPlayable.map { step <= $0 } ?? false }
    var fellBack: Bool { drawn != product }

    static let empty = RadarTimeline(steps: [], gridNow: 0, now: nil, lastPlayable: nil, layers: [:], dbz: [:], serverTime: 0)

    /// The networks with a place in the composite, in core's priority order.
    static let networks = ["ch", "fr", "cz", "pl", "be", "sk", "lt", "ee", "ie", "hr", "dk", "nl", "fi", "se", "no"]
    /// The networks meteocool's nowcast runs for (core's `NOWCAST_DOMAINS`:
    /// Ireland's run is served but not drawn).
    static let nowcastNetworks = networks.filter { $0 != "ie" }

    init(steps: [Int], gridNow: Int, now: Int?, lastPlayable: Int?, layers: [Int: [RadarLayer]], dbz: [Int: Double],
         serverTime: Int, replay: Bool = false, product: RadarProduct = .hx, drawn: RadarProduct = .hx,
         scanRange: (freshest: Int, stalest: Int)? = nil, nowcastDomains: [Int: [String]] = [:]) {
        self.steps = steps
        self.gridNow = gridNow
        self.now = now
        self.lastPlayable = lastPlayable
        self.layers = layers
        self.dbz = dbz
        self.serverTime = serverTime
        self.replay = replay
        self.product = product
        self.drawn = drawn
        self.scanRange = scanRange
        self.nowcastDomains = nowcastDomains
    }

    /// Composes the series. `clock` is the device's time, which seeds the
    /// grid as in core. `network` is the one the series was asked for, whose
    /// nowcast gives the forecast steps' readings (core's `chartSeries`).
    init(series: RadarSeries, clock: Int, nowcast: Bool = true, network: String? = nil, product: RadarProduct = .hx) {
        let grid = clock / Self.stepSeconds * Self.stepSeconds
        var frames: [Int: RadarFrame] = [:]
        for (key, frame) in series.frames {
            if let step = Int(key), let frame { frames[step] = frame }
        }
        func byStep(_ raw: [String: RadarFrame]?) -> [Int: RadarFrame] {
            var out: [Int: RadarFrame] = [:]
            for (key, frame) in raw ?? [:] { if let step = Int(key), frame.valueTileId != nil { out[step] = frame } }
            return out
        }
        func scan(_ step: Int, _ frame: RadarFrame) -> Int { frame.upstreamTime ?? step }
        var networkFrames: [String: [Int: RadarFrame]] = [:]
        for code in Self.networks { networkFrames[code] = byStep(series.networks?[code]) }
        var nowcastFrames: [String: [Int: RadarFrame]] = [:]
        if nowcast {
            for code in Self.nowcastNetworks { nowcastFrames[code] = byStep(series.products?["nowcast_\(code)"]) }
        }
        let productFrames: [RadarProduct: [Int: RadarFrame]] = [
            .merged: byStep(series.products?["merged"]), .colmax: byStep(series.products?["colmax"]),
            .dmax: byStep(series.products?["dmax"]),
        ]

        let now = frames.filter { $0.value.isObservation && $0.value.valueTileId != nil }.keys.max()
            ?? frames.filter { $0.value.valueTileId != nil && $0.key <= series.serverTime }.keys.max()
        let lastPublished = frames.filter { $0.value.valueTileId != nil }.keys.max()
        // Held back to where the nowcast runs end when they are at most two
        // steps short of WN (`lastStepWithRuns`).
        var lastPlayable = lastPublished
        if let last = lastPublished {
            for run in nowcastFrames.values {
                guard let end = run.keys.max(), end < last, last - end <= 2 * Self.stepSeconds else { continue }
                lastPlayable = min(lastPlayable ?? end, end)
            }
        }

        // The live step shows each network's newest composite, whatever step
        // it falls on, while it is fresh.
        var newest: [String: (step: Int, frame: RadarFrame)] = [:]
        for code in Self.networks {
            let limit = now ?? series.serverTime
            guard let latest = networkFrames[code]?.filter({ $0.key <= limit }).max(by: { $0.key < $1.key }),
                  series.serverTime - scan(latest.key, latest.value) < Self.networkFreshness else { continue }
            newest[code] = (latest.key, latest.value)
        }

        // Each product's newest scan, and what is drawn (`drawnProduct`).
        let hxScan = now.flatMap { step in frames[step].map { scan(step, $0) } }
        func newestFrame(_ product: RadarProduct) -> (step: Int, frame: RadarFrame)? {
            productFrames[product]?.max(by: { $0.key < $1.key }).map { ($0.key, $0.value) }
        }
        func fallsBehind(_ product: RadarProduct) -> Bool {
            guard product != .hx else { return false }
            guard let latest = newestFrame(product) else { return true }
            guard let hxScan else { return false }
            return hxScan - scan(latest.step, latest.frame) > product.allowedBehind
        }
        let drawn = fallsBehind(product) ? RadarProduct.hx : product

        // The frame a product draws on an observed step (`stepFrame`).
        func productFrame(_ product: RadarProduct, at step: Int) -> RadarFrame? {
            if step == now, let latest = newestFrame(product) { return latest.frame }
            return productFrames[product]?[step]
        }
        // The column maximum around DMAX (`aroundFrame`).
        func aroundFrame(at step: Int) -> RadarFrame? {
            guard drawn == .dmax else { return nil }
            if step == now, fallsBehind(.colmax) { return nil }
            return productFrame(.colmax, at: step)
        }

        var steps: [Int] = []
        var layers: [Int: [RadarLayer]] = [:]
        var dbz: [Int: Double] = [:]
        var domains: [Int: [String]] = [:]
        var carried: [RadarLayer] = []
        let readingsRun = network.flatMap { nowcastFrames[$0] }.flatMap { $0.isEmpty ? nil : $0 }
        var step = grid - 7200
        while step <= grid + 7200 {
            steps.append(step)
            let frame = frames[step]
            let forecast = frame.map { !$0.isObservation } ?? (now.map { step > $0 } ?? false)
            // Readings: a forecast step takes the point's network's run where
            // it has one (`chartFrames`); dry arrives as -32.5 and is 0.
            let reading = forecast && readingsRun != nil ? readingsRun?[step]?.dbz : frame?.dbz
            if let reading, reading.isFinite { dbz[step] = max(0, reading) }

            if let frame, let tileId = frame.valueTileId {
                var drawnLayers: [RadarLayer] = []
                var holes: [String] = []
                var dwdFrame = frame
                var dwdTile = tileId
                if frame.isObservation {
                    if drawn == .merged || drawn == .colmax, let whole = productFrame(drawn, at: step),
                       let layer = Self.layer(drawn.rawValue, whole, maxZoom: 8, clip: .whole) {
                        // One frame of every network stands in for all of them.
                        layers[step] = [layer]
                        carried = [layer]
                        step += Self.stepSeconds
                        continue
                    }
                    if drawn == .dmax, let dmax = productFrame(.dmax, at: step), let dmaxTile = dmax.valueTileId {
                        dwdFrame = dmax
                        dwdTile = dmaxTile
                    }
                    if let around = aroundFrame(at: step), let layer = Self.layer("around", around, maxZoom: 8, clip: .allNetworks) {
                        // Around DMAX the column maximum stands where every network would.
                        holes = Self.networks
                        drawnLayers.append(layer)
                    } else {
                        for code in Self.networks {
                            let network = step == now ? newest[code]?.frame : networkFrames[code]?[step]
                            // On the live step DWD gives way to every network,
                            // which brings its own newest frame (core's `holes`).
                            if step == now || network != nil { holes.append(code) }
                            guard let network, let layer = Self.layer(code, network, maxZoom: 8, clip: .exclusive(code)) else { continue }
                            drawnLayers.append(layer)
                        }
                    }
                } else {
                    for code in Self.nowcastNetworks {
                        guard let run = nowcastFrames[code]?[step],
                              let layer = Self.layer(code, run, maxZoom: 8, clip: .exclusive(code)) else { continue }
                        holes.append(code)
                        drawnLayers.append(layer)
                    }
                    if !holes.isEmpty { domains[step] = holes }
                }
                let index = TileIndex(dwdFrame.tiles)
                // HX is 250 m and tiled to 9, WN 1 km and tiled to 8.
                let depth = index.deepestZoom ?? (dwdFrame.isObservation ? 9 : 8)
                drawnLayers.append(RadarLayer(key: "de", bucket: dwdFrame.bucket, tileId: dwdTile, index: index,
                                              maxZoom: depth, clip: .dwd(holes: holes)))
                carried = drawnLayers
            }
            // A missing scan plays through on the frame before it.
            layers[step] = carried
            step += Self.stepSeconds
        }

        // The scans the drawn picture is made of (`scanRange`).
        var range: (Int, Int)?
        let networkScans = newest.map { scan($0.value.step, $0.value.frame) }
        switch drawn {
        case .hx:
            if let hxScan { let parts = [hxScan] + networkScans; range = (parts.max()!, parts.min()!) }
        case .merged, .colmax:
            if let latest = newestFrame(drawn) { let own = scan(latest.step, latest.frame); range = (own, own) }
        case .dmax:
            if let latest = newestFrame(.dmax) {
                let own = scan(latest.step, latest.frame)
                let around = now.flatMap { aroundFrame(at: $0) }.flatMap { _ in newestFrame(.colmax) }.map { scan($0.step, $0.frame) }
                let parts = around.map { [own, $0] } ?? [own] + networkScans
                range = (parts.max()!, parts.min()!)
            }
        }

        self.init(steps: steps, gridNow: grid, now: now, lastPlayable: lastPlayable, layers: layers, dbz: dbz,
                  serverTime: series.serverTime, replay: series.replay ?? false, product: product, drawn: drawn,
                  scanRange: range, nowcastDomains: domains)
    }

    private static func layer(_ code: String, _ frame: RadarFrame, maxZoom: Int, clip: RadarClip) -> RadarLayer? {
        guard let tileId = frame.valueTileId else { return nil }
        let index = TileIndex(frame.tiles)
        return RadarLayer(key: code, bucket: frame.bucket, tileId: tileId, index: index,
                          maxZoom: min(index.deepestZoom ?? maxZoom, 9), clip: clip)
    }

    /// The step closest to `time`, among those that can be shown.
    func step(nearest time: Int) -> Int? {
        steps.filter(isPlayable).min { abs($0 - time) < abs($1 - time) }
    }

    /// The player's label for a step, as core writes it (`formatOffset`):
    /// "Now", "-2h", "+45m", "+1h30m", counted from the clock's step.
    func offsetLabel(_ step: Int, now nowLabel: String) -> String {
        let minutes = Int((Double(step - gridNow) / 60).rounded())
        if minutes == 0 { return nowLabel }
        let sign = minutes < 0 ? "-" : "+"
        let h = abs(minutes) / 60, m = abs(minutes) % 60
        if h == 0 { return "\(sign)\(m)m" }
        return m == 0 ? "\(sign)\(h)h" : "\(sign)\(h)h\(m)m"
    }

    /// The bars' top (`barCeiling`): 45 dBZ, or the peak if higher.
    var barCeiling: Double { max(45, (dbz.values.max() ?? 0).rounded(.up)) }

    /// Where along the strip the forecast stops having readings, as a share
    /// of its width (`forecastGapFrom`); nil where it does not.
    var forecastGap: Double? {
        guard let first = steps.firstIndex(where: isForecast), first > 0 else { return nil }
        let published = steps.filter(isPlayable).count
        guard let lastReading = steps.indices.last(where: { isPlayable(steps[$0]) && dbz[steps[$0]] != nil }) else { return nil }
        let gap = max(lastReading + 1, first)
        return gap < published ? Double(gap) / Double(steps.count) : nil
    }
}
