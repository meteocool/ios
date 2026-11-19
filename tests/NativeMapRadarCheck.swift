import CoreGraphics
import Foundation

/// Checks the radar's products and how their tiles are coloured: core's
/// `columnValues.test.ts`, the column products' part of `rvp6.test.ts` and
/// `observedProduct.test.ts`.
@main
struct NativeMapRadarCheck {
    static func close(_ actual: Double, _ expected: Double, _ what: String = "") {
        precondition(abs(actual - expected) < 1e-9, "\(actual) ≠ \(expected) \(what)")
    }

    static func main() {
        columnValues()
        valueTables()
        products()
        motionArrows()
        playbackLoop()
        playbackGate()
        frameSwitch()
        print("NativeMapRadarCheck passed")
    }

    // MARK: - Echo tops and VIL (columnValues.test.ts)

    static func columnValues() {
        // An echo top's byte is 250 m a step above sea level.
        let top = ColumnEncoding.echoTop, vil = ColumnEncoding.vil
        precondition(top.value(1) == 0.25 && top.value(4) == 1 && top.value(16) == 4 && top.value(64) == 16)
        precondition(top.value(72) == 18, "read to 18 km")
        precondition(top.value(254) == 63.5)
        // A VIL byte is half a kilogram a square metre a step.
        precondition(vil.value(1) == 0.5 && vil.value(26) == 13 && vil.value(90) == 45 && vil.value(140) == 70)
        // 0, no echo at the threshold or no radar, and 255, no radar in the files, measure nothing.
        for encoding in ColumnEncoding.allCases {
            precondition(encoding.value(0) == nil && encoding.value(255) == nil && encoding.value(-1) == nil && encoding.value(256) == nil)
        }
        // Only the two column encodings are column encodings.
        precondition(ColumnEncoding(encoding: "height-250m-u8") == .echoTop && ColumnEncoding(encoding: "vil-0.5kg-u8") == .vil)
        precondition(ColumnEncoding(encoding: "rvp6-u8") == nil && ColumnEncoding(encoding: "hg-class-u8") == nil && ColumnEncoding(encoding: nil) == nil)

        // Every byte's colour is its value's on the scale, and 0 and 255 draw nothing.
        for encoding in ColumnEncoding.allCases {
            let table = encoding.table
            precondition(table.count == 256 && table[0] == .clear && table[255] == .clear)
            for byte in 1 ..< 255 {
                precondition(table[byte] == encoding.scale.colour(encoding.value(byte)!), "\(encoding) \(byte)")
                precondition(table[byte].a > 0, "\(encoding) \(byte) is drawn")
            }
        }

        // A value on a stop is its colour, between two is between them, past the ends is the end.
        let tops = ColumnScale.echoTop, water = ColumnScale.vil
        precondition(tops.colour(4) == tops.stops[2].colour && tops.colour(16) == tops.stops[8].colour)
        precondition(tops.colour(18) == tops.stops[8].colour, "above 16 km is the top colour")
        precondition(water.colour(0.25) == water.stops[0].colour)
        let (a, b) = (water.stops[1].colour.components, water.stops[2].colour.components)
        precondition(water.colour(1.5).components == (0 ..< 4).map { Int((Double(a[$0] + b[$0]) / 2).rounded()) })

        // Both palettes only brighten from less to more, so they read without colour vision.
        func luminance(_ c: ValueColour) -> Double {
            func linear(_ v: Int) -> Double {
                let s = Double(v) / 255
                return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
        }
        for scale in [tops, water] {
            for i in 1 ..< scale.stops.count {
                precondition(luminance(scale.stops[i].colour) > luminance(scale.stops[i - 1].colour), "\(scale.unit) stop \(i)")
                precondition(scale.stops[i].value > scale.stops[i - 1].value)
            }
        }

        // The lowest values fade in, as reflectivity's do; the rest are opaque.
        precondition(top.table[1].a < 255 && top.table[8].a == 255, "2 km")
        precondition(vil.table[1].a < vil.table[2].a && vil.table[4].a == 255, "2 kg/m²")

        // The stops are evenly spaced along the legend, so VIL's crowded low end gets its share.
        precondition(tops.position(0) == 0 && tops.position(8) == 0.5 && tops.position(16) == 1 && tops.position(20) == 1)
        precondition(water.position(1) == 0.1 && water.position(10) == 0.5 && water.position(70) == 1)
        close(water.position(3), 0.25)

        // The legend's strip runs from the first stop's colour to the last, ticks where their values fall.
        for encoding in ColumnEncoding.allCases {
            let scale = encoding.scale
            let legend = scale.legend(samples: 10)
            precondition(legend.colours.count == 11)
            precondition(legend.colours[0].colour == scale.stops[0].colour && legend.colours[10].colour == scale.stops.last!.colour)
            precondition(legend.ticks.map(\.value) == scale.ticks)
            for tick in legend.ticks { precondition(tick.at == scale.position(tick.value)) }
            precondition(legend.min == scale.step && legend.max == scale.stops.last!.value)
        }
        precondition(ColumnScale.echoTop.unit == "km" && ColumnScale.vil.unit == "kg/m²")
    }

    // MARK: - Drawn by encoding (rvp6.test.ts)

    static func valueTables() {
        // A frame carries values only when it says so in an encoding the client reads.
        precondition(ValueEncoding.carriesValues("rvp6-u8") && !ValueEncoding.carriesValues(nil))
        precondition(!ValueEncoding.carriesValues("hg-class-u8") && !ValueEncoding.carriesValues("hail-u8"))
        precondition(ValueEncoding.carriesValues("height-250m-u8") && ValueEncoding.carriesValues("vil-0.5kg-u8"))
        func frame(_ values: String) -> RadarFrame {
            try! JSONDecoder().decode(RadarFrame.self, from: Data("""
            {"processedTime": 1, "tileId": "t", "source": "observation", \(values)}
            """.utf8))
        }
        precondition(frame(#""values": {"tileId": "e", "encoding": "height-250m-u8"}"#).valueTileId == "e")
        precondition(frame(#""values": {"tileId": "e", "encoding": "hail-u8"}"#).valueTileId == nil)
        // A frame that does not say is RVP6, as every frame was before the column products.
        precondition(frame(#""values": null"#).encoding == "rvp6-u8")
        precondition(frame(#""values": {"tileId": "v", "encoding": "vil-0.5kg-u8"}"#).encoding == "vil-0.5kg-u8")
        // An RVP6 byte is half a dBZ a step from -32.5.
        precondition(ValueEncoding.dbz(1) == -32 && ValueEncoding.dbz(65) == 0 && ValueEncoding.dbz(165) == 50 && ValueEncoding.dbz(255) == 95)

        // A frame is drawn by its encoding: reflectivity in the reader's palette, a column product in its own.
        precondition(RadarLUT(encoding: "rvp6-u8", palette: "viridis") == RadarLUT(palette: "viridis"))
        precondition(RadarLUT(encoding: "rvp6-u8", palette: "classic", ink: .black) == RadarLUT(palette: "classic", ink: .black))
        func premultiplied(_ table: [ValueColour]) -> [UInt32] {
            table.map { c in
                let a = UInt32(c.a)
                return UInt32(c.r) * a / 255 | (UInt32(c.g) * a / 255) << 8 | (UInt32(c.b) * a / 255) << 16 | a << 24
            }
        }
        for encoding in ColumnEncoding.allCases {
            // Whatever the reader's palette is.
            let viridis = RadarLUT(encoding: encoding.rawValue, palette: "viridis")
            precondition(viridis.entries == RadarLUT(encoding: encoding.rawValue, palette: "classic").entries)
            precondition(viridis.entries == premultiplied(encoding.table))
            for ink in [RadarLUT.Ink.black, .white] {
                precondition(RadarLUT(encoding: encoding.rawValue, palette: "classic", ink: ink).entries
                             == premultiplied(RadarLUT.columnGreyTable(encoding, ink: ink)))
            }
        }
        precondition(RadarLUT(encoding: "height-250m-u8", palette: "classic").entries != RadarLUT(encoding: "vil-0.5kg-u8", palette: "classic").entries)
        precondition(RadarLUT(encoding: "height-250m-u8", palette: "classic").id != RadarLUT(palette: "classic").id)
        // Not read as dBZ: nothing at all.
        precondition(RadarLUT(encoding: "hail-u8", palette: "classic").entries.allSatisfy { $0 == 0 })
        precondition(RadarLUT(encoding: "hail-u8", palette: "classic", ink: .black).entries.allSatisfy { $0 == 0 })

        // A column product in grey keeps each byte's alpha and runs from the ink's faintest to full ink.
        for encoding in ColumnEncoding.allCases {
            let colour = encoding.table
            let black = RadarLUT.columnGreyTable(encoding, ink: .black)
            let white = RadarLUT.columnGreyTable(encoding, ink: .white)
            var last = 255
            for byte in 1 ..< 255 {
                let c = black[byte]
                precondition(c.r == c.g && c.g == c.b, "\(encoding) \(byte) is grey")
                precondition(c.a == colour[byte].a, "\(encoding) \(byte) keeps its alpha")
                precondition(c.r <= last, "\(encoding) \(byte) is no lighter than the one before")
                last = c.r
            }
            precondition(black[0].a == 0 && black[255].a == 0)
            // The scale's top, and past it, is full ink.
            precondition(black[254].r == 0 && white[254].r == 255 && white[1].r < 255)
        }
    }

    // MARK: - Products (observedProduct.test.ts)

    static func products() {
        let columns: [RadarProduct] = [.echotop18, .echotop45, .echotop50, .vil]
        // The picker lists every product once: the lowest scans, the column maxima, then the echo tops upward and VIL.
        precondition(RadarProduct.groups.map(\.group) == ["lowest", "column", "tops"])
        precondition(RadarProduct.groups[2].products == columns)
        let listed = RadarProduct.groups.flatMap(\.products)
        precondition(Set(listed).count == listed.count && listed.count == 8 && listed[0] == .hx)
        // Every product of every network is drawn whole; HX and DMAX keep DWD's grid.
        precondition(RadarProduct.allCases.filter(\.isWhole) == [.merged, .colmax] + columns)
        for product in columns {
            precondition(RadarProduct(setting: product.rawValue) == product)
            // An echo top or VIL asks for its own past alone, not the column maximum's.
            precondition(product.timeseriesProducts == [product.rawValue])
            precondition(product.latestPath == product.rawValue)
            // As far behind as the column maximum they are built with.
            precondition(product.allowedBehind == RadarProduct.colmax.allowedBehind)
        }
        precondition(RadarProduct(setting: "echotop") == .hx)

        // A timeline of them: drawn whole, with the encoding the legend reads, and HX where it has none.
        let now = 1_000_200
        func frame(_ id: String, _ encoding: String = "rvp6-u8", source: String = "observation") -> String {
            """
            {"processed_time": 1, "upstream_time": null, "tile_id": "\(id)", "source": "\(source)", "filename": "x",
             "dbz": null, "tiles": null, "values": {"tile_id": "v-\(id)", "encoding": "\(encoding)"}}
            """
        }
        let json = """
        {"frames": {"\(now - 300)": \(frame("b")), "\(now)": \(frame("c")), "\(now + 300)": \(frame("d", source: "nowcast_phys"))},
         "networks": {}, "products": {"echotop18": {"\(now)": \(frame("e", "height-250m-u8"))},
                                      "vil": {"\(now - 600)": \(frame("w", "vil-0.5kg-u8"))}},
         "server_time": \(now + 120), "replay": false}
        """
        let series = try! RadarSeries.decode(Data(json.utf8))
        let tops = RadarTimeline(series: series, clock: now + 120, product: .echotop18)
        precondition(tops.drawn == .echotop18)
        precondition(tops.layers[now]!.map { "\($0.key):\($0.tileId)" } == ["echotop18:v-e"] && tops.layers[now]![0].clip == .whole)
        precondition(tops.layers[now]![0].encoding == "height-250m-u8")
        precondition(tops.columnEncoding(at: now) == .echoTop && tops.scanRange! == (now, now))
        // A step it has no frame for draws HX, read in dBZ; so does the forecast, WN's whatever is chosen.
        precondition(tops.columnEncoding(at: now - 300) == nil && tops.layers[now - 300]!.last!.tileId == "v-b")
        precondition(tops.columnEncoding(at: now + 300) == nil)
        // Two and three cycles behind HX is still drawn; four is not.
        precondition(RadarTimeline(series: series, clock: now + 120, product: .vil).drawn == .vil)
        for (behind, drawn) in [(900, RadarProduct.vil), (1200, .hx)] {
            let late = json.replacingOccurrences(of: "\"\(now - 600)\": \(frame("w", "vil-0.5kg-u8"))",
                                                 with: "\"\(now - behind)\": \(frame("w", "vil-0.5kg-u8"))")
            precondition(RadarTimeline(series: try! RadarSeries.decode(Data(late.utf8)), clock: now + 120, product: .vil).drawn == drawn)
        }
    }

    // MARK: - The rain's motion (motionArrow.test.ts)

    static func motionArrows() {
        typealias M = MotionArrowRules
        func arrow(_ east: Double, _ north: Double) -> M.Shape {
            guard let shape = M.arrow(east: east, north: north) else { preconditionFailure("an arrow for \(east), \(north)") }
            return shape
        }
        func tip(_ shape: M.Shape) -> CGPoint { shape.head.0 }
        func tail(_ shape: M.Shape) -> CGPoint { shape.shaft.0 }

        // A motion east and north is a speed and the direction the rain goes.
        let east = M.motion(east: 40, north: 0)
        close(east.kmh, 40)
        close(east.towardDeg, 90)
        close(M.motion(east: 0, north: 30).towardDeg, 0)
        close(M.motion(east: 0, north: -30).towardDeg, 180)
        close(M.motion(east: -30, north: 0).towardDeg, 270)
        close(M.motion(east: 30, north: 30).kmh, (1800.0).squareRoot())

        // Speeds are kept to the nearest 5 km/h and directions to the nearest 5 degrees.
        precondition(M.roundKmh(37.4) == 35 && M.roundKmh(37.5) == 40)
        precondition(M.roundDeg(2.4) == 0 && M.roundDeg(357.6) == 0 && M.roundDeg(-3) == 355)

        // Rain too slow to have a direction has no arrow.
        precondition(M.arrow(east: 2, north: 1) == nil && M.arrow(east: 0, north: 0) == nil)
        precondition(M.arrow(east: M.stillKmh, north: 0) != nil)

        // The arrow points the way the rain goes: up the screen for rain going north.
        let north = arrow(0, 40)
        close(tip(north).x, 0)
        precondition(tip(north).y < 0 && tail(north).y > 0)
        let eastward = arrow(40, 0)
        precondition(tip(eastward).x > 0)
        close(tip(eastward).y, 0)

        // The arrow is centred on its block.
        let shape = arrow(30, -20)
        close(tip(shape).x + tail(shape).x, 0)
        close(tip(shape).y + tail(shape).y, 0)

        // A faster motion is a longer arrow, up to the longest.
        func length(_ shape: M.Shape) -> Double { hypot(tip(shape).x - tail(shape).x, tip(shape).y - tail(shape).y) }
        close(length(arrow(M.stillKmh, 0)), M.size.shortest)
        precondition(length(arrow(60, 0)) > length(arrow(30, 0)))
        close(length(arrow(M.fastestKmh, 0)), M.size.longest)
        close(length(arrow(3 * M.fastestKmh, 0)), M.size.longest)
        close(M.length(0), M.size.shortest)

        // The head sits at the tip, as wide either side of the shaft.
        let up = arrow(0, 50)
        let (left, right) = (up.head.1, up.head.2)
        close(left.y, right.y)
        close(left.x, -right.x)
        close(abs(left.x), M.size.halfWidth)
        precondition(up.shaft.1 == CGPoint(x: 0, y: left.y))

        // The arrows are the motion of a forecast frame, and of an observed one shortly before them.
        let arrows = 1_700_000_000
        precondition(!M.stale(frame: arrows + 30 * 60, arrows: arrows, onForecast: true))
        precondition(!M.stale(frame: arrows - 10 * 60, arrows: arrows, onForecast: false))
        precondition(!M.stale(frame: arrows - M.staleAfter, arrows: arrows, onForecast: false))
        // Not of an observed frame well before them.
        precondition(M.stale(frame: arrows - M.staleAfter - 1, arrows: arrows, onForecast: false))
        precondition(M.stale(frame: arrows - 2 * 3600, arrows: arrows, onForecast: false))
        // With no frame or no arrows yet, nothing is stale.
        precondition(!M.stale(frame: nil, arrows: arrows, onForecast: false) && !M.stale(frame: arrows, arrows: nil, onForecast: false))
    }

    // MARK: - The loop (playbackLoop.test.ts)

    static func playbackLoop() {
        typealias P = PlaybackRules
        let minute = 60, now = 1_800_000_000
        func state(shown: Int = now, loopFrom: Int = now, fromStart: Bool = false, noForecast: Bool = false, only: [Int]? = nil) -> P.LoopState {
            P.LoopState(shown: shown, latestObservation: now, now: now, lastStep: now + 120 * minute, start: now - 120 * minute,
                        loopFrom: loopFrom, fromStart: fromStart, noForecast: noForecast, only: only)
        }
        // A full playback steps into the forecast and wraps to now at its end.
        precondition(P.nextFrame(state()) == now + 5 * minute && P.nextFrame(state(shown: now + 120 * minute)) == now)
        // With no forecast, playback stops at now and goes back to where it was started.
        precondition(P.nextFrame(state(shown: now - 5 * minute, loopFrom: now - 15 * minute, noForecast: true)) == now)
        precondition(P.nextFrame(state(loopFrom: now - 15 * minute, noForecast: true)) == now - 15 * minute)
        // With no forecast and play-from-start, the loop goes back to the start.
        precondition(P.nextFrame(state(loopFrom: now - 15 * minute, fromStart: true, noForecast: true)) == now - 120 * minute)
        // A forecast lost mid-playback ends the loop on the next frame, not in the wash.
        precondition(P.nextFrame(state(shown: now + 30 * minute, noForecast: true)) == now - 120 * minute)
        // With a radar open, playback skips the steps it has no sweep for and never enters the forecast.
        let only = [now - 30 * minute, now - 25 * minute, now - 10 * minute, now]
        precondition(P.nextFrame(state(shown: now - 25 * minute, loopFrom: now - 30 * minute, only: only)) == now - 10 * minute)
        precondition(P.nextFrame(state(shown: now - 20 * minute, loopFrom: now - 30 * minute, only: only)) == now - 10 * minute)
        // Past its last sweep: back to its first, not into the forecast.
        precondition(P.nextFrame(state(loopFrom: now - 30 * minute, only: only)) == now - 30 * minute)
        precondition(P.nextFrame(state(shown: now + 30 * minute, loopFrom: now + 30 * minute, only: only)) == now - 30 * minute)
        // Round every sweep, not only those after where play was pressed.
        precondition(P.nextFrame(state(loopFrom: now - 25 * minute, only: only)) == now - 30 * minute)
        precondition(P.nextFrame(state(loopFrom: now - 25 * minute, fromStart: true, only: only)) == now - 30 * minute)
        // A radar opened on a step it has no sweep for goes to its nearest one.
        let sweeps = [now - 30 * minute, now - 10 * minute, now]
        precondition(P.nearestStep(sweeps, to: now + 15 * minute) == now && P.nearestStep(sweeps, to: now - 20 * minute) == now - 30 * minute)
        precondition(P.nearestStep(sweeps, to: now - 15 * minute) == now - 10 * minute && P.nearestStep([], to: now) == nil)
    }

    // MARK: - Playback (playbackGate.test.ts, framePreload.test.ts)

    static func playbackGate() {
        typealias P = PlaybackRules
        // A step whose pictures are ready is moved on to at once; one not ready is waited for.
        precondition(P.shouldAdvance(ready: true, waited: 0))
        precondition(!P.shouldAdvance(ready: false, waited: 0) && !P.shouldAdvance(ready: false, waited: P.readyTimeout - 0.001))
        // Waited for long enough, playback moves on regardless.
        precondition(P.shouldAdvance(ready: false, waited: P.readyTimeout) && P.shouldAdvance(ready: false, waited: 0.2, timeout: 0.1))
        // The wait left shrinks with the wait so far, and never goes below nothing.
        precondition(P.waitLeft(0) == P.readyTimeout && P.waitLeft(0.4, timeout: 1) == 0.6 && P.waitLeft(5, timeout: 1) == 0)
        // Playback waits only while steps are being prepared ahead.
        precondition(P.holdsForTiles(.all) && P.holdsForTiles(.ahead))
        precondition(!P.holdsForTiles(.none), "with nothing filling the store, a wait would only time out")
        precondition(!P.holdsForTiles(.previews), "previews are not what a step waits for")
        precondition(!P.holdsForTiles(.all, moving: true) && !P.holdsForTiles(.ahead, moving: true), "nor while the map is being zoomed or panned")
        // The longest hold is a few frames of playback, not a stall.
        precondition(P.readyTimeout >= 1 && P.readyTimeout <= 2)
        // Playing, the steps to prepare are those the loop shows next, in its order, once round.
        let loop = { (shown: Int) in shown >= 1200 ? 600 : shown + 300 }
        precondition(P.playOrder(from: 900, next: loop, max: 10) == [900, 1200, 600])
        precondition(P.playOrder(from: 900, next: loop, max: 2) == [900, 1200])
        // A loop that never comes back to where it started stops when it repeats itself.
        precondition(P.playOrder(from: 300, next: { $0 >= 900 ? 600 : $0 + 300 }, max: 10) == [300, 600, 900])

        // What is loaded ahead.
        func mode(browsing: Bool = true, playing: Bool = false, slow: Bool = false, setting: Bool = true, shown: Bool = true) -> P.PreloadMode {
            P.preloadMode(setting: setting, radarShown: shown, browsing: browsing, playing: playing, slow: slow)
        }
        precondition(mode(browsing: false) == .none, "a map opened to look at now preloads nothing")
        precondition(mode() == .all && mode(playing: true) == .all)
        precondition(mode(slow: true) == .previews && mode(browsing: false, slow: true) == .none && mode(playing: true, slow: true) == .ahead)
        precondition(mode(playing: true, setting: false) == .none && mode(playing: true, shown: false) == .none)
        // Nearest the needle first, the later of two as near first; from either end across the whole timeline.
        precondition(P.preloadOrder([0, 300, 600, 900, 1200], from: 600) == [600, 900, 300, 1200, 0])
        precondition(P.preloadOrder([0, 300, 600], from: 0) == [0, 300, 600] && P.preloadOrder([0, 300, 600], from: 600) == [600, 300, 0])
    }

    // MARK: - Switching steps (frameSwitch.test.ts)

    static func frameSwitch() {
        typealias F = FrameSwitchRules
        typealias T = F.Tile
        // A missing tile is drawn from the nearest coarser one ready, two zooms up at most.
        var ready: Set<T> = [T(z: 5, x: 8, y: 10)]
        precondition(F.ancestor(of: T(z: 7, x: 33, y: 41), minZ: 3, has: ready.contains) == T(z: 5, x: 8, y: 10))
        precondition(F.ancestor(of: T(z: 8, x: 66, y: 82), minZ: 3, has: ready.contains) == nil, "three up is too coarse")
        ready.insert(T(z: 6, x: 16, y: 20))
        precondition(F.ancestor(of: T(z: 7, x: 33, y: 41), minZ: 3, has: ready.contains) == T(z: 6, x: 16, y: 20), "the nearest first")
        precondition(F.ancestor(of: T(z: 3, x: 4, y: 5), minZ: 3, has: { _ in true }) == nil, "none above the source's least zoom")
        precondition(F.ancestor(of: T(z: 8, x: 66, y: 82), minZ: 3, depth: F.ancestorReach, has: ready.contains) == T(z: 6, x: 16, y: 20))
        // Zooming out, a missing tile is drawn from the finer ones ready.
        let finer: Set<T> = [T(z: 6, x: 16, y: 20), T(z: 6, x: 17, y: 21)]
        precondition(F.children(of: T(z: 5, x: 8, y: 10), maxZ: 8, has: finer.contains) == [T(z: 6, x: 16, y: 20), T(z: 6, x: 17, y: 21)])
        precondition(F.children(of: T(z: 8, x: 8, y: 10), maxZ: 8, has: { _ in true }).isEmpty, "none past the source's deepest zoom")
        // A step is switched to only once every one of its tiles is settled.
        let settled: Set<String> = ["a", "b"]
        precondition(F.settled(["a", "b"], ready: settled.contains) && !F.settled(["a", "b", "c"], ready: settled.contains))
        precondition(F.settled([String](), ready: { _ in false }), "a step with nothing in view")
    }
}
