//
//  ScanHistory.swift
//  meteocool
//
//  The storms at an earlier scan, found in the bucket by key (core's
//  `lib/cloudHistory.ts`). `/cells/volumes` lists only the newest scan, but
//  each volume stays filed under `volumes/<scan>/<network>-<tile>.mcvx` for
//  about a day. So an earlier scan is asked for its coarse zoom-9 tiles where
//  storms are now and around them; their 1 km voxels say which quarters hold
//  echo, and only there are the fine tiles asked for.
//

import Foundation

enum ScanHistory {
    typealias Scan = Int

    /// Between two scans of a network's composite.
    static let scanSeconds = 300
    /// How far back the picker reaches, in scans: the flat map's two hours.
    static let historyScans = 24
    static let coarseZoom = 9
    static let seedDbz = 25.0
    static let minQuarterColumns = 2
    static let coreDbz = 50.0
    static let fallbackTemplate = "meteoradar/volumes/20260922T011500/de-T00.mcvx"

    /// The earlier scans offered, newest first.
    static func earlierScans(newest: Scan, count: Int = historyScans) -> [Scan] {
        (0 ..< count).map { newest - ($0 + 1) * scanSeconds }
    }

    /// A network's scan nearest a picked one, on that network's own clock.
    static func scanOnClock(known: Scan, picked: Scan) -> Scan {
        known + Int((Double(picked - known) / Double(scanSeconds)).rounded()) * scanSeconds
    }

    /// `20261005T221000`, UTC.
    static func stamp(_ scan: Scan) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(scan)))
    }

    /// The scan a listed path is filed under.
    static func scan(ofPath path: String) -> Scan? {
        guard let range = path.range(of: #"\d{8}T\d{6}"#, options: .regularExpression) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter.date(from: String(path[range])).map { Int($0.timeIntervalSince1970) }
    }

    /// Where a tile's volume would be at `scan`, named after a listed path.
    static func pathAt(_ listed: String, scan: Scan, network: String, code: String) -> String? {
        guard let match = listed.range(of: #"^.*/\d{8}T\d{6}/[^/]+\.mcvx$"#, options: .regularExpression), match == listed.startIndex ..< listed.endIndex,
              let folder = listed.range(of: #"\d{8}T\d{6}/[^/]+\.mcvx$"#, options: .regularExpression) else { return nil }
        return String(listed[listed.startIndex ..< folder.lowerBound]) + "\(stamp(scan))/\(network)-\(code).mcvx"
    }

    /// `T`, the zoom in two digits, x and y in five (`Tile.code`).
    static func tileCode(_ z: Int, _ x: Int, _ y: Int) -> String {
        String(format: "T%02d%05d%05d", z, x, y)
    }

    /// The middle of a tile, lon/lat.
    static func tileCentre(_ z: Int, _ x: Int, _ y: Int) -> (lon: Double, lat: Double) {
        let n = pow(2, Double(z))
        return ((Double(x) + 0.5) / n * 360 - 180, atan(sinh(.pi * (1 - 2 * (Double(y) + 0.5) / n))) * 180 / .pi)
    }

    /// The coarse tile a tile of any zoom lies in.
    static func coarseOf(_ tile: [Int]) -> (x: Int, y: Int)? {
        guard tile.count == 3, tile[0] >= coarseZoom else { return nil }
        let shift = tile[0] - coarseZoom
        return (tile[1] >> shift, tile[2] >> shift)
    }

    struct Place: Hashable {
        let network: String
        let x: Int
        let y: Int
    }

    /// These places and the eight around each, once each, in order.
    static func around(_ places: [Place]) -> [Place] {
        var seen = Set<Place>()
        var out: [Place] = []
        for place in places {
            for dy in -1 ... 1 {
                for dx in -1 ... 1 {
                    let near = Place(network: place.network, x: place.x + dx, y: place.y + dy)
                    if seen.insert(near).inserted { out.append(near) }
                }
            }
        }
        return out
    }

    /// One zoom-10 quarter of a coarse tile and the echo over it.
    struct Quarter: Equatable {
        let tile: [Int]
        /// The strongest echo, dBZ, column maximum; -inf without any.
        let peak: Double
        /// Columns reaching `seedDbz`.
        let columns: Int
    }

    /// The four zoom-10 tiles in a coarse tile, with the echo over each.
    static func quarters(_ volume: StormVolume) -> [Quarter] {
        let header = volume.header
        guard let tile = header.tile, tile.count == 3 else { return [] }
        let (nx, ny, nz) = (header.nx, header.ny, header.nz)
        let ax = header.apron?.first ?? 0, ay = header.apron.flatMap { $0.count > 1 ? $0[1] : nil } ?? 0
        let across = nx - 2 * ax, up = ny - 2 * ay
        guard across > 0, up > 0 else { return [] }
        var strongest = [Int](repeating: -1, count: across * up)
        volume.voxels.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for z in 0 ..< nz {
                for row in 0 ..< up {
                    for column in 0 ..< across {
                        let at = ((z * ny + row + ay) * nx + column + ax) * 2
                        guard at + 1 < bytes.count, bytes[at + 1] != 0 else { continue }
                        let cell = row * across + column
                        if Int(bytes[at]) > strongest[cell] { strongest[cell] = Int(bytes[at]) }
                    }
                }
            }
        }
        let seed = (seedDbz - header.dbzFloor) * header.dbzScale
        let (x, y) = (tile[1], tile[2])
        return [(0, 0), (1, 0), (0, 1), (1, 1)].map { qx, qy in
            // The northern quarters, qy = 0, are the upper rows.
            let rows = qy == 0 ? (up / 2) ..< up : 0 ..< (up / 2)
            let columns = qx == 0 ? 0 ..< (across / 2) : (across / 2) ..< across
            var peak = -1, count = 0
            for row in rows {
                for column in columns {
                    let byte = strongest[row * across + column]
                    peak = max(peak, byte)
                    if Double(byte) >= seed { count += 1 }
                }
            }
            return Quarter(tile: [coarseZoom + 1, 2 * x + qx, 2 * y + qy],
                           peak: peak < 0 ? -.infinity : Double(peak) / header.dbzScale + header.dbzFloor, columns: count)
        }
    }

    /// The tiles to ask over a quarter, as two tries; the second only if the first found nothing.
    static func tilesToAsk(_ quarter: Quarter) -> (first: [[Int]], second: [[Int]]) {
        guard quarter.columns >= minQuarterColumns else { return ([], []) }
        let (z, x, y) = (quarter.tile[0], quarter.tile[1], quarter.tile[2])
        let cores = [(0, 0), (1, 0), (0, 1), (1, 1)].map { [z + 1, 2 * x + $0.0, 2 * y + $0.1] }
        return quarter.peak >= coreDbz ? (cores, []) : ([quarter.tile], cores)
    }

    /// The strongest echo a volume measured over its own ground, dBZ.
    static func peakDbz(_ volume: StormVolume) -> Double? {
        let header = volume.header
        let ax = header.apron?.first ?? 0, ay = header.apron.flatMap { $0.count > 1 ? $0[1] : nil } ?? 0
        var peak = -1
        volume.voxels.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for z in 0 ..< header.nz {
                for row in ay ..< max(ay, header.ny - ay) {
                    for column in ax ..< max(ax, header.nx - ax) {
                        let at = ((z * header.ny + row) * header.nx + column) * 2
                        if at + 1 < bytes.count, bytes[at + 1] != 0, Int(bytes[at]) > peak { peak = Int(bytes[at]) }
                    }
                }
            }
        }
        return peak < 0 ? nil : ((Double(peak) / header.dbzScale + header.dbzFloor) * 10).rounded() / 10
    }

    /// A volume found in the bucket as the list would have had it.
    static func entry(path: String, volume: StormVolume, network: String) -> StormEntry {
        let header = volume.header
        let coarse = (header.tile?.first ?? coarseZoom + 1) <= coarseZoom
        return StormEntry(code: header.code, network: header.network ?? network, lon: header.lon, lat: header.lat, path: path,
                          tier: header.tier ?? 2, peakDbz: peakDbz(volume), areaKm2: nil, coverage: header.coverage, bytes: nil,
                          scannedAt: header.scannedAt ?? header.referenceTime, referenceTime: header.referenceTime,
                          tile: header.tile, system: nil, coarse: coarse)
    }

    /// The places to ask a scan at: where storms are listed now and the
    /// ground around them, nearest the viewer first, at most `limit`.
    static func places(from listed: [StormEntry], viewer: (lat: Double, lon: Double)?, limit: Int = 36) -> [Place] {
        var seeds: [(place: Place, metres: Double)] = []
        for entry in listed {
            guard let tile = entry.tile, let coarse = coarseOf(tile) else { continue }
            let metres = viewer.map { Geo.distanceBearing(fromLat: $0.lat, lon: $0.lon, toLat: entry.lat, lon: entry.lon).metres } ?? 0
            seeds.append((Place(network: entry.network ?? "de", x: coarse.x, y: coarse.y), metres))
        }
        seeds.sort { $0.metres < $1.metres }
        var unique: [Place] = []
        var seen = Set<Place>()
        for seed in seeds where seen.insert(seed.place).inserted { unique.append(seed.place) }
        return Array(around(unique).prefix(limit))
    }

    /// Asks one scan for its storms: the coarse tiles over `places`, then the
    /// fine tiles of their quarters with echo. `fetch` gives nil for a tile
    /// that is not there and throws for one that would not load.
    static func find(scan picked: Scan, places: [Place], template: String, knownScans: [String: Scan],
                     fetch: @escaping @Sendable (String) async throws -> StormVolume?,
                     progress: @escaping @MainActor (Double) -> Void) async -> (entries: [StormEntry], volumes: [String: StormVolume], failed: Int) {
        func scanOf(_ network: String) -> Scan { knownScans[network].map { scanOnClock(known: $0, picked: picked) } ?? picked }
        var entries: [StormEntry] = []
        var volumes: [String: StormVolume] = [:]
        var failed = 0
        var done = 0
        // The coarse tiles, all at once.
        let coarse: [(Place, String, StormVolume?)] = await withTaskGroup(of: (Place, String, StormVolume?, Bool).self) { group in
            for place in places {
                guard let path = pathAt(template, scan: scanOf(place.network), network: place.network,
                                        code: tileCode(coarseZoom, place.x, place.y)) else { continue }
                group.addTask {
                    do { return (place, path, try await fetch(path), false) } catch { return (place, path, nil, true) }
                }
            }
            var out: [(Place, String, StormVolume?)] = []
            for await (place, path, volume, error) in group {
                if error { failed += 1 }
                out.append((place, path, volume))
                done += 1
                let share = 0.6 * Double(done) / Double(max(places.count, 1))
                await progress(share)
            }
            return out
        }
        // Their quarters with a storm, asked fine.
        var asks: [(Place, [[Int]], [[Int]])] = []
        for (place, path, volume) in coarse {
            guard let volume else { continue }
            entries.append(entry(path: path, volume: volume, network: place.network))
            volumes[path] = volume
            for quarter in quarters(volume) {
                let tries = tilesToAsk(quarter)
                if !tries.first.isEmpty { asks.append((place, tries.first, tries.second)) }
            }
        }
        var fineDone = 0
        let fine: [(String, StormVolume, String)] = await withTaskGroup(of: [(String, StormVolume, String)].self) { group in
            for (place, first, second) in asks {
                let scan = scanOf(place.network)
                group.addTask {
                    func ask(_ tiles: [[Int]]) async -> [(String, StormVolume, String)] {
                        var found: [(String, StormVolume, String)] = []
                        for tile in tiles {
                            guard let path = pathAt(template, scan: scan, network: place.network, code: tileCode(tile[0], tile[1], tile[2])),
                                  let volume = try? await fetch(path) else { continue }
                            found.append((path, volume, place.network))
                        }
                        return found
                    }
                    let found = await ask(first)
                    return found.isEmpty && !second.isEmpty ? await ask(second) : found
                }
            }
            var out: [(String, StormVolume, String)] = []
            for await found in group {
                out += found
                fineDone += 1
                await progress(0.6 + 0.4 * Double(fineDone) / Double(max(asks.count, 1)))
            }
            return out
        }
        for (path, volume, network) in fine {
            entries.append(entry(path: path, volume: volume, network: network))
            volumes[path] = volume
        }
        return (entries, volumes, failed)
    }
}
