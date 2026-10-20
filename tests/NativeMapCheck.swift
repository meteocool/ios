import Foundation
import CoreGraphics

/// Checks the native map's radar data: the value PNG decoder against every
/// row filter, the palette lookup, the tile index and how the timeline
/// composes DWD, the networks and their nowcasts per step.
@main
struct NativeMapCheck {
    /// A grey 8-bit PNG of `pixels`, each row with the filter `filters[row % 5]`.
    static func png(width: Int, height: Int, pixels: [UInt8], filters: [UInt8]) -> Data {
        var raw = [UInt8]()
        for row in 0 ..< height {
            let filter = filters[row % filters.count]
            raw.append(filter)
            for x in 0 ..< width {
                let value = Int(pixels[row * width + x])
                let a = x > 0 ? Int(pixels[row * width + x - 1]) : 0
                let b = row > 0 ? Int(pixels[(row - 1) * width + x]) : 0
                let c = x > 0 && row > 0 ? Int(pixels[(row - 1) * width + x - 1]) : 0
                let predictor: Int
                switch filter {
                case 1: predictor = a
                case 2: predictor = b
                case 3: predictor = (a + b) / 2
                case 4:
                    let p = a + b - c
                    let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
                    predictor = pa <= pb && pa <= pc ? a : (pb <= pc ? b : c)
                default: predictor = 0
                }
                raw.append(UInt8(truncatingIfNeeded: value - predictor))
            }
        }
        let deflated = try! (Data(raw) as NSData).compressed(using: .zlib) as Data
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let n = UInt32(body.count)
            return [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + Array(type.utf8) + body + [0, 0, 0, 0]
        }
        func be(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        var out: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        out += chunk("IHDR", be(width) + be(height) + [8, 0, 0, 0, 0])
        // Split across two IDAT chunks, as encoders may.
        let zlib = [0x78, 0x9C] + [UInt8](deflated) + [0, 0, 0, 0]
        out += chunk("IDAT", Array(zlib[..<(zlib.count / 2)]))
        out += chunk("IDAT", Array(zlib[(zlib.count / 2)...]))
        out += chunk("IEND", [])
        return Data(out)
    }

    static func main() {
        // Every filter type, on values that wrap around.
        let width = 37, height = 23
        let pixels = (0 ..< width * height).map { UInt8(truncatingIfNeeded: $0 * 7 + ($0 / width) * 13) }
        let decoded = GreyPNG.decode(png(width: width, height: height, pixels: pixels, filters: [0, 1, 2, 3, 4]))
        precondition(decoded?.width == width && decoded?.height == height && decoded?.pixels == pixels)
        precondition(GreyPNG.decode(Data([1, 2, 3])) == nil)

        // The palette: 0 is nothing, below leftPad is nothing, past the end the last colour.
        let classic = RadarLUT(palette: "classic")
        precondition(classic.entries[0] == 0 && classic.entries[56] == 0 && classic.entries[57] != 0)
        precondition(classic.entries[255] == classic.entries[57 + 128])
        // 0xFFFFFFFF at index 107 (49.5 dBZ, white): opaque white.
        precondition(classic.entries[57 + 107] == 0xFFFF_FFFF)
        precondition(RadarLUT(palette: "nonsense").name == "classic")
        let blank = GreyPNG.Image(width: 2, height: 1, pixels: [0, 0])
        precondition(classic.colour(blank) == nil)
        let image = classic.colour(GreyPNG.Image(width: 2, height: 1, pixels: [0, 200]))
        precondition(image?.width == 2)

        // The tile index: "sA==" is 1011 0000, a 2×2 block missing its second tile.
        let rows = TileRows(x: 16, y: 20, w: 2, h: 2, bits: Data(base64Encoded: "sA==")!)
        precondition(rows.has(x: 16, tmsY: 20) && !rows.has(x: 17, tmsY: 20) && rows.has(x: 16, tmsY: 21) && rows.has(x: 17, tmsY: 21))
        precondition(!rows.has(x: 18, tmsY: 20) && !rows.has(x: 15, tmsY: 20))
        let index = TileIndex(["5": rows])
        // XYZ y 11 is TMS 31 - 11 = 20.
        precondition(index.has(z: 5, x: 16, y: 11) && !index.has(z: 5, x: 17, y: 11) && index.has(z: 6, x: 0, y: 0))
        precondition(index.deepestZoom == 5)

        // A series: observations up to now (1000200), a scan missing at -10 min,
        // WN after it; Switzerland observed now, France five minutes late and
        // never on the past step; a Swiss nowcast at +5.
        let now = 1_000_200
        func frame(_ id: String, _ source: String = "observation", dbz: Double? = nil, tiles: String = "") -> String {
            """
            {"processed_time": 1, "upstream_time": null, "tile_id": "\(id)", "source": "\(source)", "filename": "x",
             "dbz": \(dbz.map { "\($0)" } ?? "null"), "tiles": \(tiles.isEmpty ? "null" : tiles),
             "values": {"tile_id": "v-\(id)", "encoding": "rvp6-u8"}}
            """
        }
        let json = """
        {"frames": {"\(now - 900)": \(frame("a", dbz: 10)), "\(now - 600)": null, "\(now - 300)": \(frame("b")),
                    "\(now)": \(frame("c", dbz: 30)), "\(now + 300)": \(frame("d", "nowcast_phys", tiles: #"{"8": {"x":0,"y":0,"w":1,"h":1,"bits":"gA=="}}"#)),
                    "\(now + 600)": \(frame("e", "nowcast_phys"))},
         "networks": {"ch": {"\(now - 900)": \(frame("ch1")), "\(now)": \(frame("ch2"))},
                      "fr": {"\(now - 300)": \(frame("fr1"))}},
         "products": {"nowcast_ch": {"\(now + 300)": \(frame("chn", "nowcast_phys"))}},
         "server_time": \(now + 120), "replay": false}
        """
        let series = try! RadarSeries.decode(Data(json.utf8))
        let timeline = RadarTimeline(series: series, clock: now + 120)
        precondition(timeline.now == now, "\(String(describing: timeline.now))")
        precondition(timeline.steps.first == now - 7200 && timeline.steps.last == now + 600)
        precondition(timeline.isForecast(now + 300) && !timeline.isForecast(now))
        precondition(timeline.dbz[now] == 30 && timeline.dbz[now - 900] == 10)

        func keys(_ step: Int) -> [String] { timeline.layers[step]!.map { "\($0.key):\($0.tileId)" } }
        // The live step: each network's newest fresh frame, DWD holed for all of them.
        precondition(keys(now) == ["ch:v-ch2", "fr:v-fr1", "de:v-c"], "\(keys(now))")
        if case let .dwd(holes) = timeline.layers[now]!.last!.clip {
            precondition(holes == RadarTimeline.networks)
        } else { preconditionFailure() }
        // A past step: only the networks observed on it, and only those holed.
        precondition(keys(now - 900) == ["ch:v-ch1", "de:v-a"])
        if case let .dwd(holes) = timeline.layers[now - 900]!.last!.clip { precondition(holes == ["ch"]) } else { preconditionFailure() }
        // A missing scan plays on the one before it.
        precondition(keys(now - 600) == keys(now - 900))
        // Before any frame: nothing.
        precondition(timeline.layers[now - 7200]!.isEmpty)
        // Forecast: WN from the nowcast bucket, holed only where a network's nowcast draws.
        let forecast = timeline.layers[now + 300]!
        precondition(forecast.map(\.key) == ["ch", "de"] && forecast.allSatisfy { $0.bucket == "meteonowcast" })
        precondition(forecast.last!.maxZoom == 8 && timeline.layers[now]!.last!.maxZoom == 9)
        if case let .dwd(holes) = forecast.last!.clip { precondition(holes == ["ch"]) } else { preconditionFailure() }
        precondition(timeline.layers[now + 600]!.map(\.key) == ["de"])
        // Readings: the series' own, and on a forecast step the asked network's nowcast where it has one.
        let swiss = RadarTimeline(series: series, clock: now + 120, network: "ch")
        precondition(swiss.dbz[now] == 30 && swiss.dbz[now + 300] == nil && timeline.dbz[now + 300] == nil)
        // Without the nowcast setting, WN alone.
        precondition(RadarTimeline(series: series, clock: now, nowcast: false).layers[now + 300]!.map(\.key) == ["de"])

        precondition(timeline.offsetLabel(now, now: "Now") == "Now")
        precondition(timeline.offsetLabel(now - 7200, now: "Now") == "-2h")
        precondition(timeline.offsetLabel(now + 2700, now: "Now") == "+45m")
        precondition(timeline.offsetLabel(now + 5400, now: "Now") == "+1h30m")
        precondition(timeline.step(nearest: now + 100) == now)

        // Links: core's spelling both ways, junk refused.
        let link = NativeMapLink(search: "?layer=radar&latLonZ=48.13710,11.57540,9.50&t=20260924T1945Z&shared=20260924T1950Z")
        precondition(link == NativeMapLink(latitude: 48.1371, longitude: 11.5754, zoom: 9.5, time: 1_790_279_100), "\(String(describing: link))")
        precondition(link?.search == "?latLonZ=48.13710,11.57540,9.50&t=20260924T1945Z")
        precondition(NativeMapLink(search: "latLonZ=48,11,6")?.time == nil)
        precondition(NativeMapLink(search: "?latLonZ=91,11,6") == nil && NativeMapLink(search: "?latLonZ=48,11") == nil)
        precondition(NativeMapLink(search: "?t=20260924T1945Z") == nil)
        precondition(NativeMapLink.frameTime("20260231T1200Z") == nil && NativeMapLink.frameTime("20260924T2560Z") == nil)
        print("NativeMapCheck passed")
    }
}
