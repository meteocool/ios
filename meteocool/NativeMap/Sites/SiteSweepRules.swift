//
//  SiteSweepRules.swift
//  meteocool
//
//  Site mode's decisions and formats (core's `lib/siteSweeps.ts`,
//  `lib/sweep.ts`, `lib/sweepGeometry.ts` and `velocityTable`): which sweep
//  a step shows, which tilts to offer, one radar's sweep unpacked, and where
//  its beam is.
//
//  No app dependencies here: `scripts/check.sh` compiles this file alone.
//

import Foundation

// MARK: - The listing

/// A sweep as `/sweeps` lists it: when it was scanned, and where its object is.
struct ListedScan: Decodable, Equatable, Sendable {
    let scannedAt: String
    var startedAt: String?
    let path: String
    var nyquistMs: Double?
    var dealiased: Bool?

    enum CodingKeys: String, CodingKey {
        case scannedAt = "scanned_at", startedAt = "started_at", path, nyquistMs = "nyquist_m_s", dealiased
    }

    /// `scannedAt` in unix seconds; -infinity when it does not parse.
    var scannedS: Double { SiteSweepRules.seconds(scannedAt) ?? -.infinity }
}

/// One tilt as `/sweeps` lists it.
struct ListedTilt: Decodable, Equatable, Sendable {
    let elevationDeg: Double
    let scans: [ListedScan]

    enum CodingKeys: String, CodingKey {
        case elevationDeg = "elevation_deg", scans
    }
}

/// One site as `/sweeps` lists it.
struct ListedSite: Decodable, Equatable, Sendable {
    let site: String
    let network: String
    let lat: Double
    let lon: Double
    var newest: String?
    var reflectivity: [ListedTilt]?
    var velocity: [ListedTilt]?
}

/// `/sweeps`' answer.
struct SweepListing: Decodable, Sendable {
    var sites: [ListedSite]?
}

/// What to draw of a radar: reflectivity, radial velocity, or velocity
/// relative to the selected storm.
enum SiteQuantity: String, CaseIterable, Sendable {
    case reflectivity, velocity, srv
}

/// What the reader has open: one site, what to draw of it, and at which tilt.
struct SiteMode: Equatable, Sendable {
    var site: String
    var quantity: SiteQuantity
    var elevation: Double
}

/// One tilt as the tray offers it.
struct OfferedTilt: Equatable, Sendable {
    let elevation: Double
    /// The beam's height 100 km out, above sea level: what the tilt sees.
    let beamKmAt100: Double
}

/// What a reading says, as the long press shows it: the value, then where the bin is.
struct ReadingParts: Equatable, Sendable {
    let value: String
    let `where`: String
}

enum SiteSweepRules {
    /// A sweep this much older than the step it would be shown on is not shown: two cycles.
    static let maxAgeS: Double = 600
    /// Two tilts this close are one: Meteo-France's lowest is 0.39 on one cycle and 0.4 on the next.
    static let sameTiltDeg = 0.2

    /// The listing a quantity is drawn from: SRV is the velocity sweep, less the storm's motion.
    static func listed(_ site: ListedSite, _ quantity: SiteQuantity) -> [ListedTilt] {
        (quantity == .reflectivity ? site.reflectivity : site.velocity) ?? []
    }

    /// The tilt nearest an elevation, within `sameTiltDeg`; else the lowest,
    /// so a change of quantity keeps its place.
    static func tiltNear(_ tilts: [ListedTilt], _ elevation: Double) -> ListedTilt? {
        guard var nearest = tilts.first else { return nil }
        for tilt in tilts where abs(tilt.elevationDeg - elevation) < abs(nearest.elevationDeg - elevation) { nearest = tilt }
        if abs(nearest.elevationDeg - elevation) <= sameTiltDeg { return nearest }
        return tilts.min { $0.elevationDeg < $1.elevationDeg }
    }

    /// The sweep a timeline step shows: the newest scanned at or before it
    /// and not older than `maxAgeS`, or nil. On the live step the newest
    /// there is wins whatever its stamp: a site files a cycle whole, minutes
    /// after the composite's step.
    static func sweepAt(_ scans: [ListedScan], step: Double, live: Bool) -> ListedScan? {
        var best: ListedScan?
        var bestAt = -Double.infinity
        for scan in scans {
            let at = scan.scannedS
            if !live && at > step { continue }
            if at > bestAt {
                best = scan
                bestAt = at
            }
        }
        guard let best else { return nil }
        if !live && step - bestAt > maxAgeS { return nil }
        return best
    }

    /// The timeline steps an open radar has a sweep for, oldest first: what
    /// playback steps through while it is open. Observed steps only: on a
    /// forecast step a sweep would be the newest scan under a later label.
    /// `latest` is the live step, judged as `sweepAt` judges it.
    static func stepsWithSweep(_ scans: [ListedScan], steps: [Int], latest: Int) -> [Int] {
        steps.filter { $0 <= latest && sweepAt(scans, step: Double($0), live: $0 == latest) != nil }
    }

    /// The sweeps to fetch ahead of the one shown: the next `count` scanned
    /// after it, oldest first; from the oldest again past the newest.
    static func ahead(of scans: [ListedScan], shown: ListedScan?, count: Int = 3) -> [ListedScan] {
        let ordered = scans.sorted { $0.scannedS < $1.scannedS }
        let from = shown.flatMap { ordered.firstIndex(of: $0) } ?? -1
        var ahead: [ListedScan] = []
        var i = 1
        while i <= ordered.count && ahead.count < count {
            let scan = ordered[((from + i) % ordered.count + ordered.count) % ordered.count]
            if scan != shown && !ahead.contains(scan) { ahead.append(scan) }
            i += 1
        }
        return ahead
    }

    /// A tilt's label: its elevation, and how high its beam is 100 km out,
    /// which is what a reader choosing a tilt actually wants to know.
    static func tiltLabel(_ elevationDeg: Double, _ beamKmAt100: Double) -> String {
        "\(fixed1(elevationDeg))° · \(fixed1(beamKmAt100)) km"
    }

    /// A radar open in site mode, as a link names it (core's `radar=`,
    /// `sweep=`, `tilt=`): its code, what is drawn of it (reflectivity unless
    /// said) and the tilt (the lowest unless said, as elevation 0 picks it).
    /// nil where the code is not a plain word, or absent.
    static func fromLink(radar: String?, sweep: String?, tilt: String?) -> SiteMode? {
        guard let site = radar?.lowercased(), site.range(of: "^[a-z0-9]{3,12}$", options: .regularExpression) != nil else { return nil }
        let quantity = sweep.flatMap(SiteQuantity.init(rawValue:)).flatMap { $0 == .reflectivity ? nil : $0 } ?? .reflectivity
        let elevation = tilt.flatMap(Double.init).flatMap { $0.isFinite && $0 >= 0 && $0 <= 90 ? $0 : nil } ?? 0
        return SiteMode(site: site, quantity: quantity, elevation: elevation)
    }

    /// The link's parameters for an open radar: reflectivity left unsaid, the
    /// tilt to two decimals (Meteo-France's 0.39) without trailing zeros.
    static func toLink(_ mode: SiteMode) -> [String: String] {
        var out = ["radar": mode.site]
        if mode.quantity != .reflectivity { out["sweep"] = mode.quantity.rawValue }
        let tilt = (mode.elevation * 100).rounded() / 100
        out["tilt"] = tilt == tilt.rounded() ? String(Int(tilt)) : String(tilt)
        return out
    }

    /// One decimal, as JavaScript's `toFixed(1)` writes it: a tie rounds away from zero.
    static func fixed1(_ value: Double) -> String {
        String(format: "%.1f", (value * 10).rounded(.toNearestOrAwayFromZero) / 10)
    }

    /// A bin's reading in words; `t` is the app's translate. SI units, as
    /// the radar measures them.
    static func describe(_ reading: BinReading, _ quantity: SiteQuantity, azimuthDeg: Double, groundM: Double, heightM: Double,
                         t: (String, [String: Any]) -> String) -> ReadingParts {
        let place = t("site.read.where", [
            "azimuth": Int((azimuthDeg + 0.5).rounded(.down)),
            "range": fixed1(groundM / 1000),
            "height": fixed1(heightM / 1000),
        ])
        switch reading {
        case .unmeasured: return ReadingParts(value: t("site.read.unmeasured", [:]), where: place)
        case .noEcho: return ReadingParts(value: t("site.read.no_echo", [:]), where: place)
        case .unresolved: return ReadingParts(value: t("site.read.unresolved", [:]), where: place)
        case .value(let value):
            if quantity == .reflectivity {
                return ReadingParts(value: t("site.read.dbz", ["value": fixed1(value)]), where: place)
            }
            let key = value > 0 ? "site.read.away" : value < 0 ? "site.read.toward" : "site.read.calm"
            return ReadingParts(value: t(key, ["value": fixed1(abs(value))]), where: place)
        }
    }

    /// An ISO date as the listing and the headers write it (`Z` or `+00:00`,
    /// with or without fractions), in unix seconds.
    static func seconds(_ iso: String) -> Double? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: iso) { return date.timeIntervalSince1970 }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: iso)?.timeIntervalSince1970
    }
}

// MARK: - One sweep

/// What the header says of one sweep.
struct SweepHeader: Decodable, Equatable, Sendable {
    let site: String
    let network: String
    let lat: Double
    let lon: Double
    /// The antenna above sea level.
    let heightM: Double
    let elevationDeg: Double
    /// Where the first bin starts, and how long each is, along the beam.
    let rangeStartM: Double
    let rangeStepM: Double
    let nrays: Int
    let nbins: Int
    /// The first ray's centre, clockwise from north, and the step between rays.
    let azimuth0Deg: Double
    let azimuthStepDeg: Double
    let encoding: String
    /// The fastest radial wind the tilt measures before it folds.
    var nyquistMs: Double?
    /// Whether the server unfolded it: a fold looks exactly like a couplet.
    var dealiased: Bool?
    var dealiaser: String?
    let scannedAt: String
    var startedAt: String?

    enum CodingKeys: String, CodingKey {
        case site, network, lat, lon, heightM = "height_m", elevationDeg = "elevation_deg", rangeStartM = "range_start_m",
             rangeStepM = "range_step_m", nrays, nbins, azimuth0Deg = "azimuth0_deg", azimuthStepDeg = "azimuth_step_deg",
             encoding, nyquistMs = "nyquist_m_s", dealiased, dealiaser, scannedAt = "scanned_at", startedAt = "started_at"
    }

    var isVelocity: Bool { encoding == Sweep.vrad }
    var geometry: SweepGeometry {
        SweepGeometry(lat: lat, lon: lon, heightM: heightM, elevationDeg: elevationDeg, rangeStartM: rangeStartM,
                      rangeStepM: rangeStepM, nrays: nrays, nbins: nbins, azimuth0Deg: azimuth0Deg, azimuthStepDeg: azimuthStepDeg)
    }
}

/// What one bin holds.
enum BinReading: Equatable, Sendable {
    case unmeasured, noEcho, unresolved
    case value(Double)
}

/// One radar's sweep: one tilt, one quantity, in the radar's own polar bins.
///
/// `MCSW`, a version, a JSON header, then `nrays × nbins` bytes, rays
/// outermost, served gzipped with `Content-Encoding: gzip`, which URLSession
/// unwraps. Reflectivity is `rvp6-u8`, as the tiles: byte / 2 − 32.5 dBZ, 0
/// no echo, 255 not measured. Velocity is `vrad-u8`: 0 not measured, 1 no
/// echo, 2…254 are (byte − 128) × 0.5 m/s, positive away from the radar,
/// 255 where the dealiaser gave up.
struct Sweep: Sendable {
    static let rvp6 = "rvp6-u8"
    static let vrad = "vrad-u8"
    static let vradZero = 128
    static let vradStep = 0.5

    let header: SweepHeader
    /// `nrays × nbins` bytes, rays outermost.
    let bins: [UInt8]

    enum Failure: Error, Equatable {
        case notASweep, version(UInt32), size(Int, wanted: Int)
    }

    /// Unpacks one object; throws on anything that is not a sweep.
    static func decode(_ data: Data) throws -> Sweep {
        let bytes = [UInt8](data)
        guard bytes.count >= 12 else { throw Failure.notASweep }
        func word(_ at: Int) -> UInt32 {
            UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
        }
        guard word(0) == 0x5753_434D else { throw Failure.notASweep }
        guard word(4) == 1 else { throw Failure.version(word(4)) }
        let length = Int(word(8))
        guard 12 + length <= bytes.count,
              let header = try? JSONDecoder().decode(SweepHeader.self, from: Data(bytes[12 ..< 12 + length])) else {
            throw Failure.notASweep
        }
        let bins = Array(bytes[(12 + length)...])
        let wanted = header.nrays * header.nbins
        guard bins.count == wanted else { throw Failure.size(bins.count, wanted: wanted) }
        return Sweep(header: header, bins: bins)
    }

    /// A bin's byte as what it means, in dBZ or m/s.
    static func read(_ encoding: String, _ byte: UInt8) -> BinReading {
        if encoding == rvp6 {
            if byte == 255 { return .unmeasured }
            if byte == 0 { return .noEcho }
            return .value(Double(byte) / 2 - 32.5)
        }
        switch byte {
        case 0: return .unmeasured
        case 1: return .noEcho
        case 255: return .unresolved
        default: return .value(Double(Int(byte) - vradZero) * vradStep)
        }
    }

    /// A velocity in m/s as `vrad-u8`'s byte, clipped to the bytes that hold one.
    static func velocityByte(_ metresPerSecond: Double) -> Int {
        // Rounded as JavaScript's `Math.round`, half up, as core encodes it.
        min(254, max(2, Int((metresPerSecond / vradStep + 0.5).rounded(.down)) + vradZero))
    }
}

// MARK: - Where the beam is

/// The parts of a sweep's header its geometry needs.
struct SweepGeometry: Equatable, Sendable {
    let lat: Double
    let lon: Double
    let heightM: Double
    let elevationDeg: Double
    let rangeStartM: Double
    let rangeStepM: Double
    let nrays: Int
    let nbins: Int
    let azimuth0Deg: Double
    let azimuthStepDeg: Double
}

/// One bin of a sweep, as a point on the map lands on it.
struct BinAt: Equatable, Sendable {
    let ray: Int
    let bin: Int
    /// The ray's own centre, and the point's distances.
    let azimuthDeg: Double
    let groundM: Double
    let slantM: Double
    /// The beam centre above sea level there.
    let heightM: Double
}

/// A storm's motion: how fast, and which way it is going, clockwise from north.
struct StormMotion: Equatable, Sendable {
    let speedMs: Double
    let headingDeg: Double
}

/// Ground distances are great-circle on a sphere of the earth's mean radius;
/// the beam is bent by the standard atmosphere, which is a straight beam over
/// an earth four thirds the size. Over a ground distance `s` from a radar
/// tilted `θ` up, on that earth of radius R':
///
///     slant range  r = R' sin(s / R') / cos(θ + s / R')
///     beam height  h = R' cos(θ) / cos(θ + s / R') − R'
///
/// `SiteSweepOverlay` runs the same projection per pixel; change one, change both.
enum SweepGeometryRules {
    static let earthRadiusM = 6_371_000.0
    static let effectiveRadiusM = 4.0 / 3.0 * earthRadiusM
    private static let rad = Double.pi / 180

    /// How far over the ground, and on which bearing clockwise from north, a point is from a site.
    static func fromSite(lon siteLon: Double, lat siteLat: Double, lon: Double, lat: Double) -> (groundM: Double, azimuthDeg: Double) {
        let phi1 = siteLat * rad
        let phi2 = lat * rad
        let dPhi = phi2 - phi1
        let dLambda = (lon - siteLon) * rad
        let a = pow(sin(dPhi / 2), 2) + cos(phi1) * cos(phi2) * pow(sin(dLambda / 2), 2)
        let groundM = 2 * earthRadiusM * asin(min(1, a.squareRoot()))
        let y = sin(dLambda) * cos(phi2)
        let x = cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(dLambda)
        let azimuthDeg = (atan2(y, x) / rad + 360).truncatingRemainder(dividingBy: 360)
        return (groundM, azimuthDeg)
    }

    /// Along the beam, and above the antenna, at a ground distance from the site; metres.
    static func alongBeam(_ groundM: Double, _ elevationDeg: Double) -> (slantM: Double, heightM: Double) {
        let k = effectiveRadiusM
        let theta = elevationDeg * rad
        let s = groundM / k
        let c = cos(theta + s)
        return (k * sin(s) / c, k * cos(theta) / c - k)
    }

    /// The ground distance at which a tilt's beam centre is `heightM` above its antenna.
    static func groundAtHeight(_ heightM: Double, _ elevationDeg: Double) -> Double {
        let k = effectiveRadiusM
        let theta = elevationDeg * rad
        let ratio = k * cos(theta) / (k + heightM)
        return k * (acos(min(1, max(-1, ratio))) - theta)
    }

    /// Which bin a point falls in: the nearest ray, and the bin it is
    /// inside; nil past the last bin or before the first.
    static func binAt(_ sweep: SweepGeometry, lon: Double, lat: Double) -> BinAt? {
        let (groundM, azimuthDeg) = fromSite(lon: sweep.lon, lat: sweep.lat, lon: lon, lat: lat)
        let (slantM, heightM) = alongBeam(groundM, sweep.elevationDeg)
        guard slantM.isFinite, slantM >= 0 else { return nil }
        let bin = Int(((slantM - sweep.rangeStartM) / sweep.rangeStepM).rounded(.down))
        guard bin >= 0, bin < sweep.nbins else { return nil }
        let steps = Int(((azimuthDeg - sweep.azimuth0Deg) / sweep.azimuthStepDeg + 0.5).rounded(.down))
        let ray = ((steps % sweep.nrays) + sweep.nrays) % sweep.nrays
        return BinAt(ray: ray, bin: bin,
                     azimuthDeg: (sweep.azimuth0Deg + Double(ray) * sweep.azimuthStepDeg).truncatingRemainder(dividingBy: 360),
                     groundM: groundM, slantM: slantM, heightM: heightM + sweep.heightM)
    }

    /// How far a sweep's last bin reaches over the ground.
    static func reachM(_ sweep: SweepGeometry) -> Double {
        let slant = sweep.rangeStartM + Double(sweep.nbins) * sweep.rangeStepM
        var low = 0.0
        var high = slant
        for _ in 0 ..< 40 {
            let mid = (low + high) / 2
            if alongBeam(mid, sweep.elevationDeg).slantM < slant { low = mid } else { high = mid }
        }
        return low
    }

    /// The rings of beam height a tilt is drawn with: every whole kilometre
    /// above sea level the beam centre reaches inside the sweep.
    static func beamHeightRings(_ sweep: SweepGeometry, stepM: Double = 1000) -> [(heightM: Double, groundM: Double)] {
        let reach = reachM(sweep)
        var rings: [(heightM: Double, groundM: Double)] = []
        var height = max(stepM, (sweep.heightM / stepM).rounded(.up) * stepM)
        while true {
            let groundM = groundAtHeight(height - sweep.heightM, sweep.elevationDeg)
            if !(groundM > 0) || groundM > reach { break }
            rings.append((height, groundM))
            height += stepM
        }
        return rings
    }

    /// Storm-relative velocity: the radial wind less the storm's own motion along the ray.
    static func stormRelative(_ radialMs: Double, azimuthDeg: Double, motion: StormMotion) -> Double {
        radialMs - motion.speedMs * cos((azimuthDeg - motion.headingDeg) * rad)
    }

    /// A point `groundM` from a site on a bearing, on the sphere: for the rings.
    static func destination(lon: Double, lat: Double, groundM: Double, bearingDeg: Double) -> (lon: Double, lat: Double) {
        let phi1 = lat * rad
        let lambda1 = lon * rad
        let delta = groundM / earthRadiusM
        let theta = bearingDeg * rad
        let phi2 = asin(sin(phi1) * cos(delta) + cos(phi1) * sin(delta) * cos(theta))
        let lambda2 = lambda1 + atan2(sin(theta) * sin(delta) * cos(phi1), cos(delta) - sin(phi1) * sin(phi2))
        return (lambda2 / rad, phi2 / rad)
    }
}

// MARK: - The velocity palette

/// Radial velocity's colours (core's `velocityTable`): toward the radar
/// green, away red, brighter the faster, grey when still, purple where the
/// dealiaser gave up. RGBA, one per byte.
enum VelocityPalette {
    typealias RGBA = (r: UInt8, g: UInt8, b: UInt8, a: UInt8)

    static let calm: RGBA = (140, 140, 140, 210)
    static let noEcho: RGBA = (128, 128, 128, 36)
    static let unresolved: RGBA = (160, 40, 220, 255)

    private static let toward: [(Double, (Double, Double, Double))] = [
        (1, (70, 92, 70)), (5, (0, 110, 20)), (15, (0, 190, 40)), (25, (60, 255, 90)), (35, (190, 255, 200)), (50, (235, 255, 245)),
    ]
    private static let away: [(Double, (Double, Double, Double))] = [
        (1, (96, 70, 70)), (5, (120, 0, 10)), (15, (205, 0, 20)), (25, (255, 60, 50)), (35, (255, 190, 170)), (50, (255, 245, 230)),
    ]

    static let table: [RGBA] = (0 ..< 256).map { byte in
        switch byte {
        case 0: return (0, 0, 0, 0)
        case 1: return noEcho
        case 255: return unresolved
        default:
            let v = Double(byte - Sweep.vradZero) * Sweep.vradStep
            if abs(v) <= 1 { return calm }
            return ramp(v < 0 ? toward : away, abs(v))
        }
    }

    private static func ramp(_ stops: [(Double, (Double, Double, Double))], _ speed: Double) -> RGBA {
        func rgba(_ c: (Double, Double, Double), _ a: UInt8) -> RGBA { (UInt8(c.0), UInt8(c.1), UInt8(c.2), a) }
        if speed <= stops[0].0 { return rgba(stops[0].1, 230) }
        for i in 1 ..< stops.count where speed <= stops[i].0 {
            let (from, a) = stops[i - 1]
            let (to, b) = stops[i]
            let f = (speed - from) / (to - from)
            return rgba(((a.0 + f * (b.0 - a.0)).rounded(), (a.1 + f * (b.1 - a.1)).rounded(), (a.2 + f * (b.2 - a.2)).rounded()), 240)
        }
        return rgba(stops[stops.count - 1].1, 240)
    }
}
