//
//  StormFeed.swift
//  meteocool
//
//  What the AR storm view knows about the weather around the viewer.
//

import Foundation

// MARK: - Wire models

/// One storm with a radar volume built for it, from `GET /cells/volumes`
/// (ng's `RadarVolume`). Found in the column-maximum composite, not in
/// KONRAD3D, so most of them have no tracked cell.
struct StormEntry: Decodable, Sendable, Equatable {
    let code: String
    let network: String?
    /// The core's peak, and the centre of its box.
    let lon: Double
    let lat: Double
    /// The volume file, bucket first, relative to the asset host.
    let path: String
    let tier: Int?
    let peakDbz: Double?
    let areaKm2: Double?
    let coverage: Double?
    let bytes: Int?
    let scannedAt: String?
    let referenceTime: String?

    /// Whether the radars saw it well enough to cut open (ng ADR 0003).
    var openable: Bool { (tier ?? 2) >= 2 }
    /// The newest sweep in the box, falling back to the composite's scan.
    var scanDate: Date? { ISODate.parse(scannedAt) ?? ISODate.parse(referenceTime) }
}

struct VolumeIndex: Decodable, Sendable {
    let referenceTime: String?
    let volumes: [StormEntry]?
}

/// A KONRAD3D cell from `GET /cells/current` (ng's `CellCurrent`): what DWD
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

/// A cell's history from `GET /cells/tracks` (ng's `TrackFeature`): the path
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
/// The volume list is one small request for the whole continent (ng ADR
/// 0009); each volume is 1.6 MB once inflated, so only the nearest few, the
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
    /// Volumes held at once; about 1.6 MB of texture each.
    static let residentLimit = 12

    private(set) var status: Status = .loading
    private(set) var entries: [StormEntry] = []
    private(set) var volumes: [String: StormVolume] = [:]
    private(set) var cellsByPath: [String: TrackedCell] = [:]
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
            // Residency follows the camera; a cheap check, not a request.
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

    /// The tracked cell standing in a storm's box, if any.
    func cell(for entry: StormEntry) -> TrackedCell? { cellsByPath[entry.path] }

    func track(for entry: StormEntry) -> CellTrack? {
        guard let code = cellsByPath[entry.path]?.code else { return nil }
        return tracks[code]
    }

    /// Whether the data service lists any storm within range of a point:
    /// what the map asks before offering the AR view. Nil when it could not ask.
    static func anyStorm(nearLat lat: Double, lon: Double, session: URLSession = .shared) async -> Bool? {
        guard let url = URL(string: "cells/volumes", relativeTo: NetworkHelper.dataURL) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse).map({ (200 ..< 300).contains($0.statusCode) }) == true,
              let index = try? decoder.decode(VolumeIndex.self, from: data) else { return nil }
        return (index.volumes ?? []).contains {
            Geo.distanceBearing(fromLat: lat, lon: lon, toLat: $0.lat, lon: $0.lon).metres <= rangeMetres
        }
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
        guard let index = await get(VolumeIndex.self, "cells/volumes") else {
            if listedAt == nil { status = .failed; onChange?() }
            return
        }
        entries = index.volumes ?? []
        listedAt = Date()
        status = .ready
        reconcile()
        onChange?()
    }

    private func loadCells() async {
        guard let index = await get(CellIndex.self, "cells/current") else { return }
        var byPath: [String: TrackedCell] = [:]
        for cell in index.cells ?? [] {
            guard let path = cell.volume?.path else { continue }
            // Two cells in one box: the stronger one speaks for it.
            if let other = byPath[path], (other.maxDbz ?? 0) >= (cell.maxDbz ?? 0) { continue }
            byPath[path] = cell
        }
        cellsByPath = byPath
        onChange?()
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
        let wanted = rankedForResidency().prefix(Self.residentLimit)
        let wantedPaths = Set(wanted.map(\.path))
        // Keep a few spares: turning round should not refetch what was just let go.
        if volumes.count > Self.residentLimit + 4 {
            for path in volumes.keys where !wantedPaths.contains(path) {
                volumes[path] = nil
                if volumes.count <= Self.residentLimit { break }
            }
        }
        // A new scan replaces every path; drop volumes no longer listed at all.
        let listed = Set(entries.map(\.path))
        for path in volumes.keys where !listed.contains(path) { volumes[path] = nil }

        let now = Date()
        for entry in wanted where volumes[entry.path] == nil && !inflight.contains(entry.path) {
            if let after = retryAfter[entry.path], after > now { continue }
            // Four at a time, as core's VOLUME_FETCHES.
            guard inflight.count < 4 else { break }
            load(entry)
        }
    }

    private func rankedForResidency() -> [StormEntry] {
        guard let viewer else { return entries }
        let look = lookAzimuth
        return nearbyEntries
            .map { entry -> (StormEntry, Double) in
                let (metres, bearing) = Geo.distanceBearing(fromLat: viewer.lat, lon: viewer.lon, toLat: entry.lat, lon: entry.lon)
                var score = metres
                if let look, abs(Geo.angleDifference(bearing, look)) > 70 { score += 1_000_000 }
                return (entry, score)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
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
