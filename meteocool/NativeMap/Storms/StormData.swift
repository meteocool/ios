//
//  StormData.swift
//  meteocool
//
//  What the data service says about storms (core's `spec/data.openapi.json`,
//  `src/api/index.ts`): `/storms`, `/storms/{id}`, `/cells/tracks/{code}`,
//  `/cells/volumes`.
//

import Foundation

// No app dependencies here: `scripts/check.sh` compiles this file alone.

/// A point as GeoJSON has it, `[lon, lat]`.
struct LonLat: Equatable, Hashable, Sendable {
    var lon: Double
    var lat: Double

    init(_ lon: Double, _ lat: Double) {
        self.lon = lon
        self.lat = lat
    }
}

/// A `Point` or a `LineString` (a storm's or a track's path).
enum PathGeometry: Equatable, Sendable {
    case point(LonLat)
    case line([LonLat])

    /// The points, oldest first; one until it moves.
    var points: [LonLat] {
        switch self {
        case let .point(point): return [point]
        case let .line(points): return points
        }
    }
}

/// `{west, south, east, north}`.
struct Bounds: Decodable, Equatable, Sendable {
    var west: Double
    var south: Double
    var east: Double
    var north: Double
}

/// Where a storm is, as the data service names it: "18 km N of Freising"
/// in parts (core's `CellPlacement`).
struct CellPlacement: Equatable, Sendable {
    var place: String
    var distanceKm: Double
    var direction: String?
    var bearingDeg: Double?
    var kind = ""
}

/// One of the tracks a storm is made of.
struct StormTrackClaim: Decodable, Equatable, Sendable {
    var product: String
    var domain: String
    var track: String
}

/// `StormProperties`.
struct StormProperties: Equatable, Sendable {
    var id: String
    var bornAt: String
    var lastSeen: String
    /// `active`, `ended` or `merged`.
    var status: String
    var mergedInto: String?
    var splitFrom: String?
    var primaryTrack: String?
    var primaryProduct: String?
    var primaryDomain: String?
    var headingDeg: Double?
    var speedKmh: Double?
    var severity = 0
    var peakDbz: Double?
    var hail = false
    var meso = false
    var placement: CellPlacement?
    var bbox: Bounds?
    var path: PathGeometry
    var tracks: [StormTrackClaim] = []
}

/// `StormFeature`: a storm from `/storms`, its geometry its centroid now.
struct Storm: Equatable, Sendable {
    var id: String
    var geometry: LonLat
    var properties: StormProperties
}

/// `/storms`: most recently seen first, at most 200.
struct StormCollection: Equatable, Sendable {
    var features: [Storm]
}

/// One KONRAD3D detection (`CellStep`).
struct CellStep: Equatable, Sendable {
    var t: String
    var lon: Double
    var lat: Double
    var identifier = 0
    var severity = 0
    var severityDecimal: Double?
    var maxDbz: Double?
    var echoTopM: Double?
    var vil: Double?
    var areaKm2: Double?
    var hailFlag = 0
    var heavyRainFlag = 0
    var gustFlag = 0
    var gustKmh: Double?
    var lightningRate: Int?
    var lightningJumps: Int?
    var mesoSeverity: Int?
    var mesoRotMs: Double?
    var speedKmh: Double?
    var headingDeg: Double?
    var deviationDeg: Double?
    var split = false
    var merge = false
}

/// DWD's 1σ Kalman ellipse at one lead (`ForecastPoint`); `angleDeg` is a
/// bearing, clockwise from north.
struct ForecastPoint: Equatable, Sendable {
    var t: String
    var lon: Double
    var lat: Double
    var majorKm: Double?
    var minorKm: Double?
    var angleDeg: Double?
}

/// One threshold of a cell's structure (`CellLayer`).
struct CellLayer: Equatable, Sendable {
    var dbz: Int
    var areaKm2: Double
    var topM: Double
    var volumeKm3: Double?
}

/// A cell's radar volume (`CellVolume`).
struct CellVolume: Equatable, Sendable {
    var path: String
    var coverage: Double
    var sites: [String] = []
    var bytes: Int?
    var tier = 2
    var scannedAt: String?
    var oldestScanAt: String?
}

/// A KONRAD3D track (`TrackProperties`, core's `CellTrackProperties`).
struct TrackProperties: Equatable, Sendable {
    var code: String
    var firstSeen: String
    var lastSeen: String
    var nSteps = 0
    var active = false
    var maxSeverity = 0
    var lineageFirstDetection: String?
    var maxDbz: Double?
    var vilMax: Double?
    var echoTopMaxM: Double?
    var echoBottomM: Double?
    var hailEver = false
    var mesoEver = false
    var splitEver = false
    var mergeEver = false
    var hailMinutes = 0
    var mesoMinutes = 0
    var lightningJumpRecent = false
    var intensifying = false
    var deviationDeg: Double?
    var parentCodes: [String] = []
    var childCodes: [String] = []
    var placement: CellPlacement?
    var polygon: [LonLat]?
    var series: [CellStep] = []
    var forecast: [ForecastPoint] = []
    var structure: [CellLayer] = []
    var volume: CellVolume?
}

/// One feature of a tracker track (`TrackerFeature`).
struct TrackerFeature: Equatable, Sendable {
    var id: String
    /// `patch` or `core`.
    var kind: String
    var validAt: String
    /// A core's patch.
    var parent: String?
    var centroid: LonLat
    var peak: LonLat
    var peakDbz: Double
    var areaKm2: Double
    /// The outline's rings, `[lon, lat]`.
    var outline: [[LonLat]]
}

/// A meteocool tracker track (`TrackerTrack`).
struct TrackerTrack: Equatable, Sendable {
    var id: String
    var product: String
    var domain: String
    var kind: String
    var firstSeen: String
    var lastSeen: String
    var active: Bool
    var parentTracks: [String] = []
    var childTracks: [String] = []
    var maxPeakDbz: Double
    var bbox: Bounds?
    var path: PathGeometry
    var nFeatures: Int
    /// The last hour only.
    var features: [TrackerFeature] = []
}

/// `/storms/{id}`: the storm, its KONRAD3D tracks and its tracker tracks.
struct StormDetail: Equatable, Sendable {
    var storm: Storm
    var konrad3d: [TrackProperties] = []
    var tracks: [TrackerTrack] = []
}

/// A box of sky (`RadarVolume`, `/cells/volumes`).
struct RadarVolume: Equatable, Sendable {
    var path: String
    var coverage: Double
    var code: String
    var lon: Double
    var lat: Double
    var referenceTime: String
    var network = "de"
    var scannedAt: String?
    var oldestScanAt: String?
    var sites: [String] = []
    var bytes: Int?
    /// 1 is drawn but not openable, 2 openable.
    var tier = 2
    var system: String?
    /// The patch it was cut from, which ties it to a storm.
    var feature: String?
    var coarse = false
    var peakDbz: Double?
    var areaKm2: Double?
    var seedDbz: Double?
}

// MARK: - Decoding

/// The data service's JSON, keys in snake case.
enum StormJSON {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    static func storms(_ data: Data) -> StormCollection? { try? decoder().decode(StormCollection.self, from: data) }
    static func detail(_ data: Data) -> StormDetail? { try? decoder().decode(StormDetail.self, from: data) }
    static func track(_ data: Data) -> TrackProperties? { try? decoder().decode(TrackFeatureWire.self, from: data).properties }
    static func volumes(_ data: Data) -> [RadarVolume]? { try? decoder().decode(VolumesWire.self, from: data).volumes }
}

/// Keys for the hand-written decoders: the camel-case names the snake-case
/// strategy turns the wire's into.
struct StormKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

private typealias Keyed = KeyedDecodingContainer<StormKey>

private extension Keyed {
    func value<T: Decodable>(_ key: String) throws -> T { try decode(T.self, forKey: StormKey(key)) }
    /// Absent and null alike, and a value of the wrong type too: a field the
    /// panel can do without never loses the whole storm.
    func optional<T: Decodable>(_ key: String) -> T? { (try? decodeIfPresent(T.self, forKey: StormKey(key))) ?? nil }
}

/// `[lon, lat]`, extra coordinates ignored.
private func lonLat(_ values: [Double]) throws -> LonLat {
    guard values.count >= 2 else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "short position")) }
    return LonLat(values[0], values[1])
}

/// A GeoJSON Point's coordinates.
private struct PointWire: Decodable {
    let point: LonLat

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: StormKey.self)
        point = try lonLat(c.value("coordinates"))
    }
}

extension PathGeometry: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: StormKey.self)
        if let line: [[Double]] = try? c.value("coordinates") {
            let points = line.compactMap { try? lonLat($0) }
            self = points.count == 1 ? .point(points[0]) : .line(points)
        } else {
            self = try .point(lonLat(c.value("coordinates")))
        }
    }
}

extension CellPlacement: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: StormKey.self)
        place = try c.value("place")
        distanceKm = try c.value("distanceKm")
        direction = c.optional("direction")
        bearingDeg = c.optional("bearingDeg")
        kind = c.optional("kind") ?? ""
    }
}

extension StormProperties: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: StormKey.self)
        id = try c.value("id")
        bornAt = try c.value("bornAt")
        lastSeen = try c.value("lastSeen")
        status = try c.value("status")
        mergedInto = c.optional("mergedInto")
        splitFrom = c.optional("splitFrom")
        primaryTrack = c.optional("primaryTrack")
        primaryProduct = c.optional("primaryProduct")
        primaryDomain = c.optional("primaryDomain")
        headingDeg = c.optional("headingDeg")
        speedKmh = c.optional("speedKmh")
        severity = c.optional("severity") ?? 0
        peakDbz = c.optional("peakDbz")
        hail = c.optional("hail") ?? false
        meso = c.optional("meso") ?? false
        placement = c.optional("placement")
        bbox = c.optional("bbox")
        path = try c.value("path")
        tracks = c.optional("tracks") ?? []
    }
}

extension Storm: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: StormKey.self)
        properties = try c.value("properties")
        id = c.optional("id") ?? properties.id
        let point: PointWire = try c.value("geometry")
        geometry = point.point
    }
}

extension StormCollection: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: StormKey.self)
        // One storm the decoder cannot read is dropped, not the answer.
        let wires: [Failable<Storm>] = c.optional("features") ?? []
        features = wires.compactMap(\.value)
    }
}

/// An element of a list that may fail to decode on its own.
private struct Failable<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

extension CellStep: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: StormKey.self)
        t = try c.value("t")
        lon = try c.value("lon")
        lat = try c.value("lat")
        identifier = c.optional("identifier") ?? 0
        severity = c.optional("severity") ?? 0
        severityDecimal = c.optional("severityDecimal")
        maxDbz = c.optional("maxDbz")
        echoTopM = c.optional("echoTopM")
        vil = c.optional("vil")
        areaKm2 = c.optional("areaKm2")
        hailFlag = c.optional("hailFlag") ?? 0
        heavyRainFlag = c.optional("heavyRainFlag") ?? 0
        gustFlag = c.optional("gustFlag") ?? 0
        gustKmh = c.optional("gustKmh")
        lightningRate = c.optional("lightningRate")
        lightningJumps = c.optional("lightningJumps")
        mesoSeverity = c.optional("mesoSeverity")
        mesoRotMs = c.optional("mesoRotMs")
        speedKmh = c.optional("speedKmh")
        headingDeg = c.optional("headingDeg")
        deviationDeg = c.optional("deviationDeg")
        split = c.optional("split") ?? false
        merge = c.optional("merge") ?? false
    }
}

extension ForecastPoint: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: StormKey.self)
        t = try c.value("t")
        lon = try c.value("lon")
        lat = try c.value("lat")
        majorKm = c.optional("majorKm")
        minorKm = c.optional("minorKm")
        angleDeg = c.optional("angleDeg")
    }
}

extension CellLayer: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: StormKey.self)
        dbz = try c.value("dbz")
        areaKm2 = try c.value("areaKm2")
        topM = try c.value("topM")
        volumeKm3 = c.optional("volumeKm3")
    }
}

extension CellVolume: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: StormKey.self)
        path = try c.value("path")
        coverage = try c.value("coverage")
        sites = c.optional("sites") ?? []
        bytes = c.optional("bytes")
        tier = c.optional("tier") ?? 2
        scannedAt = c.optional("scannedAt")
        oldestScanAt = c.optional("oldestScanAt")
    }
}

extension TrackProperties: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: StormKey.self)
        code = try c.value("code")
        firstSeen = try c.value("firstSeen")
        lastSeen = try c.value("lastSeen")
        nSteps = c.optional("nSteps") ?? 0
        active = c.optional("active") ?? false
        maxSeverity = c.optional("maxSeverity") ?? 0
        lineageFirstDetection = c.optional("lineageFirstDetection")
        maxDbz = c.optional("maxDbz")
        vilMax = c.optional("vilMax")
        echoTopMaxM = c.optional("echoTopMaxM")
        echoBottomM = c.optional("echoBottomM")
        hailEver = c.optional("hailEver") ?? false
        mesoEver = c.optional("mesoEver") ?? false
        splitEver = c.optional("splitEver") ?? false
        mergeEver = c.optional("mergeEver") ?? false
        hailMinutes = c.optional("hailMinutes") ?? 0
        mesoMinutes = c.optional("mesoMinutes") ?? 0
        lightningJumpRecent = c.optional("lightningJumpRecent") ?? false
        intensifying = c.optional("intensifying") ?? false
        deviationDeg = c.optional("deviationDeg")
        parentCodes = c.optional("parentCodes") ?? []
        childCodes = c.optional("childCodes") ?? []
        placement = c.optional("placement")
        let ring: [[Double]]? = c.optional("polygon")
        polygon = ring.map { $0.compactMap { try? lonLat($0) } }
        series = (c.optional("series") as [Failable<CellStep>]?)?.compactMap(\.value) ?? []
        forecast = (c.optional("forecast") as [Failable<ForecastPoint>]?)?.compactMap(\.value) ?? []
        structure = (c.optional("structure") as [Failable<CellLayer>]?)?.compactMap(\.value) ?? []
        volume = c.optional("volume")
    }
}

/// `TrackFeature`: the properties are all the panel reads.
private struct TrackFeatureWire: Decodable {
    let properties: TrackProperties
}

extension TrackerFeature: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: StormKey.self)
        id = try c.value("id")
        kind = try c.value("kind")
        validAt = try c.value("validAt")
        parent = c.optional("parent")
        centroid = (try c.value("centroid") as PointWire).point
        peak = (try c.value("peak") as PointWire).point
        peakDbz = try c.value("peakDbz")
        areaKm2 = try c.value("areaKm2")
        let outline: OutlineWire? = c.optional("outline")
        self.outline = outline?.rings ?? []
    }
}

/// A GeoJSON Polygon's rings.
private struct OutlineWire: Decodable {
    let rings: [[LonLat]]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: StormKey.self)
        let rings: [[[Double]]] = try c.value("coordinates")
        self.rings = rings.map { $0.compactMap { try? lonLat($0) } }
    }
}

extension TrackerTrack: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: StormKey.self)
        id = try c.value("id")
        product = try c.value("product")
        domain = try c.value("domain")
        kind = try c.value("kind")
        firstSeen = try c.value("firstSeen")
        lastSeen = try c.value("lastSeen")
        active = c.optional("active") ?? false
        parentTracks = c.optional("parentTracks") ?? []
        childTracks = c.optional("childTracks") ?? []
        maxPeakDbz = c.optional("maxPeakDbz") ?? 0
        bbox = c.optional("bbox")
        path = (c.optional("path") as PathGeometry?) ?? .line([])
        nFeatures = c.optional("nFeatures") ?? 0
        features = (c.optional("features") as [Failable<TrackerFeature>]?)?.compactMap(\.value) ?? []
    }
}

extension StormDetail: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: StormKey.self)
        storm = try c.value("storm")
        let cells: [Failable<TrackFeatureWire>] = c.optional("konrad3d") ?? []
        konrad3d = cells.compactMap { $0.value?.properties }
        tracks = (c.optional("tracks") as [Failable<TrackerTrack>]?)?.compactMap(\.value) ?? []
    }
}

extension RadarVolume: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: StormKey.self)
        path = try c.value("path")
        coverage = try c.value("coverage")
        code = try c.value("code")
        lon = try c.value("lon")
        lat = try c.value("lat")
        referenceTime = try c.value("referenceTime")
        network = c.optional("network") ?? "de"
        scannedAt = c.optional("scannedAt")
        oldestScanAt = c.optional("oldestScanAt")
        sites = c.optional("sites") ?? []
        bytes = c.optional("bytes")
        tier = c.optional("tier") ?? 2
        system = c.optional("system")
        feature = c.optional("feature")
        coarse = c.optional("coarse") ?? false
        peakDbz = c.optional("peakDbz")
        areaKm2 = c.optional("areaKm2")
        seedDbz = c.optional("seedDbz")
    }
}

/// `/cells/volumes`.
private struct VolumesWire: Decodable {
    let volumes: [RadarVolume]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: StormKey.self)
        volumes = (c.optional("volumes") as [Failable<RadarVolume>]?)?.compactMap(\.value) ?? []
    }
}

// MARK: - Time

/// The data service's timestamps (`2026-10-20T00:25:00Z`, fractional seconds
/// and offsets accepted) as unix milliseconds, which core's rules count in.
enum StormTime {
    /// Unix ms, or NaN for a string that is not a timestamp (core's
    /// `new Date(x).getTime()`).
    static func ms(_ iso: String) -> Double {
        let c = Array(iso.utf8)
        func digits(_ at: Int, _ count: Int) -> Int? {
            guard at + count <= c.count else { return nil }
            var value = 0
            for i in at ..< at + count {
                let d = Int(c[i]) - 48
                guard (0 ... 9).contains(d) else { return nil }
                value = value * 10 + d
            }
            return value
        }
        guard c.count >= 19, c[4] == 45, c[7] == 45, c[10] == 84 || c[10] == 116, c[13] == 58,
              let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2),
              let hour = digits(11, 2), let minute = digits(14, 2) else { return .nan }
        var at = 16
        var second = 0
        if at < c.count, c[at] == 58, let s = digits(17, 2) {
            second = s
            at = 19
        }
        var fraction = 0.0
        if at < c.count, c[at] == 46 {
            at += 1
            var scale = 0.1
            while at < c.count, (48 ... 57).contains(c[at]) {
                fraction += Double(Int(c[at]) - 48) * scale
                scale /= 10
                at += 1
            }
        }
        var offset = 0
        if at < c.count, c[at] == 43 || c[at] == 45 {
            let sign = c[at] == 45 ? -1 : 1
            guard let h = digits(at + 1, 2) else { return .nan }
            let m = digits(at + 4, 2) ?? digits(at + 3, 2) ?? 0
            offset = sign * (h * 60 + m)
        }
        let days = daysFromCivil(year, month, day)
        let seconds = Double(days * 86400 + hour * 3600 + minute * 60 + second - offset * 60) + fraction
        return seconds * 1000
    }

    /// `new Date(ms).toISOString()`: `2026-10-20T00:25:00.000Z`.
    static func iso(_ ms: Double) -> String {
        let whole = Int((ms / 1000).rounded(.down))
        let millis = Int(ms - Double(whole) * 1000)
        let days = Int((Double(whole) / 86400).rounded(.down))
        let rest = whole - days * 86400
        let (y, m, d) = civilFromDays(days)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", y, m, d, rest / 3600, rest % 3600 / 60, rest % 60, millis)
    }

    /// Days since 1970-01-01 (Howard Hinnant's algorithm).
    private static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func civilFromDays(_ days: Int) -> (Int, Int, Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }
}
