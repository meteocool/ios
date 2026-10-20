import Foundation
import simd

/// Checks the 3D storm map's rules, ported with core's own tests
/// (`scripts/tests/stormFrame`, `volumeTiles`, `cloudFaintness`,
/// `cloudFootprint`, `cloudSuccession`, `scans`, `tileStorms`, `cutaway`,
/// `gpuBudget`), and the MapLibre camera it stands on.
@main
struct NativeMapThreeDCheck {
    static func near(_ actual: Double, _ expected: Double, _ within: Double, _ what: String = "",
                     file: StaticString = #file, line: UInt = #line) {
        precondition(abs(actual - expected) <= within, "\(what) \(actual) is not within \(within) of \(expected)", file: file, line: line)
    }

    /// An `.mcvx` file as the worker writes one.
    static func mcvx(header: [String: Any], voxels: [UInt8]) -> Data {
        let json = try! JSONSerialization.data(withJSONObject: header)
        var data = Data("MCVX".utf8)
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { data.append(contentsOf: $0) } }
        u32(1)
        u32(json.count)
        data.append(json)
        data.append(contentsOf: voxels)
        return data
    }

    static let boxHeader: [String: Any] = [
        "code": "G1445718707", "reference_time": "2026-10-01T11:00:00Z", "lon": 7.0689, "lat": 54.5708,
        "nx": 160, "ny": 160, "nz": 32, "step_m": [250, 250, 500], "origin_m": [-20000, -20000, 0],
        "dbz_floor": -32, "dbz_scale": 2, "sites": ["deasb"], "coverage": 0.87, "tier": 2,
    ]

    typealias Field = (Double, Double, Double) -> Double?

    /// A 40 km box from `field` (km east, north, up from the box's middle and the ground).
    static func box(_ field: Field, unmeasured: Field = { _, _, _ in nil }) -> StormVolume {
        let (nx, ny, nz) = (160, 160, 32)
        var voxels = [UInt8](repeating: 0, count: nx * ny * nz * 2)
        for z in 0 ..< nz {
            for y in 0 ..< ny {
                for x in 0 ..< nx {
                    let at = ((z * ny + y) * nx + x) * 2
                    let east = (Double(x) + 0.5) * 0.25 - 20, north = (Double(y) + 0.5) * 0.25 - 20, up = (Double(z) + 0.5) * 0.5
                    if let blind = unmeasured(east, north, up) {
                        voxels[at] = UInt8((blind + 32) * 2)
                        continue
                    }
                    let dbz = field(east, north, up)
                    voxels[at] = dbz.map { UInt8(max(0, ($0 + 32) * 2)) } ?? 0
                    voxels[at + 1] = 200
                }
            }
        }
        return try! StormVolume.decode(mcvx(header: boxHeader, voxels: voxels))
    }

    static func disc(_ e: Double, _ n: Double, _ radius: Double, _ top: Double, _ dbz: Double) -> Field {
        { east, north, up in hypot(east - e, north - n) <= radius && up <= top ? dbz : nil }
    }

    static func layered(_ fields: Field...) -> Field {
        { east, north, up in
            for field in fields { if let dbz = field(east, north, up) { return dbz } }
            return nil
        }
    }

    static let showers: Field = { east, north, up in
        up <= 3 ? 21 + Double((Int(floor(east)) + Int(floor(north))) & 3) : nil
    }

    static func main() {
        checkTiles()
        cellVolumes()
        checkFootprint()
        checkLocate()
        checkFraming()
        checkFaintness()
        checkCut()
        checkTileStorms()
        checkScans()
        checkCamera()
        checkStyle()
        print("NativeMapThreeDCheck: all checks passed")
    }

    // MARK: volumeTiles.test.ts

    static func checkTiles() {
        precondition(CloudTiles.code(10, 544, 355) == "T100054400355")
        precondition(CloudTiles.code(11, 1089, 711) == "T110108900711")
        let (lon, lat) = CloudTiles.centre(10, 544, 355)
        near(lon, 11.42578125, 1e-9)
        near(lat, 48.1074311884804, 1e-9)
        let b = CloudTiles.bounds(10, 544, 355)
        near(b.west, 11.25, 1e-9)
        near(b.east, 11.6015625, 1e-9)
        precondition(b.south < lat && lat < b.north)
        near(CloudTiles.bounds(10, 544, 354).south, b.north, 1e-12)

        func listed(_ path: String, _ tile: [Int]?, _ coarse: Bool = false) -> CloudEntry {
            CloudEntry(path: path, code: path, lon: 0, lat: 0, tile: tile, coarse: coarse, peakDbz: 40)
        }
        let clouds = [listed("coarse", [9, 272, 177], true), listed("in", [10, 544, 354]), listed("core-in", [11, 1089, 709]),
                      listed("elsewhere", [10, 600, 354]), listed("old-box", nil)]
        precondition(CloudTiles.atLevel(clouds, coarse: { _ in true }).map(\.path) == ["coarse", "elsewhere", "old-box"])
        precondition(CloudTiles.atLevel(clouds, coarse: { _ in false }).map(\.path) == ["in", "core-in", "elsewhere", "old-box"])
        let open = [listed("coarse", [9, 272, 177], true), listed("in", [10, 544, 354]), listed("next", [10, 545, 354])]
        precondition(CloudTiles.atLevel(open, coarse: { _ in true }, openPath: "in").map(\.path) == ["in", "next"])
        let mixed = [listed("near", [9, 272, 177], true), listed("near-tile", [10, 544, 354]),
                     listed("far", [9, 280, 170], true), listed("far-tile", [10, 560, 340])]
        precondition(CloudTiles.atLevel(mixed, coarse: { $0[1] == 280 }).map(\.path) == ["far", "near-tile"])

        let taps = [listed("coarse", [9, 272, 177], true), listed("tile", [10, 544, 355]), listed("core", [11, 1089, 710])]
        precondition(CloudTiles.fineAt(taps, lon: 11.576, lat: 48.137)?.path == "core")
        precondition(CloudTiles.fineAt(taps, lon: 11.35, lat: 48.0)?.path == "tile")
        precondition(CloudTiles.fineAt(taps, lon: 2.35, lat: 48.85) == nil)

        // A tile draws itself and not its apron; texture sizes as the worker builds them.
        let tile = tileVolume(nx: 106, nz: 32, step: 137.2, tile: [10, 555, 240])
        near(Double(tile.drawnMin.x), 1.0 / 106, 1e-6)
        near(Double(tile.drawnMax.y), 105.0 / 106, 1e-6)
        precondition(tile.textureBytes == 719_104)
        precondition(tileVolume(nx: 54, nz: 32, step: 168.12, tile: [11, 1164, 553]).textureBytes == 186_624)
        precondition(listed("z10", [10, 1, 1]).textureBytes == 719_104 && listed("z9", [9, 1, 1], true).textureBytes == 186_624)
        let cloud = CloudVolume(tile)
        near(cloud.drawnExtentM.x, 104 * 137.2, 0.01)
        near(cloud.drawnExtentM.z, 16_000, 1e-9)
    }

    static func tileVolume(nx: Int, nz: Int, step: Double, tile: [Int], fill: UInt8 = 0) -> StormVolume {
        let header: [String: Any] = [
            "code": CloudTiles.code(tile[0], tile[1], tile[2]), "reference_time": "2026-10-20T00:25:00Z",
            "lon": 15.0, "lat": 68.0, "nx": nx, "ny": nx, "nz": nz, "step_m": [step, step, 500],
            "origin_m": [-Double(nx) / 2 * step, -Double(nx) / 2 * step, 0], "dbz_floor": -32, "dbz_scale": 2,
            "tile": tile, "apron": [1, 1, 0], "tier": 2, "coverage": 0.7,
        ]
        return try! StormVolume.decode(mcvx(header: header, voxels: [UInt8](repeating: fill, count: nx * nx * nz * 2)))
    }

    // MARK: cloudFootprint.test.ts

    static func checkFootprint() {
        let kmPerDeg = 2 * Double.pi * 6371.0088 / 360
        func offsetKm(_ from: SIMD2<Double>, _ to: SIMD2<Double>) -> SIMD2<Double> {
            let midLat = (from.y + to.y) / 2 * .pi / 180
            return SIMD2((to.x - from.x) * kmPerDeg * cos(midLat), (to.y - from.y) * kmPerDeg)
        }
        let ring = CloudTiles.footprint(lon: 7.75, lat: 48.58).ring
        precondition(ring.count == 5 && ring[0] == ring[4])
        near(offsetKm(ring[0], ring[1]).x, 40, 0.2)
        near(offsetKm(ring[0], ring[3]).y, 40, 0.2)
        precondition(abs(ring[1].x - ring[2].x) < 1e-12 && abs(ring[0].x - ring[3].x) < 1e-12)
        let sized = CloudTiles.footprint(lon: 10, lat: 52, extentM: SIMD2(30_000, 20_000)).ring
        near(offsetKm(sized[0], sized[1]).x, 30, 0.2)
        near(offsetKm(sized[0], sized[3]).y, 20, 0.2)
        let pivot = CloudTiles.footprint(lon: 7.75, lat: 48.58, centreKm: SIMD2(5, -3)).pivot
        near(offsetKm(SIMD2(7.75, 48.58), pivot).x, 5, 0.05)
        near(offsetKm(SIMD2(7.75, 48.58), pivot).y, -3, 0.05)
        // A tile's outline is the tile.
        let n = 1024.0
        let lonOf = { (x: Double) in x / n * 360 - 180 }
        let latOf = { (y: Double) in atan(sinh(.pi * (1 - 2 * y / n))) * 180 / .pi }
        let width = CloudTiles.widthM(10, lat: latOf(355.5))
        let tile = CloudTiles.footprint(lon: lonOf(544.5), lat: latOf(355.5), extentM: SIMD2(width, width)).ring
        near(tile[0].x, lonOf(544), 1e-9)
        near(tile[2].x, lonOf(545), 1e-9)
        near(tile[0].y, latOf(356), 1e-9)
        near(tile[2].y, latOf(355), 1e-9)
        // Halos: light on dark, dark on light, wider than the line, see-through.
        precondition(ThreeDPaint.boxCasing(dark: true).colour.r > 0.8 && ThreeDPaint.boxCasing(dark: false).colour.r < 0.25)
        for dark in [true, false] {
            let casing = ThreeDPaint.boxCasing(dark: dark)
            precondition(casing.width > ThreeDPaint.boxWidth && casing.colour.a > 0 && casing.colour.a < 0.5)
        }
    }

    // MARK: stormFrame.test.ts (locateStorm)

    static func checkLocate() {
        var storm = CloudMath.locateStorm(box(layered(disc(0, 0, 5, 7, 29), showers)))
        near(storm.halfKm.x, 5, 0.5)
        near(storm.halfKm.y, 5, 0.5)
        near(storm.centreKm.x, 0, 0.5)
        near(storm.centreKm.y, 0, 0.5)
        storm = CloudMath.locateStorm(box(layered(disc(0, 0, 4, 7, 40), disc(13, 9, 5, 10, 50))))
        near(storm.halfKm.x, 4, 0.5)
        near(storm.centreKm.x, 0, 0.5)
        let crescent: Field = { east, north, up in
            let r = hypot(east, north)
            return r >= 2 && r <= 6 && east > -2 && up <= 8 ? 35 : nil
        }
        storm = CloudMath.locateStorm(box(layered(crescent, disc(-15, -15, 3, 6, 45))))
        near(storm.centreKm.x, 2, 0.5)
        near(storm.halfKm.y, 6, 0.5)
        storm = CloudMath.locateStorm(box(layered(disc(0, 0, 5, 9, 45), showers)))
        near(storm.centreKm.z + storm.halfKm.z, 9 - 8, 0.5)
        let cored = layered(disc(0, 0, 3, 8, 38), disc(0, 0, 9, 4, 27))
        near(CloudMath.locateStorm(box(cored)).halfKm.x, 9, 0.5)
        near(CloudMath.locateStorm(box(cored), stormDbz: 30).halfKm.x, 4, 0.5)
        let blind: Field = { east, _, _ in east > 10 ? 60 : nil }
        near(CloudMath.locateStorm(box(disc(0, 0, 5, 7, 40), unmeasured: blind)).halfKm.x, 5, 0.5)
        storm = CloudMath.locateStorm(box(disc(6, 0, 5, 4, 22)))
        near(storm.centreKm.x, 6, 0.5)
        near(storm.halfKm.x, 5, 0.5)
        storm = CloudMath.locateStorm(box { _, _, _ in nil })
        precondition(storm.centreKm == .zero && storm.halfKm == SIMD3(20, 20, 8))
    }

    // MARK: stormFrame.test.ts (framingCamera)

    static func checkFraming() {
        let phone = FramingRoom(width: 375, height: 812, top: 64, bottom: 812 * (1 - 0.32), left: 0, right: 375)
        precondition(FramingRoom.of(width: 375, height: 812, phone: true) == phone)
        let desktop = FramingRoom(width: 1440, height: 900, top: 64, bottom: 900 - 88, left: 0, right: 1440 - 416)
        precondition(FramingRoom.of(width: 1440, height: 900, phone: false) == desktop)
        let extentM = SIMD3(40_000.0, 40_000, 16_000)
        let header = (lon: 7.0689, lat: 54.5708)
        func frame(_ extent: StormExtent, _ direction: Double, _ room: FramingRoom) -> StormFraming.Camera {
            StormFraming.camera(lon: header.lon, lat: header.lat, extentM: extentM, extent: extent, directionDeg: direction,
                                room: room, pitchDeg: 76, maxZoom: 13, verticalScale: 1)
        }
        let whole = StormExtent(centreKm: .zero, halfKm: SIMD3(20, 20, 8))

        let storm = CloudMath.locateStorm(box(layered(disc(0, 0, 5, 7, 29), showers)))
        let camera = frame(storm, 90, phone)
        let tilt = 76 * Double.pi / 180
        let focal = phone.height / 2 / tan(36.8699 * Double.pi / 360)
        let above = atan(-camera.offsetY / focal)
        let atMiddle = StormFraming.worldMetresAtZoom0 * cos(header.lat * .pi / 180) / pow(2, camera.zoom)
        let atFoot = atMiddle * cos(tilt) / cos(tilt + above)
        near(atFoot * phone.width / 1000, 2 * storm.halfKm.x / StormFraming.openFill, 0.5)
        precondition(camera.zoom - frame(whole, 90, phone).zoom > 1.5)

        let tall = CloudMath.locateStorm(box(disc(0, 0, 5, 12, 50)))
        let foot = phone.height / 2 + frame(tall, 0, phone).offsetY
        precondition(foot > phone.top && foot < phone.bottom)

        let tiny = StormExtent(centreKm: SIMD3(0, 0, -7), halfKm: SIMD3(0.1, 0.1, 0.1))
        precondition(frame(tiny, 0, phone).zoom == 13)

        let offset = CloudMath.locateStorm(box(disc(8, -6, 4, 6, 40)))
        let centred = frame(offset, 0, phone)
        near((centred.lon - header.lon) * 111.32 * cos(header.lat * .pi / 180), 8, 0.3)
        near((centred.lat - header.lat) * 111.32, -6, 0.3)

        let wide = frame(storm, 90, desktop)
        near(desktop.width / 2 + wide.offsetX, (desktop.left + desktop.right) / 2, 1e-9)
        precondition(wide.zoom - frame(whole, 90, desktop).zoom > 1.5)

        // Facing the cut within a quarter turn, flipping the kept half if nearer.
        let straight = StormFraming.facing(direction: 90, bearing: 0)
        precondition(straight.off == 0 && !straight.flipped)
        let flipped = StormFraming.facing(direction: -90, bearing: 0)
        precondition(abs(flipped.off) <= 90)
        // The sweep: two swings of ±70° over 24 s, then rest.
        near(CutSweep.angle(at: 6)!, 70, 1e-9)
        near(CutSweep.angle(at: 18)!, -70, 1e-9)
        precondition(CutSweep.angle(at: 48) == nil)
        // The dial: detents within 7° of an axis, whole degrees otherwise, resets to the nearer half.
        precondition(SliceDialMath.settle(84) == 90 && SliceDialMath.settle(82.6) == 83 && SliceDialMath.reset(100) == 180)
        precondition(SliceDialMath.offAxis(30) && !SliceDialMath.offAxis(180) && !SliceDialMath.offAxis(0))
    }

    // MARK: cloudFaintness.test.ts

    static func checkFaintness() {
        func column(_ dbz: Double, _ km: Double, _ tall: Double, _ confidence: Double = 1) -> StormVolume {
            let (nx, ny, nz) = (160, 160, 32)
            var voxels = [UInt8](repeating: 0, count: nx * ny * nz * 2)
            let half = km * 4 / 2
            for z in 0 ..< nz {
                for y in 0 ..< ny {
                    for x in 0 ..< nx where abs(Double(x - nx / 2)) < half && abs(Double(y - ny / 2)) < half && Double(z) < tall * 2 {
                        let at = ((z * ny + y) * nx + x) * 2
                        voxels[at] = UInt8(((dbz + 32) * 2).rounded())
                        voxels[at + 1] = UInt8((confidence * 255).rounded())
                    }
                }
            }
            return try! StormVolume.decode(mcvx(header: boxHeader, voxels: voxels))
        }
        precondition(CloudMath.solidKm2(box { _, _, _ in nil }) == 0)
        precondition(CloudMath.solidKm2(column(21, 4, 2)) == 0)
        let core = column(45, 3, 6)
        precondition(CloudMath.solidKm2(core) >= 9 && !CloudVolume(core).isFaint)
        precondition(CloudVolume(column(45, 3, 6, 0.05)).isFaint)
        precondition(!CloudVolume(column(30, 10, 1)).isFaint)
        precondition(CloudVolume(column(24, 40, 1)).isFaint)
    }

    // MARK: volumeTiles.test.ts (cut, peel)

    static func model(_ x: Double, _ y: Double, _ size: Double, _ height: Double) -> simd_double4x4 {
        simd_double4x4(columns: (SIMD4(size, 0, 0, 0), SIMD4(0, -size, 0, 0), SIMD4(0, 0, height, 0), SIMD4(x, y + size, 0, 1)))
    }

    static func checkCut() {
        let floors = CloudMath.peelFloors([("weak", "T1", 28, true), ("core", "T1", 52, true), ("other", "T2", 33, true),
                                           ("old", nil, 41, true)])
        precondition(floors == ["weak": 52, "core": 52, "other": 33, "old": 41])
        let held = CloudMath.peelFloors([("seen", "T1", 30, true), ("unseen", "T1", 60, false)])
        precondition(held["seen"] == 30 && held["unseen"] == 20)

        let opened = model(0.5, 0.3, 0.001, 0.0002)
        let point = CloudMath.cutPoint(model: opened, extentM: SIMD3(26_000, 26_000, 16_000), centreKm: SIMD3(6.5, -3.25, 4))
        near(point.x, 0.5 + 0.75 * 0.001, 1e-12)
        near(point.y, 0.3 + 0.001 - 0.375 * 0.001, 1e-12)

        let east = model(0.501, 0.3, 0.001, 0.0002)
        let along = 30 * Double.pi / 180
        let at = SIMD3(0.5008, 0.3005, 0.0001)
        let there = CloudMath.carryCut(model: east, opened: opened, point: at, along: along)
        let here = CloudMath.carryCut(model: opened, opened: opened, point: at, along: along)
        near(here.normal.x, cos(along), 1e-12)
        near(here.normal.y, -sin(along), 1e-12)
        near(there.point.x, here.point.x - 1, 1e-9)
        near(there.point.y, here.point.y, 1e-9)
        let onPlane = SIMD3(here.point.x - sin(along) * 0.2, here.point.y - cos(along) * 0.2, 0.3)
        near(simd_dot(here.normal, onPlane - here.point), 0, 1e-12)
        near(simd_dot(there.normal, SIMD3(onPlane.x - 1, onPlane.y, onPlane.z) - there.point), 0, 1e-9)

        let metre = 0.001 / 25_000
        let point2 = SIMD3(0.5005, 0.3005, 0.0)
        let whole = (SIMD3<Double>(0, 0, 0), SIMD3<Double>(1, 1, 1))
        precondition(CloudMath.kmFromCut(model: model(0.5, 0.3, 0.001, 0.0002), boxMin: whole.0, boxMax: whole.1, point: point2, metre: metre) == 0)
        near(CloudMath.kmFromCut(model: model(0.501, 0.3, 0.001, 0.0002), boxMin: whole.0, boxMax: whole.1, point: point2, metre: metre), 12.5, 1e-9)
        near(CloudMath.kmFromCut(model: model(0.502, 0.3, 0.001, 0.0002), boxMin: whole.0, boxMax: whole.1, point: point2, metre: metre), 37.5, 1e-9)
        near(CloudMath.kmFromCut(model: model(0.501, 0.301, 0.001, 0.0002), boxMin: whole.0, boxMax: whole.1, point: point2, metre: metre),
             hypot(12.5, 12.5), 1e-9)
        near(CloudMath.kmFromCut(model: model(0.501, 0.3, 0.001, 0.0002), boxMin: SIMD3(0.5, 0, 0), boxMax: whole.1, point: point2,
                                 metre: metre), 25, 1e-9)

        let normal = SIMD3<Double>(1, 0, 0)
        precondition(!CloudMath.cutAway(boxMin: whole.0, boxMax: whole.1, normal: normal, point: SIMD3(0.5, 0, 0)))
        precondition(CloudMath.cutAway(boxMin: whole.0, boxMax: whole.1, normal: normal, point: SIMD3(-0.1, 0, 0)))
        precondition(!CloudMath.cutAway(boxMin: whole.0, boxMax: whole.1, normal: normal, point: SIMD3(1.1, 0, 0)))

        // The peel: held whole until 0.1, at the core from 0.45 to 0.6, whole again by 0.95.
        precondition(CloudMath.peelAt(0.5) == 0 && CloudMath.peelAt(5) == 1 && CloudMath.peelAt(9.6) == 0)
        precondition(CloudMath.peelAt(2.75) > 0 && CloudMath.peelAt(2.75) < 1)

        // cutaway.test.ts
        precondition(CloudMath.normaliseCut(0) == 0 && CloudMath.normaliseCut(360) == 0)
        precondition(CloudMath.normaliseCut(190) == -170 && CloudMath.normaliseCut(-190) == 170 && CloudMath.normaliseCut(-180) == -180)
        precondition(CloudMath.normaliseCut(0) != CloudMath.normaliseCut(180))
        let t: (String, [String: Any]) -> String = { key, values in
            values.isEmpty ? key : "\(key)(\(values.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ",")))"
        }
        precondition(CloudMath.cutLabel(0, track: true, t) == "storm.cut.along")
        precondition(CloudMath.cutLabel(90, track: true, t) == "storm.cut.across")
        precondition(CloudMath.cutLabel(-90, track: true, t) == "storm.cut.across")
        precondition(CloudMath.cutLabel(40, track: true, t) == "storm.cut.off_track(deg=40)")
        precondition(CloudMath.cutLabel(180, track: true, t) == CloudMath.cutLabel(0, track: true, t))
        precondition(CloudMath.cutLabel(140, track: true, t) == CloudMath.cutLabel(40, track: true, t))
        precondition(CloudMath.cutLabel(0, track: false, t) == "storm.cut.north_south")
        precondition(CloudMath.cutLabel(90, track: false, t) == "storm.cut.east_west")
        precondition(CloudMath.cutLabel(30, track: false, t) == "storm.cut.off_north(deg=30)")
    }

    // MARK: tileStorms.test.ts

    static func stormTile(_ z: Int, _ x: Int, _ y: Int, dbz: Double = 40, _ echo: (Int, Int) -> Double?) -> CloudMath.StormTile {
        let (nx, ny, nz) = (6, 6, 2)
        var voxels = [UInt8](repeating: 0, count: nx * ny * nz * 2)
        for row in 1 ..< ny - 1 {
            for column in 1 ..< nx - 1 {
                guard let found = echo(column - 1, row - 1) else { continue }
                let at = ((1 * ny + row) * nx + column) * 2
                voxels[at] = UInt8((found + 32) * 2)
                voxels[at + 1] = 255
            }
        }
        let header: [String: Any] = [
            "code": "T", "reference_time": "2026-10-01T00:00:00Z", "lon": 0, "lat": 0, "nx": nx, "ny": ny, "nz": nz,
            "step_m": [250, 250, 500], "origin_m": [-750, -750, 0], "dbz_floor": -32, "dbz_scale": 2,
            "tile": [z, x, y], "apron": [1, 1, 0], "network": "de",
        ]
        let volume = try! StormVolume.decode(mcvx(header: header, voxels: voxels))
        return CloudMath.StormTile(network: "de", tile: [z, x, y], system: nil, edges: CloudMath.tileEdges(volume))
    }

    static func checkTileStorms() {
        let everywhere: (Int, Int) -> Double? = { _, _ in 40 }
        let corner = stormTile(10, 0, 0) { column, row in column == 0 && row == 3 ? 40 : nil }.edges!
        precondition(corner.north == [1, 0, 0, 0] && corner.west == [1, 0, 0, 0] && corner.south == [0, 0, 0, 0] && corner.east == [0, 0, 0, 0])

        var storms = CloudMath.stormsOf([("west", stormTile(10, 100, 200, everywhere)), ("east", stormTile(10, 101, 200, everywhere)),
                                         ("south", stormTile(10, 101, 201, everywhere))])
        precondition(Set(storms.values).count == 1)
        storms = CloudMath.stormsOf([("west", stormTile(10, 100, 200) { column, _ in column < 2 ? 40 : nil }),
                                     ("east", stormTile(10, 101, 200, everywhere)),
                                     ("weak", stormTile(10, 102, 200) { _, _ in 20 })])
        precondition(Set(storms.values).count == 3)
        storms = CloudMath.stormsOf([("west", stormTile(10, 100, 200, everywhere)),
                                     ("middle", stormTile(10, 101, 200) { column, _ in column == 0 ? 50 : column == 3 ? 30 : nil }),
                                     ("east", stormTile(10, 102, 200, everywhere))])
        precondition(storms["middle"] == storms["west"] && storms["east"] != storms["west"])
        storms = CloudMath.stormsOf([("a", stormTile(10, 100, 200, everywhere)), ("b", stormTile(10, 101, 201, everywhere))])
        precondition(storms["a"] != storms["b"])
        storms = CloudMath.stormsOf([("coarse", stormTile(9, 0, 0, everywhere)), ("north", stormTile(10, 2, 0, everywhere)),
                                     ("south", stormTile(10, 2, 1, everywhere)), ("far", stormTile(10, 2, 2, everywhere))])
        precondition(storms["north"] == storms["coarse"] && storms["south"] == storms["coarse"] && storms["far"] == storms["coarse"])
        let cornered = CloudMath.stormsOf([("coarse", stormTile(9, 0, 0, everywhere)), ("far", stormTile(10, 2, 2, everywhere))])
        precondition(cornered["far"] != cornered["coarse"])
        func named(_ system: String, _ x: Int) -> CloudMath.StormTile {
            var tile = stormTile(10, x, 200, everywhere)
            tile.system = system
            return tile
        }
        storms = CloudMath.stormsOf([("a", named("T1", 100)), ("b", named("T2", 101)), ("c", stormTile(10, 102, 200, everywhere)),
                                     ("d", named("T1", 105))])
        precondition(storms == ["a": "T1", "b": "T2", "c": "T2", "d": "T1"])
        var nl = stormTile(10, 101, 200, everywhere)
        nl.network = "nl"
        storms = CloudMath.stormsOf([("de", stormTile(10, 100, 200, everywhere)), ("nl", nl),
                                     ("box", CloudMath.StormTile(network: "de", tile: nil, system: nil, edges: nil))])
        precondition(Set(storms.values).count == 3)
    }

    // MARK: scans.test.ts, cloudSuccession.test.ts

    static func checkScans() {
        precondition(CloudScans.scanTime("2026-10-01T00:05:00Z") == 1_790_813_100)
        precondition(CloudScans.scanTime(nil) == nil && CloudScans.scanTime("not a time") == nil)
        let at = { (hhmm: String) in CloudScans.scanTime("2026-10-01T\(hhmm):00Z")! }
        precondition(CloudScans.isBehind(at("00:00"), radar: at("00:05")) && !CloudScans.isBehind(at("00:05"), radar: at("00:05")))
        precondition(!CloudScans.isBehind(at("00:00"), radar: nil) && !CloudScans.isBehind(nil, radar: at("00:05")))
        precondition(CloudScans.offers(at("00:05"), after: nil) && !CloudScans.offers(at("00:00"), after: at("00:05")))
        precondition(CloudScans.offers(at("00:01"), after: at("00:01")))

        let later = { (path: String, network: String) in
            CloudEntry(path: path, code: path, lon: 0, lat: 0, referenceTime: "2026-10-01T10:25:00Z", network: network)
        }
        let open = (path: "a/1020/de-1", network: "de", time: "2026-10-01T10:20:00Z")
        precondition(CloudScans.isPastItsScan(path: open.path, network: open.network, referenceTime: open.time,
                                              listed: [later("b/1025/de-1", "de"), later("b/1025/de-2", "de")]))
        let itself = CloudEntry(path: open.path, code: "x", lon: 0, lat: 0, referenceTime: open.time, network: "de")
        precondition(!CloudScans.isPastItsScan(path: open.path, network: open.network, referenceTime: open.time,
                                               listed: [itself, later("b/1025/de-2", "de")]))
        precondition(!CloudScans.isPastItsScan(path: open.path, network: open.network, referenceTime: open.time,
                                               listed: [later("b/1025/ch-1", "ch")]))
        precondition(!CloudScans.isPastItsScan(path: open.path, network: open.network, referenceTime: open.time, listed: []))
        precondition(CloudScans.isPastItsScan(path: open.path, network: nil, referenceTime: open.time, listed: [later("b/1025/de-1", "de")]))

        func storm(_ lon: Double, _ lat: Double, _ half: Double, _ centre: SIMD2<Double> = .zero) -> CloudVolume {
            var header = boxHeader
            header["lon"] = lon
            header["lat"] = lat
            let volume = try! StormVolume.decode(mcvx(header: header, voxels: [UInt8](repeating: 0, count: 160 * 160 * 32 * 2)))
            var cloud = CloudVolume(volume)
            cloud.overrideExtent(StormExtent(centreKm: SIMD3(centre.x, centre.y, 0), halfKm: SIMD3(half, half, 4)))
            return cloud
        }
        precondition(CloudScans.isSuccessor(storm(9.71087, 54.40429, 19.875), storm(9.71080, 54.41302, 19.875)))
        precondition(CloudScans.isSuccessor(storm(9, 54, 3), storm(9.05, 54, 3)))
        precondition(!CloudScans.isSuccessor(storm(9, 54, 10), storm(9 + 18 / (111.32 * cos(54 * Double.pi / 180)), 54, 10)))
        let dx = 30 / (111.32 * cos(54 * Double.pi / 180))
        precondition(CloudScans.isSuccessor(storm(9, 54, 5, SIMD2(14, 0)), storm(9 + dx, 54, 5, SIMD2(-15, 0))))
        precondition(!CloudScans.isSuccessor(storm(9, 54, 5), storm(9 + dx, 54, 5)))
    }

    // MARK: The camera

    static func checkCamera() {
        var camera = MapCamera(lon: 11.5, lat: 48.1, zoom: 8, pitch: 55, bearing: 30, width: 390, height: 844)
        // The centre is drawn in the middle of the screen, at any tilt and heading.
        let c = camera.centre
        let middle = camera.project(SIMD3(c.x, c.y, 0)).point
        near(middle.x, 195, 1e-6)
        near(middle.y, 422, 1e-6)
        // A screen point and the ground under it are one round trip.
        let ground = camera.ground(SIMD2(100, 600))!
        let back = camera.project(SIMD3(ground.x, ground.y, 0)).point
        near(back.x, 100, 1e-5)
        near(back.y, 600, 1e-5)
        // Looking straight down at zoom z, 512·2^z points span the world.
        var flat = camera
        flat.pitch = 0
        flat.bearing = 0
        let left = flat.ground(SIMD2(0, 422))!, right = flat.ground(SIMD2(390, 422))!
        near((right.x - left.x) * flat.worldSize, 390, 1e-6)
        // North is up with no bearing; a bearing of 90 puts east up.
        let north = flat.project(SIMD3(c.x, c.y - 0.001, 0)).point
        precondition(north.y < 422 && abs(north.x - 195) < 1e-6)
        flat.bearing = 90
        let east = flat.project(SIMD3(c.x + 0.001, c.y, 0)).point
        precondition(east.y < 422 && abs(east.x - 195) < 1e-6)
        // The camera stands behind the centre, opposite where it looks.
        flat.bearing = 0
        flat.pitch = 55
        precondition(flat.position.y > c.y && flat.position.z > 0)
        // Depth runs 0…1 from the near plane to the far one.
        let depth = Matrix.apply(camera.viewProjection, SIMD3(c.x, c.y, 0))
        precondition(depth.z / depth.w > 0 && depth.z / depth.w < 1)
        // Limits: zoom 3.5 to 13, tilt to 84.
        camera.zoom = 20
        camera.pitch = 89
        camera.constrain()
        precondition(camera.zoom == 13 && camera.pitch == 84)
        // An ease with an offset lands the target that far from the middle.
        let start = MapCamera(lon: 11.5, lat: 48.1, zoom: 8, pitch: 55, bearing: 0, width: 390, height: 844)
        let ease = CameraEase(from: start, center: (11.6, 48.2), zoom: 10, pitch: 76, bearing: 40, offset: SIMD2(0, 120),
                              duration: 0.9, now: 0)
        let end = ease.target
        near(end.zoom, 10, 1e-9)
        near(end.pitch, 76, 1e-9)
        near(end.bearing, 40, 1e-9)
        let target = Mercator.point(lon: 11.6, lat: 48.2)
        let landed = end.project(SIMD3(target.x, target.y, 0)).point
        near(landed.x, 195, 0.01)
        near(landed.y, 422 + 120, 0.01)
        precondition(CameraEase.normaliseBearing(170, from: -170) == -190)
        near(UnitBezier.ease.solve(0), 0, 1e-6)
        near(UnitBezier.ease.solve(1), 1, 1e-6)
        // Covering tiles: finer under the camera, coarser towards the horizon, none past zoom limits.
        let tiles = start.coveringTiles(maxZoom: 14)
        precondition(!tiles.isEmpty && tiles.count < 120, "\(tiles.count) tiles")
        precondition(tiles.first!.z == 8 && tiles.allSatisfy { $0.z <= 8 }, "\(tiles.prefix(4))")
        precondition(tiles.contains { $0.z < 8 })
        let bounds = start.bounds
        precondition(bounds.west < 11.5 && bounds.east > 11.5 && bounds.south < 48.1 && bounds.north > 48.1)
        // Tile rects: a child's quarter of its parent.
        precondition(MapTile(11, 1089, 710).rect(in: MapTile(10, 544, 355)) == SIMD4(0.5, 0, 0.5, 0.5))
    }

    static func checkStyle() {
        // core's muteTheme: water #cfe0ec over earth #f6f4f0.
        let light = BasemapTheme.of(dark: false)
        precondition(light.earth.hex == "#f6f4f0")
        precondition(light.boundaryCountry.hex == "#9a958c")
        precondition(light.water.hex == "#dbe3e9", light.water.hex)
        precondition(BasemapTheme.of(dark: true).landcover["forest"]!.a < 0.1)
        near(BasemapTheme.width(1.6, zoom: 6), 0.8, 1e-9)
        near(BasemapTheme.width(1.6, zoom: 14), 3.52, 1e-9)
        // Labels: no villages below MapLibre zoom 12, cities always.
        precondition(!PlaceLabels.shows(kind: "locality", detail: "village", minZoom: nil, zoom: 11))
        precondition(PlaceLabels.shows(kind: "locality", detail: "village", minZoom: nil, zoom: 12))
        precondition(PlaceLabels.shows(kind: "locality", detail: "city", minZoom: 5, zoom: 4))
        precondition(!PlaceLabels.shows(kind: "locality", detail: "city", minZoom: 7, zoom: 5))
        precondition(PlaceLabels.tier(kind: "locality", detail: "town") == PlaceLabels.locality)
        // Box colours: the palette at the peak, never grey.
        let box = ThreeDPaint.boxColour(dbz: 50, palette: "classic")
        let palette = Colormaps.colour(dbz: 50, palette: "classic")
        near(box.r * 255, Double(palette.x), 0.6)
        near(box.g * 255, Double(palette.y), 0.6)
    }
}

extension NativeMapThreeDCheck {
    /// core's `scripts/tests/cellVolume.test.ts`.
    static func cellVolumes() {
        typealias P = CellVolumeModel.Point
        let square: [[Double]] = [[9, 51], [11, 51], [11, 53], [9, 53]]
        let layers = [
            CellThreshold(dbz: 30, areaKm2: 95, topM: 9200, volumeKm3: 400, rings: nil),
            CellThreshold(dbz: 45, areaKm2: 30, topM: 7600, volumeKm3: 100, rings: nil),
            CellThreshold(dbz: 55, areaKm2: 4, topM: 6100, volumeKm3: 12, rings: nil),
        ]
        func cell(_ structure: [CellThreshold], lon: Double = 10, lat: Double = 52) -> CellVolumeModel.Input {
            CellVolumeModel.Input(code: "2026092012050010000000", lon: lon, lat: lat, echoBottomM: 1200, polygon: square, structure: structure)
        }
        func area(_ ring: [P]) -> Double { abs(CellVolumeModel.shoelace(ring.map { (x: $0.lon, y: $0.lat) })) }
        let squareRing: [P] = square.map { ($0[0], $0[1]) }

        // A shell scaled to a quarter of the area is half the width; none collapses.
        let scaled = CellVolumeModel.scale(squareRing, about: (10, 52), ratio: 0.25)
        near(area(scaled) / area(squareRing), 0.25, 1e-9)
        near(scaled[0].lon, 9.5, 1e-12)
        precondition(CellVolumeModel.scale(squareRing, about: (10, 52), ratio: 0).allSatisfy { $0.lon == 10 && $0.lat == 52 })

        // The solved exponent gives a profile of the mean it was asked for.
        for wanted in [0.12, 0.25, 0.4, 0.55, 0.7, 0.9] {
            let exponent = CellVolumeModel.exponentForMean(wanted)
            let n = 400
            let mean = (0 ..< n).reduce(0.0) { $0 + CellVolumeModel.profile((Double($1) + 0.5) / Double(n), exponent: exponent) } / Double(n)
            near(mean, wanted, 0.02, "mean for \(wanted)")
        }
        precondition(CellVolumeModel.exponentForMean(0.3) > CellVolumeModel.exponentForMean(0.6))
        for exponent in [0.5, 1, 3] {
            for k in 1 ... 40 {
                precondition(CellVolumeModel.profile(Double(k) / 40, exponent: exponent) <= CellVolumeModel.profile(Double(k - 1) / 40, exponent: exponent) + 1e-12)
            }
        }

        // A storm with volume to spare stands on its echo base.
        let model = CellVolumeModel.model(cell(layers))!
        precondition(model.base == 1200 && model.top == 9200)

        // A body too thin for its column hangs under its own top.
        let wispy = CellVolumeModel.model(cell([
            CellThreshold(dbz: 30, areaKm2: 95, topM: 9200, volumeKm3: 400, rings: nil),
            CellThreshold(dbz: 45, areaKm2: 40, topM: 8000, volumeKm3: 2, rings: nil),
        ]))!
        precondition(wispy.base == model.base)
        let lowest = wispy.bands.map(\.base).min()!
        let with45 = wispy.bands.filter { $0.rings.contains { $0.dbz == 45 } }
        precondition(!with45.isEmpty && with45.map(\.base).min()! > lowest + 3000)

        precondition(CellVolumeModel.model(cell([])) == nil)

        // Bands stack without overlapping; rings never touch; only the innermost is opaque.
        for (index, band) in model.bands.enumerated() {
            precondition(band.top > band.base)
            if index > 0 { precondition(band.base >= model.bands[index - 1].top - 1e-6) }
            for (i, ring) in band.rings.enumerated() {
                let innermost = i == band.rings.count - 1
                precondition(ring.outer > ring.inner)
                if i + 1 < band.rings.count {
                    precondition(ring.inner > band.rings[i + 1].outer)
                    precondition(band.rings[i + 1].dbz >= ring.dbz)
                }
                precondition((ring.alpha == 1) == innermost && (ring.inner == 0) == innermost)
            }
        }

        // A centroid adrift of its outline does not drag the model with it.
        let adrift = CellVolumeModel.model(cell(layers, lon: 40, lat: 12))!
        precondition(adrift.centre.lon > 9 && adrift.centre.lon < 11 && adrift.centre.lat > 51 && adrift.centre.lat < 53)

        // Every piece has somewhere to stand, and holes are smaller than their rings.
        let pieces = CellVolumeModel.pieces(model)
        precondition(!pieces.isEmpty && pieces.contains { $0.hole != nil })
        for piece in pieces {
            precondition(piece.top > piece.base && piece.base >= 0)
            if let hole = piece.hole { precondition(area(hole) < area(piece.outer)) }
        }

        // Measured cores: two where the radar saw two, where they were, sized by the profile.
        let west: [[Double]] = [[9.2, 51.2], [9.6, 51.2], [9.6, 51.6], [9.2, 51.6]]
        let east: [[Double]] = [[10.4, 52.4], [10.8, 52.4], [10.8, 52.8], [10.4, 52.8]]
        let measured = CellVolumeModel.model(cell([
            layers[0], CellThreshold(dbz: 45, areaKm2: 30, topM: 7600, volumeKm3: 100, rings: [west, east]), layers[2],
        ]))!
        func cores(_ model: CellVolumeModel.Model) -> [CellVolumeModel.Piece] { CellVolumeModel.pieces(model).filter { $0.tier == 0 && $0.dbz == 45 } }
        let before = cores(model), after = cores(measured)
        precondition(!before.isEmpty && after.count == before.count * 2)
        let centres = after.map { $0.outer.reduce(0) { $0 + $1.lon } / Double($0.outer.count) }
        precondition(centres.min()! < 9.8 && centres.max()! > 10.2)
        var byBand: [Double: Double] = [:]
        for piece in after { byBand[piece.base, default: 0] += area(piece.outer) }
        let areas = byBand.sorted { $0.key < $1.key }.map(\.value)
        precondition(areas.count > 1 && areas.indices.allSatisfy { $0 == 0 || areas[$0] <= areas[$0 - 1] + 1e-12 })

        // As `/cells/current` sends a layer.
        let json = #"{"dbz": 30, "area_km2": 27.4, "top_m": 4036.0, "volume_km3": 70.2, "rings": [[[4.9, 50.3], [4.91, 50.3], [4.91, 50.31], [4.9, 50.31]]]}"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let layer = try! decoder.decode(CellThreshold.self, from: Data(json.utf8))
        precondition(layer.topM == 4036 && layer.rings?.first?.count == 4)
    }
}

extension CloudVolume {
    /// For the checks: a storm placed by hand rather than found in its voxels.
    mutating func overrideExtent(_ extent: StormExtent) {
        self = CloudVolume(volume: volume, extent: extent, solidKm2: solidKm2, edges: edges, peakDbz: peakDbz)
    }
}
