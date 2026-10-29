import Foundation

/// Checks site mode's rules (`meteocool/NativeMap/Sites/SiteSweepRules.swift`)
/// with core's own tests, one for one: `scripts/tests/siteSweeps.test.ts`,
/// `sweep.test.ts` and `sweepGeometry.test.ts`, then Borkum's real sweeps
/// (core's `tests/ui/fixtures/sweeps`, gunzipped by `scripts/check.sh` into
/// the directory given as the first argument).
@main
struct NativeMapSitesCheck {
    static var count = 0

    static func test(_ name: String, _ body: () -> Void) {
        body()
        count += 1
    }

    static func main() {
        srvMotion()
        siteSweeps()
        sweep()
        geometry()
        fixtures(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil)
        print("NativeMapSitesCheck: \(count) checks passed")
    }

    static func srvMotion() {
        typealias M = SrvMotionRules
        test("a finger on the dial points the way it is from the centre, clockwise from north") {
            precondition(M.headingFromPoint(dx: 0, dy: -40) == 0 && M.headingFromPoint(dx: 40, dy: 0) == 90)
            precondition(M.headingFromPoint(dx: 0, dy: 40) == 180 && M.headingFromPoint(dx: -40, dy: 0) == 270)
            precondition(M.headingFromPoint(dx: 30, dy: -30) == 45 && M.headingFromPoint(dx: -30, dy: 30) == 225)
        }
        test("the dial snaps to five degrees, and just west of north is north") {
            precondition(M.headingFromPoint(dx: 10, dy: -100) == 5 && M.headingFromPoint(dx: -1, dy: -100) == 0)
            precondition(M.snapHeading(357.6) == 0 && M.snapHeading(-92) == 270 && M.snapHeading(722) == 0)
            precondition(M.headingFromPoint(dx: 0, dy: 0) == nil)
        }
        test("a turn goes a click, round past north either way") {
            precondition(M.turnHeading(355, steps: 1) == 0 && M.turnHeading(0, steps: -1) == 355 && M.turnHeading(45, steps: 9) == 90)
        }
        test("the stepper goes in fives, from wherever a typed speed left it, between still and its top") {
            precondition(M.stepSpeed(0, direction: 1) == 5 && M.stepSpeed(43, direction: 1) == 45 && M.stepSpeed(43, direction: -1) == 40)
            precondition(M.stepSpeed(45, direction: 1) == 50 && M.stepSpeed(45, direction: -1) == 40)
            precondition(M.stepSpeed(0, direction: -1) == 0 && M.stepSpeed(M.maxSpeedKmh, direction: 1) == M.maxSpeedKmh)
            precondition(M.clampSpeed(-3) == 0 && M.clampSpeed(999) == M.maxSpeedKmh && M.clampSpeed(37.6) == 38 && M.clampSpeed(.nan) == 0)
        }
        test("the setting keeps a manual motion as heading and km/h, and reads it back") {
            let motion = ManualMotion(headingDeg: 240, speedKmh: 55)
            precondition(M.format(motion) == "240,55" && M.parse("240,55") == motion)
            for value: Any? in ["", "north", "45", "45,", ",30", "a,b", "1,2,3", nil, 7, true] {
                precondition(M.parse(value) == M.defaultMotion, String(describing: value))
            }
            precondition(M.parse("400,-3") == ManualMotion(headingDeg: 40, speedKmh: 0))
            precondition(M.parse(" 92 , 999 ") == ManualMotion(headingDeg: 90, speedKmh: M.maxSpeedKmh))
        }
        test("a manual motion is taken out in m/s; before one is set, nothing is") {
            precondition(M.motion(of: M.defaultMotion).speedMs == 0)
            let motion = M.motion(of: ManualMotion(headingDeg: 90, speedKmh: 36))
            precondition(motion.speedMs == 10 && motion.headingDeg == 90)
            precondition(abs(SweepGeometryRules.stormRelative(10, azimuthDeg: 90, motion: motion)) < 1e-9)
            precondition(abs(SweepGeometryRules.stormRelative(10, azimuthDeg: 270, motion: motion) - 20) < 1e-9)
        }
        test("SRV takes the selected storm's motion, unless the reader asked for their own") {
            let storm = StormMotion(speedMs: 12.5, headingDeg: 60)
            let manual = ManualMotion(headingDeg: 200, speedKmh: 18)
            precondition(M.resolve(storm: storm, manual: manual, prefersManual: false) == SrvMotion(source: .storm, motion: storm))
            let own = SrvMotion(source: .manual, motion: StormMotion(speedMs: 5, headingDeg: 200))
            precondition(M.resolve(storm: storm, manual: manual, prefersManual: true) == own)
            precondition(M.resolve(storm: nil, manual: manual, prefersManual: false) == own)
        }
        test("turning the dial while it shows a storm's motion starts from the storm's") {
            let manual = ManualMotion(headingDeg: 200, speedKmh: 18)
            let fromStorm = M.resolve(storm: StormMotion(speedMs: 15.1, headingDeg: 62.3), manual: manual, prefersManual: false)
            precondition(M.editBase(fromStorm, manual: manual) == ManualMotion(headingDeg: 60, speedKmh: 54))
            precondition(M.editBase(M.resolve(storm: nil, manual: manual, prefersManual: false), manual: manual) == manual)
        }
        test("a heading is worded as the nearest of sixteen points") {
            precondition([0.0, 11, 12, 45, 60, 180, 350, -90].map(M.compassPoint) == ["N", "N", "NNE", "NE", "ENE", "S", "N", "W"])
        }
    }

    static func iso(_ minute: Int) -> String {
        String(format: "2026-10-09T18:%02d:00.000Z", minute)
    }

    static func at(_ minute: Int) -> ListedScan {
        ListedScan(scannedAt: minute < 0 ? "2026-10-09T17:59:00.000Z" : iso(minute), path: "p\(minute)")
    }

    static func step(_ minute: Int) -> Double {
        SiteSweepRules.seconds(iso(0))! + Double(minute) * 60
    }

    static func siteSweeps() {
        let scans = [at(0), at(5), at(10), at(15)]
        test("a step shows the newest sweep scanned by then") {
            precondition(SiteSweepRules.sweepAt(scans, step: step(12), live: false)?.path == "p10")
            precondition(SiteSweepRules.sweepAt(scans, step: step(10), live: false)?.path == "p10")
        }
        test("a step with nothing recent enough shows no sweep rather than old weather") {
            precondition(SiteSweepRules.sweepAt(scans, step: step(15) + SiteSweepRules.maxAgeS + 1, live: false) == nil)
            precondition(SiteSweepRules.sweepAt(scans, step: step(-1), live: false) == nil)
        }
        test("an open radar plays the observed steps it has a sweep for, and none after now") {
            let s = { (minute: Int) in Int(step(minute)) }
            let scans = [at(0), at(5), at(30)]
            let steps = [-5, 0, 5, 10, 15, 20, 25, 30, 35, 40].map(s)
            // 20 and 25: the sweep at 5 is more than two cycles old. 35 and 40: forecast.
            precondition(SiteSweepRules.stepsWithSweep(scans, steps: steps, latest: s(30)) == [0, 5, 10, 15, 30].map(s))
            // The live step shows the newest sweep, filed after it.
            precondition(SiteSweepRules.stepsWithSweep([at(0), at(7)], steps: [0, 5].map(s), latest: s(5)) == [0, 5].map(s))
        }
        test("the live step shows the newest sweep, whatever its stamp") {
            precondition(SiteSweepRules.sweepAt(scans, step: step(10), live: true)?.path == "p15")
        }
        test("a tilt is kept across a change of quantity, else the lowest is taken") {
            let tilts = [0.5, 1.5, 2.5].map { ListedTilt(elevationDeg: $0, scans: []) }
            precondition(SiteSweepRules.tiltNear(tilts, 1.49)?.elevationDeg == 1.5)
            precondition(SiteSweepRules.tiltNear(tilts, 8.0)?.elevationDeg == 0.5)
            precondition(SiteSweepRules.tiltNear([], 0.5) == nil)
        }
        test("the sweeps fetched ahead are the next scanned, wrapping round") {
            precondition(SiteSweepRules.ahead(of: scans, shown: scans[1]).map(\.path) == ["p10", "p15", "p0"])
            precondition(SiteSweepRules.ahead(of: scans, shown: nil, count: 2).map(\.path) == ["p0", "p5"])
        }
        let t: (String, [String: Any]) -> String = { key, values in
            values.isEmpty ? key : "\(key)(\(values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")))"
        }
        test("a reading says the value and where the bin is") {
            let parts = SiteSweepRules.describe(.value(-12.5), .velocity, azimuthDeg: 231.4, groundM: 84_250, heightM: 1_920, t: t)
            precondition(parts.value == "site.read.toward(value=12.5)", parts.value)
            precondition(parts.where == "site.read.where(azimuth=231,height=1.9,range=84.3)", parts.where)
            precondition(SiteSweepRules.describe(.value(31), .reflectivity, azimuthDeg: 0, groundM: 0, heightM: 0, t: t).value
                == "site.read.dbz(value=31.0)")
            precondition(SiteSweepRules.describe(.unresolved, .srv, azimuthDeg: 0, groundM: 0, heightM: 0, t: t).value == "site.read.unresolved")
        }
        test("the velocity palette is green toward, red away, grey when still, and marks the reserved bytes") {
            let table = VelocityPalette.table
            precondition(table.count == 256)
            precondition(table[0] == (0, 0, 0, 0))
            precondition(table[1] == VelocityPalette.noEcho)
            precondition(table[255] == VelocityPalette.unresolved)
            precondition(table[128] == VelocityPalette.calm)
            let toward = table[108], away = table[148]
            precondition(toward.g > toward.r, "toward is green")
            precondition(away.r > away.g, "away is red")
        }
        test("a tilt's label is its elevation and its beam 100 km out") {
            precondition(SiteSweepRules.tiltLabel(0.5, 1.234) == "0.5° · 1.2 km")
        }
        test("a radar open round-trips, reflectivity left unsaid") {
            let srv = SiteMode(site: "frave", quantity: .srv, elevation: 0.39)
            precondition(SiteSweepRules.toLink(srv) == ["radar": "frave", "sweep": "srv", "tilt": "0.39"])
            precondition(SiteSweepRules.fromLink(radar: "frave", sweep: "srv", tilt: "0.39") == srv)
            precondition(SiteSweepRules.toLink(SiteMode(site: "deoft", quantity: .reflectivity, elevation: 0.5)) == ["radar": "deoft", "tilt": "0.5"])
            precondition(SiteSweepRules.toLink(SiteMode(site: "deoft", quantity: .velocity, elevation: 12)) == ["radar": "deoft", "sweep": "velocity", "tilt": "12"])
            precondition(SiteSweepRules.fromLink(radar: "DEOFT", sweep: nil, tilt: nil) == SiteMode(site: "deoft", quantity: .reflectivity, elevation: 0))
        }
        test("a radar link that does not parse is dropped, and an unknown sweep is reflectivity") {
            precondition(SiteSweepRules.fromLink(radar: "../tiles", sweep: nil, tilt: nil) == nil)
            precondition(SiteSweepRules.fromLink(radar: "", sweep: nil, tilt: nil) == nil)
            precondition(SiteSweepRules.fromLink(radar: "deoft", sweep: "hail", tilt: "-3") == SiteMode(site: "deoft", quantity: .reflectivity, elevation: 0))
            // A tilt or sweep alone means nothing.
            precondition(SiteSweepRules.fromLink(radar: nil, sweep: "velocity", tilt: "1.5") == nil)
        }
        test("the listing decodes as /sweeps answers it") {
            let json = """
            {"sites":[{"site":"deoft","network":"de","lat":49.98,"lon":8.71,"newest":"2026-10-11T01:35:00Z",
              "reflectivity":[{"elevation_deg":0.5,"scans":[{"scanned_at":"2026-10-11T01:35:00Z","started_at":"2026-10-11T01:37:30Z",
              "path":"meteoradar/sweeps/de/deoft/20261011T013500/00.5/DBZH.mcsw","bytes":60000,"nyquist_m_s":null,"dealiased":false}]}]}]}
            """
            let listing = try! JSONDecoder().decode(SweepListing.self, from: Data(json.utf8))
            let site = listing.sites![0]
            precondition(site.site == "deoft" && site.velocity == nil)
            precondition(SiteSweepRules.listed(site, .velocity).isEmpty && SiteSweepRules.listed(site, .reflectivity).count == 1)
            precondition(site.reflectivity![0].scans[0].scannedS == SiteSweepRules.seconds("2026-10-11T01:35:00+00:00"))
        }
    }

    /// An object as the backend writes it, before URLSession has gunzipped it.
    static func encode(_ header: [String: Any], _ bins: [UInt8]) -> Data {
        let text = try! JSONSerialization.data(withJSONObject: header)
        var out = Data("MCSW".utf8)
        for word in [UInt32(1), UInt32(text.count)] { withUnsafeBytes(of: word.littleEndian) { out.append(contentsOf: $0) } }
        out.append(text)
        out.append(contentsOf: bins)
        return out
    }

    static let header: [String: Any] = [
        "site": "deasb", "network": "de", "lat": 53.56, "lon": 6.75, "height_m": 36.2, "elevation_deg": 0.5, "range_start_m": 0,
        "range_step_m": 250, "nrays": 2, "nbins": 3, "azimuth0_deg": 0.5, "azimuth_step_deg": 1, "encoding": "vrad-u8",
        "scanned_at": "2026-10-09T18:20:00+00:00",
    ]

    static func sweep() {
        test("a sweep reads back its header and its bins, rays outermost") {
            let sweep = try! Sweep.decode(encode(header, [1, 2, 3, 4, 5, 6]))
            precondition(sweep.header.site == "deasb" && sweep.header.nrays == 2)
            precondition(sweep.bins == [1, 2, 3, 4, 5, 6])
        }
        test("anything that is not a sweep is refused") {
            precondition((try? Sweep.decode(Data(count: 4))) == nil)
            // A blank tile, as a missing object might be answered.
            precondition((try? Sweep.decode(Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0, 0, 0, 0, 0, 0]))) == nil)
        }
        test("a sweep whose bins do not fill its header is refused") {
            do {
                _ = try Sweep.decode(encode(header, [0, 0, 0, 0, 0]))
                preconditionFailure("accepted")
            } catch {
                precondition(error as? Sweep.Failure == .size(5, wanted: 6))
            }
        }
        test("reflectivity bytes read as the tiles do") {
            precondition(Sweep.read(Sweep.rvp6, 0) == .noEcho)
            precondition(Sweep.read(Sweep.rvp6, 255) == .unmeasured)
            precondition(Sweep.read(Sweep.rvp6, 105) == .value(20))
        }
        test("velocity bytes are half metres per second about 128, with three reserved") {
            precondition(Sweep.read(Sweep.vrad, 0) == .unmeasured)
            precondition(Sweep.read(Sweep.vrad, 1) == .noEcho)
            precondition(Sweep.read(Sweep.vrad, 255) == .unresolved)
            precondition(Sweep.read(Sweep.vrad, 148) == .value(10))
            precondition(Sweep.read(Sweep.vrad, 108) == .value(-10))
        }
        test("a velocity is encoded within the bytes that hold one") {
            precondition(Sweep.velocityByte(10) == 148)
            precondition(Sweep.velocityByte(-99) == 2)
            precondition(Sweep.velocityByte(99) == 254)
            // Halves round up, as JavaScript's Math.round does.
            precondition(Sweep.velocityByte(-0.25) == 128)
        }
    }

    /// Emden's 0.5 degree tilt as the backend publishes it: 360 rays from 0.518 degrees, 720 bins of 250 m.
    static let emden = SweepGeometry(lat: 53.564129, lon: 6.748317, heightM: 36.2, elevationDeg: 0.5, rangeStartM: 0, rangeStepM: 250,
                                     nrays: 360, nbins: 720, azimuth0Deg: 0.518, azimuthStepDeg: 1)

    static func geometry() {
        typealias G = SweepGeometryRules
        test("a point due north of a site is at bearing 0, east at 90") {
            let north = G.fromSite(lon: 10, lat: 50, lon: 10, lat: 51)
            precondition(abs(north.azimuthDeg) < 1e-9 || abs(north.azimuthDeg - 360) < 1e-9)
            precondition(abs(north.groundM - 111_195) < 50)
            precondition(abs(G.fromSite(lon: 10, lat: 50, lon: 10.5, lat: 50).azimuthDeg - 90) < 0.3)
        }
        test("the beam's height agrees with the one the volumes panel draws") {
            let (slantM, heightM) = G.alongBeam(100_000, 0.5)
            let panel = RadarSites.beamHeightKm(range: slantM / 1000, elevationDeg: 0.5, siteHeightM: 0) * 1000
            precondition(abs(heightM - panel) < 1, "\(heightM) against \(panel)")
        }
        test("the ground distance at a beam height is the inverse of the beam height") {
            for elevation in [0.5, 1.5, 5.5] {
                precondition(abs(G.alongBeam(G.groundAtHeight(2000, elevation), elevation).heightM - 2000) < 0.01)
            }
        }
        test("a point lands in the bin and ray that cover it") {
            let lon = emden.lon + 50_000 / (111_195 * cos(emden.lat * .pi / 180))
            let bin = G.binAt(emden, lon: lon, lat: emden.lat)!
            precondition(bin.ray == 89 || bin.ray == 90, "ray \(bin.ray)")
            precondition(bin.bin == Int((bin.slantM / 250).rounded(.down)))
            precondition(abs(bin.groundM - 50_000) < 500)
            precondition(abs(bin.heightM - (G.alongBeam(bin.groundM, 0.5).heightM + 36.2)) < 1e-6)
        }
        test("a point past the last bin is in no bin") {
            precondition(G.binAt(emden, lon: emden.lon, lat: emden.lat + 2) == nil)
            precondition(abs(G.reachM(emden) - 180_000) < 200)
        }
        test("rays wrap round north") {
            let justWest = G.binAt(emden, lon: emden.lon - 0.001, lat: emden.lat + 0.3)!
            precondition(justWest.ray == 359)
            precondition(abs(justWest.azimuthDeg - 359.518) < 1e-9)
        }
        test("beam height rings are whole kilometres, nearest first, inside the sweep") {
            let rings = G.beamHeightRings(emden)
            precondition(rings.map(\.heightM) == [1000, 2000, 3000])
            precondition(zip(rings, rings.dropFirst()).allSatisfy { $0.groundM < $1.groundM })
            precondition(rings.allSatisfy { $0.groundM <= G.reachM(emden) })
        }
        test("storm-relative velocity takes the storm's motion along the ray out") {
            let motion = StormMotion(speedMs: 10, headingDeg: 90)
            precondition(abs(G.stormRelative(12, azimuthDeg: 90, motion: motion) - 2) < 1e-9)
            precondition(abs(G.stormRelative(12, azimuthDeg: 0, motion: motion) - 12) < 1e-9)
            precondition(abs(G.stormRelative(-12, azimuthDeg: 270, motion: motion) - -2) < 1e-9)
        }
        test("a ring's points are its ground distance from the site") {
            let at = G.destination(lon: emden.lon, lat: emden.lat, groundM: 100_000, bearingDeg: 63)
            let back = G.fromSite(lon: emden.lon, lat: emden.lat, lon: at.lon, lat: at.lat)
            precondition(abs(back.groundM - 100_000) < 1 && abs(back.azimuthDeg - 63) < 1e-6)
        }
    }

    static func fixtures(_ directory: String?) {
        guard let directory else { return }
        func load(_ name: String) -> Sweep {
            try! Sweep.decode(Data(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent(name)))
        }
        test("Borkum's real sweeps decode, reflectivity and dealiased velocity") {
            let dbzh = load("DBZH.mcsw")
            let vradh = load("VRADH.mcsw")
            precondition(dbzh.header.site == "deasb" && dbzh.header.nrays == 360 && dbzh.header.nbins == 720)
            precondition(!dbzh.header.isVelocity && vradh.header.isVelocity && vradh.header.dealiased == true)
            precondition(dbzh.header.startedAt.flatMap(SiteSweepRules.seconds) != nil)
            // Somewhere in it there is an echo, and a reading where the bin is.
            precondition(dbzh.bins.contains { $0 > 0 && $0 < 255 })
            let bin = SweepGeometryRules.binAt(dbzh.header.geometry, lon: 6.95, lat: 53.72)!
            if case .value = Sweep.read(dbzh.header.encoding, dbzh.bins[bin.ray * dbzh.header.nbins + bin.bin]) {} else {
                // No echo is a reading too; what matters is the bin is inside.
                precondition(bin.groundM < SweepGeometryRules.reachM(dbzh.header.geometry))
            }
            precondition(abs(SweepGeometryRules.reachM(dbzh.header.geometry) - 180_000) < 200)
        }
    }
}
