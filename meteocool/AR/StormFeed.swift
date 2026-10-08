//
//  StormFeed.swift
//  meteocool
//
//  What the AR storm view knows about the weather around the viewer.
//

import Foundation

// MARK: - Wire models

/// One storm with a radar volume built for it, from `GET /cells/volumes`.
/// Found in the column-maximum composite, not in
/// KONRAD3D, so most of them have no tracked cell.
struct StormEntry: Decodable, Sendable, Equatable {
    let code: String
    let network: String?
    /// The core's peak, and the centre of its box.
    let lon: Double
    let lat: Double
    /// The volume file's path, relative to the asset host.
    let path: String
    let tier: Int?
    let peakDbz: Double?
    let areaKm2: Double?
    let coverage: Double?
    let bytes: Int?
    let scannedAt: String?
    let referenceTime: String?
    /// The Web Mercator tile the box fills, z, x, y; nil before tiles.
    let tile: [Int]?
    /// The code of the tile holding the peak of this tile's storm: one storm's
    /// tiles share it. Nil before tiles, when a box was a storm of its own.
    let system: String?
    /// A zoom-9 tile for a map zoomed out, listed only with `?coarse=true`,
    /// which this view does not ask for.
    let coarse: Bool?

    /// Whether the radars saw it well enough to cut open.
    var openable: Bool { (tier ?? 2) >= 2 }
    /// The storm it is part of: its `system`, or the box itself before tiles.
    var stormKey: String { system ?? path }
    /// The zoom-9 tile a fine tile lies in, whose coarse volume can stand in
    /// for it far away; nil for a coarse tile or a box from before tiles.
    var coarseParent: [Int]? {
        guard let tile, tile.count == 3, tile[0] > 9 else { return nil }
        let shift = tile[0] - 9
        return [9, tile[1] >> shift, tile[2] >> shift]
    }

    /// Whether a point lies in the map tile it fills; false before tiles.
    func tileContains(lat: Double, lon: Double) -> Bool {
        guard let tile, tile.count == 3 else { return false }
        let n = pow(2, Double(tile[0]))
        let x = Int(((lon + 180) / 360 * n).rounded(.down))
        let φ = lat * .pi / 180
        let y = Int(((1 - log(tan(φ) + 1 / cos(φ)) / .pi) / 2 * n).rounded(.down))
        return x == tile[1] && y == tile[2]
    }

    /// Whether it is the tile its storm is named after, the one holding the peak.
    var isStormPeak: Bool { system == nil || system == code }
    /// Its 3D texture's bytes before it has loaded, as the volume files are
    /// built: 104 voxels across a zoom-10 tile, 52 for a
    /// zoom-11 core tile or a coarse zoom-9 one, a voxel of apron each side,
    /// 32 levels; 160 x 160 x 32 for a box from before tiles.
    var estimatedTextureBytes: Int {
        guard let zoom = tile?.first else { return 160 * 160 * 32 * 2 }
        let across = zoom == 10 ? 104 : 52
        return (across + 2) * (across + 2) * 32 * 2
    }
    /// The newest sweep in the box, falling back to the composite's scan.
    var scanDate: Date? { ISODate.parse(scannedAt) ?? ISODate.parse(referenceTime) }
}

struct VolumeIndex: Decodable, Sendable {
    let referenceTime: String?
    let volumes: [StormEntry]?
}

/// A KONRAD3D cell from `GET /cells/current`: what DWD
/// measured about a tracked storm.
struct TrackedCell: Decodable, Sendable {
    struct VolumeRef: Decodable, Sendable { let path: String }
    struct ForecastPoint: Decodable, Sendable {
        let t: String
        let lon: Double
        let lat: Double
        let majorKm: Double?
        let minorKm: Double?
        let angleDeg: Double?
    }

    let code: String
    let t: String?
    let lon: Double
    let lat: Double
    let maxDbz: Double?
    let echoTopM: Double?
    let echoBottomM: Double?
    let headingDeg: Double?
    let speedKmh: Double?
    let severity: Int?
    let hailFlag: Int?
    let gustFlag: Int?
    let heavyRainFlag: Int?
    let gustKmh: Double?
    let lightningRate: Int?
    let lightningJumps: Int?
    let mesoSeverity: Int?
    let mesoRotMs: Double?
    let vil: Double?
    let areaKm2: Double?
    let forecast: [ForecastPoint]?
    /// The box this cell's centroid stands in, if one was built.
    let volume: VolumeRef?
}

struct CellIndex: Decodable, Sendable {
    let referenceTime: String?
    let cells: [TrackedCell]?
}

/// A cell's history from `GET /cells/tracks`: the path
/// its centroid took, and the place it is described against.
struct CellTrack: Decodable, Sendable {
    struct Placement: Decodable, Sendable {
        let place: String
        let kind: String?
        let distanceKm: Double
        let direction: String?
        let bearingDeg: Double?
    }
    struct Properties: Decodable, Sendable {
        let code: String
        let active: Bool?
        let placement: Placement?
    }

    let properties: Properties
    /// `[lon, lat]` centroids, oldest first. A one-step track is a single point.
    let path: [[Double]]

    enum CodingKeys: String, CodingKey { case properties, geometry }
    enum GeometryKeys: String, CodingKey { case type, coordinates }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        properties = try container.decode(Properties.self, forKey: .properties)
        let geometry = try container.nestedContainer(keyedBy: GeometryKeys.self, forKey: .geometry)
        if let line = try? geometry.decode([[Double]].self, forKey: .coordinates) {
            path = line
        } else if let point = try? geometry.decode([Double].self, forKey: .coordinates) {
            path = [point]
        } else {
            path = []
        }
    }
}

struct TrackCollection: Decodable, Sendable {
    let features: [CellTrack]?
}

/// A strike from `GET /lightning_cache`. `lon` and `lat` are EPSG:3857
/// metres despite their names; `time` is epoch milliseconds.
private struct WireStrike: Decodable { let lat: Double; let lon: Double; let time: Double }
/// A detection from `GET /mesocyclones/all/`, in the same projected metres.
private struct WireMesocyclone: Decodable { let lat: Double; let lon: Double; let diameter: Double?; let intensity: Int?; let time: Double? }

struct LightningStrike: Sendable {
    let lat: Double
    let lon: Double
    let time: Date
}

struct Mesocyclone: Sendable {
    let lat: Double
    let lon: Double
    let diameterM: Double
    let intensity: Int
}

enum ISODate {
    static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        // BSON keeps no offset, and an older wire format sent naive UTC.
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: value)
    }
}

// MARK: - The feed

/// Polls the data service for the storms around a point, and keeps the
/// volumes of the ones worth drawing in memory.
///
/// The volume list is one small request for the whole continent; each volume is 1.6 MB once inflated, so only the nearest few, the
/// ones in front of the camera first, are held. The rest are listed with
/// their position, which is enough for a label.
@MainActor
final class StormFeed {
    enum Status: Equatable {
        case loading
        case ready
        case failed
    }

    /// Storms further than this are not drawn: past it a storm is below the
    /// horizon or a sliver on it.
    static let rangeMetres = 180_000.0
    /// 3D texture held at once, in bytes. A storm is as many tiles as it
    /// needs, so the budget is bytes rather than boxes: about 46 zoom-10 tiles,
    /// or 20 of the 40 km boxes from before tiles. Core's 3D map holds 39 MB.
    static let residentBytes = 32 * 1024 * 1024
    /// Beyond this, a storm is drawn from its coarse tiles: at 90 km a 250 m
    /// voxel is a sixth of a degree, finer than the half-resolution pass can
    /// show, and a coarse tile costs a sixteenth of the fine ones it covers.
    static let coarseBeyondMetres = 90_000.0
    /// Held beyond the budget before anything is let go, so turning round
    /// does not refetch what was just dropped.
    static let spareBytes = 8 * 1024 * 1024

    private(set) var status: Status = .loading
    /// The storms' fine tiles, or their boxes from before tiles.
    private(set) var entries: [StormEntry] = []
    /// Coarse zoom-9 tiles, by `tile`: about 1 km a voxel, drawn in place of
    /// the fine tiles inside them for storms far away (see `drawUnit`).
    private(set) var coarse: [[Int]: StormEntry] = [:]
    private(set) var volumes: [String: StormVolume] = [:]
    private(set) var cellsByPath: [String: TrackedCell] = [:]
    /// The cells as last read, linked to boxes by `linkCells`.
    private(set) var cells: [TrackedCell] = []
    private(set) var tracks: [String: CellTrack] = [:]
    private(set) var strikes: [LightningStrike] = []
    private(set) var mesocyclones: [Mesocyclone] = []
    /// When the volume list was last read; nil until it has been.
    private(set) var listedAt: Date?

    /// Called on the main actor whenever anything above changes.
    var onChange: (() -> Void)?

    /// Where the viewer stands. Storms are filtered and ranked from here.
    var viewer: (lat: Double, lon: Double)? {
        didSet {
            reconcile()
            // Tracks are asked for around the viewer; the poll's first round
            // may have gone by before there was one.
            if oldValue == nil, viewer != nil, !polls.isEmpty {
                Task { [weak self] in await self?.loadTracks() }
            }
        }
    }
    /// Where the camera looks, true azimuth in degrees; storms in front load first.
    var lookAzimuth: Double?

    private var inflight: Set<String> = []
    private var retryAfter: [String: Date] = [:]
    private var polls: [Task<Void, Never>] = []
    private let session: URLSession
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func start() {
        guard polls.isEmpty else { return }
        polls = [
            poll(every: .seconds(60)) { await $0.loadVolumeIndex() },
            poll(every: .seconds(60)) { await $0.loadCells() },
            poll(every: .seconds(120)) { await $0.loadTracks() },
            poll(every: .seconds(20)) { await $0.loadLightning() },
            poll(every: .seconds(60)) { await $0.loadMesocyclones() },
            // Residency follows the camera. The check is cheap and sends no request.
            poll(every: .seconds(2)) { feed in feed.reconcile() },
        ]
    }

    func stop() {
        polls.forEach { $0.cancel() }
        polls.removeAll()
    }

    /// Storms within range of the viewer, nearest first.
    var nearbyEntries: [StormEntry] {
        guard let viewer else { return entries }
        var ranked: [(entry: StormEntry, metres: Double)] = []
        for entry in entries {
            let metres = Geo.distanceBearing(fromLat: viewer.lat, lon: viewer.lon, toLat: entry.lat, lon: entry.lon).metres
            if metres <= Self.rangeMetres { ranked.append((entry, metres)) }
        }
        ranked.sort { $0.metres < $1.metres }
        return ranked.map(\.entry)
    }

    /// What is drawn for a fine tile: the coarse tile it lies in when that is
    /// listed and its middle is far away, otherwise the tile itself. Decided
    /// by the coarse tile, so all the tiles inside it go one way and the
    /// coarse tile never overlaps a fine one drawn beside it.
    func drawUnit(for entry: StormEntry) -> StormEntry {
        guard let viewer, let parent = entry.coarseParent, let coarse = coarse[parent] else { return entry }
        let metres = Geo.distanceBearing(fromLat: viewer.lat, lon: viewer.lon, toLat: coarse.lat, lon: coarse.lon).metres
        return metres > Self.coarseBeyondMetres ? coarse : entry
    }

    /// What to draw this frame, nearest storms' units first: each fine tile's
    /// draw unit, once. A coarse unit not yet loaded falls back to the fine
    /// tiles inside it that are, so a storm does not vanish while it loads.
    func drawPlan() -> [StormEntry] {
        var plan: [StormEntry] = []
        var seen: Set<String> = []
        for entry in nearbyEntries {
            var unit = drawUnit(for: entry)
            if unit.path != entry.path, volumes[unit.path] == nil { unit = entry }
            if seen.insert(unit.path).inserted { plan.append(unit) }
        }
        return plan
    }

    /// The tracked cell standing in a storm's box, if any.
    func cell(for entry: StormEntry) -> TrackedCell? { cellsByPath[entry.path] }

    func track(for entry: StormEntry) -> CellTrack? {
        guard let code = cellsByPath[entry.path]?.code else { return nil }
        return tracks[code]
    }

    private func poll(every interval: Duration, _ work: @escaping @MainActor (StormFeed) async -> Void) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await work(self)
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func get<T: Decodable>(_ type: T.Type, _ path: String, base: URL = NetworkHelper.dataURL) async -> T? {
        guard let url = URL(string: path, relativeTo: base) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    private func loadVolumeIndex() async {
        guard let index = await get(VolumeIndex.self, "cells/volumes?coarse=true") else {
            if listedAt == nil { status = .failed; onChange?() }
            return
        }
        ingest(index)
        listedAt = Date()
        status = .ready
        reconcile()
        onChange?()
    }

    /// Take a volume list: fine tiles (and boxes from before tiles) as the
    /// storms, coarse tiles kept aside by their tile.
    func ingest(_ index: VolumeIndex) {
        let listed = index.volumes ?? []
        entries = listed.filter { $0.coarse != true }
        coarse = Dictionary(listed.compactMap { entry in entry.coarse == true ? entry.tile.map { ($0, entry) } : nil },
                            uniquingKeysWith: { first, _ in first })
        linkCells()
    }

    /// For the checks: cells as `/cells/current` would deliver them.
    func ingest(cells: [TrackedCell]) {
        self.cells = cells
        linkCells()
    }

    private func loadCells() async {
        guard let index = await get(CellIndex.self, "cells/current") else { return }
        cells = index.cells ?? []
        linkCells()
        onChange?()
    }

    /// Give each cell the box it stands in: the one its `volume` names, or,
    /// when that is not in the list held (the cells and the volumes are
    /// polled apart, and a cell names the newest scan's tile before the list
    /// has caught up), the listed tile its centroid falls in.
    func linkCells() {
        let listed = Set(entries.map(\.path))
        var byPath: [String: TrackedCell] = [:]
        for cell in cells {
            var path = cell.volume?.path
            if path.map({ !listed.contains($0) }) ?? true {
                path = entries.first { $0.tileContains(lat: cell.lat, lon: cell.lon) }?.path
            }
            guard let path else { continue }
            // Two cells in one box: the stronger one speaks for it.
            if let other = byPath[path], (other.maxDbz ?? 0) >= (cell.maxDbz ?? 0) { continue }
            byPath[path] = cell
        }
        cellsByPath = byPath
    }

    private func loadTracks() async {
        guard let viewer else { return }
        // About 180 km each way, which is the range storms are drawn at.
        let dLat = 1.7, dLon = 1.7 / max(cos(viewer.lat * .pi / 180), 0.2)
        let bbox = String(format: "%.3f,%.3f,%.3f,%.3f", viewer.lon - dLon, viewer.lat - dLat, viewer.lon + dLon, viewer.lat + dLat)
        guard let collection = await get(TrackCollection.self, "cells/tracks?bbox=\(bbox)") else { return }
        var byCode: [String: CellTrack] = [:]
        for track in collection.features ?? [] where track.properties.active != false {
            byCode[track.properties.code] = track
        }
        tracks = byCode
        onChange?()
    }

    private func loadLightning() async {
        guard let wire = await get([WireStrike].self, "lightning_cache") else { return }
        let cutoff = Date().addingTimeInterval(-10 * 60)
        strikes = wire.compactMap { strike in
            let time = Date(timeIntervalSince1970: strike.time / 1000)
            guard time > cutoff else { return nil }
            let (lon, lat) = Geo.lonLat(mercatorX: strike.lon, y: strike.lat)
            if let viewer, Geo.distanceBearing(fromLat: viewer.lat, lon: viewer.lon, toLat: lat, lon: lon).metres > Self.rangeMetres {
                return nil
            }
            return LightningStrike(lat: lat, lon: lon, time: time)
        }
        onChange?()
    }

    private func loadMesocyclones() async {
        guard let wire = await get([WireMesocyclone].self, "mesocyclones/all/") else { return }
        mesocyclones = wire.map { meso in
            let (lon, lat) = Geo.lonLat(mercatorX: meso.lon, y: meso.lat)
            return Mesocyclone(lat: lat, lon: lon, diameterM: meso.diameter ?? 2000, intensity: meso.intensity ?? 0)
        }
        onChange?()
    }

    /// Fetch the volumes worth holding, and let go of the rest.
    ///
    /// Storms in front of the camera rank first, then by distance: a storm
    /// behind the viewer can wait until they turn round.
    func reconcile() {
        // Whole storms, in front of the camera first, then nearest, until the
        // budget is spent: half a storm's tiles draws a storm with holes.
        var wanted: [StormEntry] = []
        var bytes = 0
        var ranked: [StormEntry] = []
        var seen: Set<String> = []
        for entry in rankedForResidency() {
            let unit = drawUnit(for: entry)
            if seen.insert(unit.path).inserted { ranked.append(unit) }
        }
        for entry in ranked {
            let cost = volumes[entry.path]?.textureBytes ?? entry.estimatedTextureBytes
            if bytes + cost > Self.residentBytes { break }
            bytes += cost
            wanted.append(entry)
        }
        let wantedPaths = Set(wanted.map(\.path))
        var held = volumes.values.reduce(0) { $0 + $1.textureBytes }
        if held > Self.residentBytes + Self.spareBytes {
            for path in volumes.keys where !wantedPaths.contains(path) {
                held -= volumes[path]?.textureBytes ?? 0
                volumes[path] = nil
                if held <= Self.residentBytes { break }
            }
        }
        // A new scan replaces every path; drop volumes no longer listed at all.
        let listed = Set(entries.map(\.path) + coarse.values.map(\.path))
        for path in volumes.keys where !listed.contains(path) { volumes[path] = nil }

        let now = Date()
        for entry in wanted where volumes[entry.path] == nil && !inflight.contains(entry.path) {
            if let after = retryAfter[entry.path], after > now { continue }
            // Four at a time, as core's VOLUME_FETCHES.
            guard inflight.count < 4 else { break }
            load(entry)
        }
    }

    /// Storm by storm: each ranked by its nearest tile, a storm behind the
    /// camera after every storm in front of it, and its tiles nearest first.
    private func rankedForResidency() -> [StormEntry] {
        guard let viewer else { return entries }
        let look = lookAzimuth
        let scored = nearbyEntries.map { entry -> (entry: StormEntry, score: Double) in
            let (metres, bearing) = Geo.distanceBearing(fromLat: viewer.lat, lon: viewer.lon, toLat: entry.lat, lon: entry.lon)
            var score = metres
            if let look, abs(Geo.angleDifference(bearing, look)) > 70 { score += 1_000_000 }
            return (entry, score)
        }
        var stormScore: [String: Double] = [:]
        for (entry, score) in scored { stormScore[entry.stormKey] = min(stormScore[entry.stormKey] ?? .infinity, score) }
        return scored
            .sorted { a, b in
                let sa = stormScore[a.entry.stormKey]!, sb = stormScore[b.entry.stormKey]!
                return sa != sb ? sa < sb : a.score < b.score
            }
            .map(\.entry)
    }

    private func load(_ entry: StormEntry) {
        guard let url = URL(string: entry.path, relativeTo: NetworkHelper.assetURL) else { return }
        inflight.insert(entry.path)
        let session = session
        Task { [weak self] in
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            let result: Result<StormVolume, Error>
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 403 || status == 404 {
                    result = .failure(VolumeGone())
                } else if !(200 ..< 300).contains(status) {
                    result = .failure(URLError(.badServerResponse))
                } else {
                    // Off the main actor: the decoder walks all 820k voxels once.
                    result = await Task.detached(priority: .userInitiated) { Result { try StormVolume.decode(data) } }.value
                }
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            self.inflight.remove(entry.path)
            switch result {
            case .success(let volume):
                self.volumes[entry.path] = volume
                self.retryAfter[entry.path] = nil
            case .failure(let error) where error is VolumeGone:
                // Past its retention, or not built yet for a scan just listed;
                // core retries the latter, and so does the next index poll.
                self.retryAfter[entry.path] = Date().addingTimeInterval(20)
            case .failure:
                self.retryAfter[entry.path] = Date().addingTimeInterval(20)
            }
            self.onChange?()
            self.reconcile()
        }
    }

    private struct VolumeGone: Error {}
}
