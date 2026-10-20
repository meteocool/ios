//
//  LightningRules.swift
//  meteocool
//
//  The lightning map's rules: how strikes age through core's palette, the
//  strikes newer than the tile set, the histogram and its legend, and the
//  services it asks (core's `caps/LightningCapability.ts`,
//  `layers/lightning.ts`, `components/LightningChart.svelte`).
//
//  No app dependencies here: `scripts/check.sh` compiles this file alone.
//

import Foundation

enum LightningRules {
    /// core's `LightningColors` (`colormaps.ts:668-790`): index 0 is a strike
    /// this minute, 120 one two hours old.
    static let colors: [UInt32] = [
        0xFFFFCC, 0xFFFEC9, 0xFFFDC6, 0xFFFCC4, 0xFFFAC1, 0xFFF9BE, 0xFFF8BB, 0xFFF7B9,
        0xFFF5B5, 0xFFF4B2, 0xFFF3AF, 0xFFF2AC, 0xFFF1A9, 0xFFF0A7, 0xFFEFA4, 0xFFEDA0,
        0xFFEC9D, 0xFFEA9B, 0xFFE998, 0xFFE895, 0xFFE793, 0xFFE590, 0xFFE48D, 0xFEE289,
        0xFEE187, 0xFEE084, 0xFEDE82, 0xFEDD7F, 0xFEDC7C, 0xFEDB7A, 0xFED976, 0xFED673,
        0xFED470, 0xFED16E, 0xFECF6B, 0xFECC68, 0xFECA66, 0xFEC863, 0xFEC45F, 0xFEC15D,
        0xFEBF5A, 0xFEBD57, 0xFEBA55, 0xFEB852, 0xFEB54F, 0xFEB24C, 0xFEAF4B, 0xFEAD4A,
        0xFEAB49, 0xFEA848, 0xFEA647, 0xFEA446, 0xFEA145, 0xFD9E43, 0xFD9C42, 0xFD9941,
        0xFD9740, 0xFD953F, 0xFD923E, 0xFD903D, 0xFD8C3C, 0xFD883B, 0xFD8439, 0xFD8038,
        0xFD7C37, 0xFD7836, 0xFD7435, 0xFD7034, 0xFC6A32, 0xFC6631, 0xFC6330, 0xFC5F2F,
        0xFC5B2E, 0xFC572C, 0xFC532B, 0xFC4D2A, 0xFA4A29, 0xF84628, 0xF74327, 0xF54026,
        0xF43D25, 0xF23924, 0xF13624, 0xEE3122, 0xED2E21, 0xEB2B21, 0xE92720, 0xE8241F,
        0xE6211E, 0xE51E1D, 0xE2191C, 0xE0181D, 0xDD161D, 0xDB141E, 0xD9131F, 0xD6111F,
        0xD41020, 0xD10E21, 0xCE0C22, 0xCB0A22, 0xC90823, 0xC70723, 0xC40524, 0xC20325,
        0xC00225, 0xBB0026, 0xB70026, 0xB40026, 0xB00026, 0xAC0026, 0xA80026, 0xA40026,
        0xA10026, 0x9B0026, 0x970026, 0x930026, 0x8F0026, 0x8B0026, 0x880026, 0x840026,
        0x7E0025,
    ]

    /// Strikes older than two hours: grey, under everything.
    static let grey: UInt32 = 0xAAAAAA

    /// The palette index for a strike `minutes` old (`layers/lightning.ts:64-75`):
    /// nil past two hours. The first minute is pale, the second jumps to 21,
    /// after that 30 on.
    static func index(minutes: Double) -> Int? {
        if minutes > 120 { return nil }
        let index = Int(min(120, max(0, minutes)).rounded())
        return min(index - max(-20 * index, -30), 120)
    }

    /// A cross's colour and its stacking (newer over older; grey lowest).
    static func cross(ageMilliseconds: Double) -> (rgb: UInt32, z: Int) {
        let minutes = ageMilliseconds / 60_000
        guard index(minutes: minutes) != nil else { return (grey, 0) }
        let rounded = Int(min(120, max(0, minutes)).rounded())
        return (colors[index(minutes: minutes)!], 120 - rounded)
    }

    // MARK: Histogram

    /// Minutes the histogram covers, one bar each.
    static let bins = 30

    /// Each bar's colour, oldest first: the colour a strike that old has on
    /// the map (`LightningChart.svelte:206-209`).
    static let barColors: [UInt32] = (0 ..< bins).map { i in
        let n = bins - i
        return colors[min(n - max(-20 * n, -30), colors.count - 1)]
    }

    /// The y axis is labelled at its ends only (core's `yTickLabel`).
    static func yTickLabel(_ value: Int, peak: Int) -> String {
        value == 0 || value == peak ? String(value) : ""
    }

    /// The skeleton's bar heights, in percent (core's `ChartSkeleton.svelte`).
    static func skeletonHeights(_ count: Int) -> [Double] {
        (0 ..< count).map { i in
            let x = Double(i)
            return 34 + 26 * abs(sin(x * 0.9)) + 12 * abs(sin(x * 0.31))
        }
    }

    /// The viewport as the closed ring `/v3/lightning/stats` takes, lon/lat
    /// (`fromExtent(…).getLinearRing(0)`), longitudes kept on the globe.
    static func statsRing(minLon: Double, minLat: Double, maxLon: Double, maxLat: Double) -> String {
        let (w, e) = (max(-180, min(180, minLon)), max(-180, min(180, maxLon)))
        let (s, n) = (max(-90, min(90, minLat)), max(-90, min(90, maxLat)))
        func pair(_ lon: Double, _ lat: Double) -> String { "[\(number(lon)),\(number(lat))]" }
        return "{\"coordinates\":[" + [pair(w, s), pair(w, n), pair(e, n), pair(e, s), pair(w, s)].joined(separator: ",") + "]}"
    }

    /// A number as JSON.stringify writes it, to six decimals at most.
    private static func number(_ value: Double) -> String {
        let rounded = (value * 1e6).rounded() / 1e6
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }

    /// `GET /v3/lightning/stats`: 30 counts, oldest first.
    static func bins(_ data: Data) -> [Int]? {
        struct Stats: Decodable { let bins: [Int] }
        guard let bins = (try? JSONDecoder().decode(Stats.self, from: data))?.bins, bins.count == Self.bins else { return nil }
        return bins
    }

    /// The legend's labels, at these palette indices, spread evenly
    /// (`LightningScaleLine.svelte`), written as the apps write them.
    static let legendMinutes = [1, 2, 3, 5, 20, 30, 60, 90, 120]

    // MARK: Layer and backfill

    /// `GET /v3/lightning/layer` (404: nothing published yet).
    struct Layer: Decodable, Equatable, Sendable {
        let processedTime: Int
        let tileId: String
        let mostRecentStrike: Int
        let numStrikes: Int?

        static func decode(_ data: Data) -> Layer? {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try? decoder.decode(Layer.self, from: data)
        }
    }

    /// The server's baseline window, less a margin (core's `BASELINE_MAX_SECONDS`).
    static let baselineMaxSeconds = 3600 - 120

    /// The baseline to ask from: the tile set's newest strike, but not
    /// further back than the server serves.
    static func baseline(mostRecentStrike: Int, now: Date) -> Int {
        max(mostRecentStrike, Int(now.timeIntervalSince1970.rounded(.down)) - baselineMaxSeconds)
    }

    /// One strike: EPSG:3857 metres (sent as `lon`/`lat`), and when, in
    /// milliseconds (`time` from the socket, `time_wall` from the backfill).
    struct Strike: Equatable, Sendable {
        let x: Double
        let y: Double
        let milliseconds: Double
    }

    /// `GET /v3/lightning/baseline`'s strikes.
    static func backfill(_ data: Data) -> [Strike]? {
        struct Wire: Decodable { let lat: Double; let lon: Double; let time_wall: Double }
        struct Collection: Decodable { let strikes: [Wire] }
        guard let collection = try? JSONDecoder().decode(Collection.self, from: data) else { return nil }
        return collection.strikes.map { Strike(x: $0.lon, y: $0.lat, milliseconds: $0.time_wall) }
    }

    /// A socket `lightning` event's strike.
    static func live(_ data: Data) -> Strike? {
        struct Wire: Decodable { let lat: Double; let lon: Double; let time: Double }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data), wire.time.isFinite else { return nil }
        return Strike(x: wire.lon, y: wire.lat, milliseconds: wire.time)
    }

    /// The strikes newer than the tile set, drawn by the client (core's
    /// `StrikeManagerV2`), all in milliseconds as core meant it: keyed by
    /// the rounded time, so a strike sent twice is drawn once; and those
    /// older than the baseline go when a new tile set takes them over.
    struct StrikeBook: Equatable, Sendable {
        private(set) var strikes: [Int64: Strike] = [:]
        private(set) var baseline: Int64 = 0

        init() {}

        /// The tile set covers everything before `seconds`.
        mutating func setBaseline(seconds: Int) {
            baseline = Int64(seconds) * 1000
            strikes = strikes.filter { $0.key >= baseline }
        }

        /// True when anything was added.
        @discardableResult
        mutating func add(_ new: [Strike]) -> Bool {
            var added = false
            for strike in new where strike.milliseconds.isFinite {
                let key = Int64(strike.milliseconds.rounded())
                guard key >= baseline, strikes[key] == nil else { continue }
                strikes[key] = strike
                added = true
            }
            return added
        }

        /// Drops strikes past two hours, which would only draw grey.
        mutating func prune(now: Date) {
            let oldest = Int64((now.timeIntervalSince1970 - 120 * 60) * 1000)
            strikes = strikes.filter { $0.key >= oldest }
        }

        var count: Int { strikes.count }
    }

    // MARK: NOAA

    /// NOAA's CONUS base reflectivity (`layers/noaa.ts`) for XYZ tile
    /// `z`/`x`/`y`, 256 px, as OpenLayers' `TileWMS` asks for it.
    static func noaaURL(z: Int, x: Int, y: Int) -> URL? {
        let half = 20037508.342789244
        let size = 2 * half / Double(1 << z)
        let minX = -half + Double(x) * size, maxY = half - Double(y) * size
        let bbox = [minX, maxY - size, minX + size, maxY].map { String(format: "%.6f", $0) }.joined(separator: ",")
        return URL(string: "https://opengeo.ncep.noaa.gov/geoserver/conus/conus_bref_qcd/ows?SERVICE=WMS&VERSION=1.3.0"
                   + "&REQUEST=GetMap&FORMAT=image%2Fpng&TRANSPARENT=true&LAYERS=conus_bref_qcd&STYLES=&TILED=true"
                   + "&CRS=EPSG%3A3857&SRS=EPSG%3A3857&WIDTH=256&HEIGHT=256&BBOX=" + bbox)
    }

    /// Whether a tile touches the contiguous US (lon −130…−60, lat 20…55),
    /// the only ground the service has: elsewhere nothing is asked.
    static func noaaCovers(z: Int, x: Int, y: Int) -> Bool {
        let n = Double(1 << z)
        let west = Double(x) / n * 360 - 180, east = Double(x + 1) / n * 360 - 180
        func latitude(_ row: Double) -> Double { atan(sinh(.pi * (1 - 2 * row / n))) * 180 / .pi }
        let north = latitude(Double(y)), south = latitude(Double(y + 1))
        return east >= -130 && west <= -60 && north >= 20 && south <= 55
    }
}
