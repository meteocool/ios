//
//  ThreeDClouds.swift
//  meteocool
//
//  The storms of the 3D map: the list, what a volume holds, which volumes
//  to draw, and where they stand. Core's rules, ported verbatim.
//

import Foundation
import simd

/// One box of sky from `GET /cells/volumes?coarse=true` (core's
/// `RadarVolume`, `spec/data.openapi.json`).
struct CloudEntry: Decodable, Sendable, Equatable {
    let path: String
    let code: String
    /// The box's centre: its tile's middle in Mercator.
    let lon: Double
    let lat: Double
    let referenceTime: String?
    let coverage: Double?
    let network: String?
    /// 1: drawn but not openable; 2: openable.
    let tier: Int?
    /// z, x, y: 9 coarse, 10 tile, 11 core tile.
    let tile: [Int]?
    let coarse: Bool?
    /// The tile holding this storm's peak: one storm's tiles share it.
    let system: String?
    /// The patch it was cut from, which names its storm.
    let feature: String?
    let peakDbz: Double?
    let areaKm2: Double?
    let seedDbz: Double?
    let scannedAt: String?
    let oldestScanAt: String?
    let sites: [String]?
    let bytes: Int?

    init(path: String, code: String, lon: Double, lat: Double, referenceTime: String? = nil, coverage: Double? = nil,
         network: String? = nil, tier: Int? = nil, tile: [Int]? = nil, coarse: Bool? = nil, system: String? = nil,
         feature: String? = nil, peakDbz: Double? = nil, areaKm2: Double? = nil, seedDbz: Double? = nil,
         scannedAt: String? = nil, oldestScanAt: String? = nil, sites: [String]? = nil, bytes: Int? = nil) {
        (self.path, self.code, self.lon, self.lat, self.referenceTime, self.coverage) = (path, code, lon, lat, referenceTime, coverage)
        (self.network, self.tier, self.tile, self.coarse, self.system, self.feature) = (network, tier, tile, coarse, system, feature)
        (self.peakDbz, self.areaKm2, self.seedDbz, self.scannedAt, self.oldestScanAt) = (peakDbz, areaKm2, seedDbz, scannedAt, oldestScanAt)
        (self.sites, self.bytes) = (sites, bytes)
    }

    var isCoarse: Bool { coarse == true }
    var openable: Bool { (tier ?? 2) != 1 }
    /// The network it was found in; volumes from before networks were recorded are DWD's.
    var networkCode: String { network.flatMap { $0.isEmpty ? nil : $0 } ?? "de" }
    var mapTile: MapTile? { tile.flatMap { $0.count == 3 ? MapTile($0[0], $0[1], $0[2]) : nil } }

    /// Its 3D texture's bytes before it has loaded (core's `textureBytes`).
    var textureBytes: Int {
        guard let tile, tile.count == 3 else { return 160 * 160 * 32 * 2 }
        return tile[0] == 10 ? 106 * 106 * 32 * 2 : 54 * 54 * 32 * 2
    }

    static func decodeList(_ data: Data) -> CloudList? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(CloudList.self, from: data)
    }
}

/// `CurrentVolumes`.
struct CloudList: Decodable, Sendable {
    let referenceTime: String?
    let volumes: [CloudEntry]?
}

/// The 3D map's constants (core's `cellVolumeLayer.ts`, `Cells3DCapability.ts`).
enum CloudRules {
    static let dbzLow = 20.0
    static let peelBand = 14.0
    static let peelMinPx = 64.0
    static let peelSeconds = 10.0
    static let opacityPerKm = 0.62
    static let solidKm2Min = 4.0
    static let viewPitch = 55.0
    static let steps = 128.0
    static let stepsVoxels = 160.0
    static let peelFPS = 12.0
    static let peelIdleSeconds = 30.0
    static let cutReachKm = 40.0
    static let dimUnopenable = 0.45
    /// Bytes of volume texture held at once (`RESIDENT_BYTES`).
    static let residentBytes = 24 * 160 * 160 * 32 * 2
    /// Coarse tiles turn fine above this size on screen, back below the other.
    static let fineAbovePx = 384.0
    static let coarseBelowPx = 288.0
    static let viewMargin = 0.35
    static let volumeFetches = 4
    static let coarseZoom = 9
    /// What a storm's footprint is measured above when its entry does not say (`STORM_DBZ`).
    static let stormDbz = 25.0
    static let framingDbz = 20.0
    static let minHalfKm = 4.0
    /// The worker's `volume_seed_dbz`, which tiles of one storm are joined above.
    static let seedDbz = 25.0
}

// MARK: - What a volume holds

/// Where the storm stands inside its box (core's `StormExtent`).
struct StormExtent: Equatable, Sendable {
    /// Its middle, km from the box's centre; z from the box's vertical middle.
    var centreKm: SIMD3<Double>
    /// Half its size on each axis, km.
    var halfKm: SIMD3<Double>
}

/// Where echo reaches a tile's sides, one flag per voxel, in map order
/// (core's `TileEdges`, `lib/tileStorms.ts`).
struct TileEdges: Equatable, Sendable {
    var north: [UInt8]
    var south: [UInt8]
    var west: [UInt8]
    var east: [UInt8]
}

/// A loaded volume and what the map works out from it once, off the main
/// thread: where its storm is, how solid it would draw, its peak, its edges.
struct CloudVolume: Sendable {
    let volume: StormVolume
    let extent: StormExtent
    let solidKm2: Double
    let edges: TileEdges?
    let peakDbz: Double

    var header: StormVolume.Header { volume.header }
    var isFaint: Bool { solidKm2 < CloudRules.solidKm2Min }

    init(volume: StormVolume, extent: StormExtent, solidKm2: Double, edges: TileEdges?, peakDbz: Double) {
        (self.volume, self.extent, self.solidKm2, self.edges, self.peakDbz) = (volume, extent, solidKm2, edges, peakDbz)
    }

    init(_ volume: StormVolume, stormDbz: Double = CloudRules.stormDbz) {
        self.volume = volume
        extent = CloudMath.locateStorm(volume, stormDbz: stormDbz)
        solidKm2 = CloudMath.solidKm2(volume)
        edges = CloudMath.tileEdges(volume)
        peakDbz = CloudMath.peakDbz(volume)
    }

    /// The drawn part's size in metres: the tile itself, without its apron.
    var drawnExtentM: SIMD3<Double> {
        let min = SIMD3<Double>(volume.drawnMin), max = SIMD3<Double>(volume.drawnMax)
        return volume.extentM * (max - min)
    }

    /// The unit cube onto the ground the storm is over (core's `modelFor`):
    /// negative on y because Mercator's y runs south, and stretched upwards
    /// as the terrain is.
    var model: simd_double4x4 { CloudMath.model(lon: header.lon, lat: header.lat, extentM: volume.extentM) }
}

/// core's volume arithmetic: `locateStorm` (`lib/stormFrame.ts`),
/// `solidKm2` and the cut (`layers/cellVolumeLayer.ts`), `tileEdges` and
/// `stormsOf` (`lib/tileStorms.ts`).
///
/// No app dependencies here: `scripts/check.sh` compiles this file alone.
enum CloudMath {
    static func model(lon: Double, lat: Double, extentM: SIMD3<Double>) -> simd_double4x4 {
        let c = Mercator.point(lon: lon, lat: lat)
        let metre = Mercator.metre(atLatitude: lat)
        let sx = extentM.x * metre, sy = extentM.y * metre, sz = extentM.z * metre * Mercator.verticalScale
        return simd_double4x4(columns: (SIMD4(sx, 0, 0, 0), SIMD4(0, -sy, 0, 0), SIMD4(0, 0, sz, 0),
                                        SIMD4(c.x - sx / 2, c.y + sy / 2, 0, 1)))
    }

    /// Find the storm inside the box: the connected footprint above
    /// `stormDbz` in the column maximum nearest the box's centre; else
    /// everything above 20 dBZ; else the whole box.
    static func locateStorm(_ volume: StormVolume, stormDbz: Double = CloudRules.stormDbz) -> StormExtent {
        let h = volume.header
        let nx = h.nx, ny = h.ny, nz = h.nz
        let columns = nx * ny
        let toByte = { (dbz: Double) in (dbz - h.dbzFloor) * h.dbzScale }
        let edge = toByte(min(CloudRules.framingDbz, stormDbz))
        var strongest = [Int16](repeating: -1, count: columns)
        volume.voxels.withUnsafeBytes { raw in
            let v = raw.bindMemory(to: UInt8.self)
            for z in 0 ..< nz {
                for column in 0 ..< columns {
                    let at = (z * columns + column) * 2
                    if v[at + 1] != 0, Int16(v[at]) > strongest[column] { strongest[column] = Int16(v[at]) }
                }
            }
        }
        guard let footprint = stormFootprint(strongest, nx: nx, ny: ny, floor: toByte(stormDbz)) ?? anyAbove(strongest, floor: edge) else {
            return StormExtent(centreKm: .zero,
                               halfKm: SIMD3(Double(nx) * h.stepM[0] / 2000, Double(ny) * h.stepM[1] / 2000, Double(nz) * h.stepM[2] / 2000))
        }
        var minX = nx, minY = ny, minZ = nz, maxX = -1, maxY = -1, maxZ = -1
        volume.voxels.withUnsafeBytes { raw in
            let v = raw.bindMemory(to: UInt8.self)
            for column in 0 ..< columns where footprint[column] {
                let x = column % nx, y = column / nx
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                for z in 0 ..< nz {
                    let at = (z * columns + column) * 2
                    if Double(v[at]) < edge || v[at + 1] == 0 { continue }
                    minZ = min(minZ, z); maxZ = max(maxZ, z)
                }
            }
        }
        func span(_ lo: Int, _ hi: Int, _ count: Int, _ step: Double) -> (Double, Double) {
            let low = (Double(lo) + 0.5 - Double(count) / 2) * (step / 1000)
            let high = (Double(hi) + 0.5 - Double(count) / 2) * (step / 1000)
            return ((low + high) / 2, max((high - low) / 2, CloudRules.minHalfKm))
        }
        let (cx, hx) = span(minX, maxX, nx, h.stepM[0])
        let (cy, hy) = span(minY, maxY, ny, h.stepM[1])
        let (cz, hz) = span(minZ, maxZ, nz, h.stepM[2])
        return StormExtent(centreKm: SIMD3(cx, cy, cz), halfKm: SIMD3(hx, hy, hz))
    }

    private static func stormFootprint(_ strongest: [Int16], nx: Int, ny: Int, floor: Double) -> [Bool]? {
        var seed = -1
        var nearest = Double.infinity
        for column in 0 ..< strongest.count where strongest[column] >= 0 && Double(strongest[column]) >= floor {
            let x = column % nx, y = column / nx
            let distance = pow(Double(x) + 0.5 - Double(nx) / 2, 2) + pow(Double(y) + 0.5 - Double(ny) / 2, 2)
            if distance < nearest {
                nearest = distance
                seed = column
            }
        }
        guard seed >= 0 else { return nil }
        var inside = [Bool](repeating: false, count: strongest.count)
        var queue = [seed]
        inside[seed] = true
        var head = 0
        while head < queue.count {
            let column = queue[head]
            head += 1
            let x = column % nx, y = column / nx
            for dy in -1 ... 1 {
                let ty = y + dy
                guard ty >= 0, ty < ny else { continue }
                for dx in -1 ... 1 {
                    let tx = x + dx
                    guard tx >= 0, tx < nx else { continue }
                    let next = ty * nx + tx
                    if inside[next] || strongest[next] < 0 || Double(strongest[next]) < floor { continue }
                    inside[next] = true
                    queue.append(next)
                }
            }
        }
        return inside
    }

    private static func anyAbove(_ strongest: [Int16], floor: Double) -> [Bool]? {
        var any = false
        let inside = strongest.map { value -> Bool in
            let yes = value >= 0 && Double(value) >= floor
            if yes { any = true }
            return yes
        }
        return any ? inside : nil
    }

    /// The area of the storm's silhouette at least half opaque, km², seen at
    /// the map's opening tilt from the south or the west, whichever shows
    /// more (`solidKm2`). Under `solidKm2Min` a volume is faint.
    static func solidKm2(_ volume: StormVolume) -> Double {
        let h = volume.header
        let nx = h.nx, ny = h.ny, nz = h.nz
        let sx = h.stepM[0] / 1000, sy = h.stepM[1] / 1000, sz = h.stepM[2] / 1000
        let tilt = CloudRules.viewPitch * .pi / 180
        let cosT = cos(tilt), sinT = sin(tilt)
        let bin = min(sx, sy)
        var perVoxel = [Float](repeating: 0, count: 256)
        for byte in 0 ..< 256 {
            let t = min(max((Double(byte) / h.dbzScale + h.dbzFloor - CloudRules.dbzLow) / CloudRules.peelBand, 0), 1)
            perVoxel[byte] = Float(t * t * (3 - 2 * t) * CloudRules.opacityPerKm * sx * sy * sz / (bin * bin * 255))
        }
        let wideX = Int(ceil(Double(nx) * sx / bin)), wideY = Int(ceil(Double(ny) * sy / bin))
        var fromSouth = [Float](repeating: 0, count: wideX * (Int(ceil((Double(ny) * sy * cosT + Double(nz) * sz * sinT) / bin)) + 1))
        var fromWest = [Float](repeating: 0, count: wideY * (Int(ceil((Double(nx) * sx * cosT + Double(nz) * sz * sinT) / bin)) + 1))
        volume.voxels.withUnsafeBytes { raw in
            let v = raw.bindMemory(to: UInt8.self)
            var at = 0
            for z in 0 ..< nz {
                let up = (Double(z) + 0.5) * sz * sinT
                for y in 0 ..< ny {
                    let rowY = Int(((Double(y) + 0.5) * sy * cosT + up) / bin)
                    let acrossY = Int(((Double(y) + 0.5) * sy) / bin)
                    for x in 0 ..< nx {
                        let depth = perVoxel[Int(v[at])] * Float(v[at + 1])
                        at += 2
                        if depth == 0 { continue }
                        fromSouth[rowY * wideX + Int(((Double(x) + 0.5) * sx) / bin)] += depth
                        fromWest[Int(((Double(x) + 0.5) * sx * cosT + up) / bin) * wideY + acrossY] += depth
                    }
                }
            }
        }
        let ln2 = Float(M_LN2)
        let solid = { (depths: [Float]) in Double(depths.reduce(0) { $1 >= ln2 ? $0 + 1 : $0 }) * bin * bin }
        return max(solid(fromSouth), solid(fromWest))
    }

    /// The strongest reflectivity the radars saw in the box (`peakDbz`, `cloudHistory.ts`).
    static func peakDbz(_ volume: StormVolume) -> Double {
        var strongest: UInt8 = 0
        volume.voxels.withUnsafeBytes { raw in
            let v = raw.bindMemory(to: UInt8.self)
            var at = 0
            while at < v.count {
                if v[at + 1] != 0, v[at] > strongest { strongest = v[at] }
                at += 2
            }
        }
        return Double(strongest) / volume.header.dbzScale + volume.header.dbzFloor
    }

    // MARK: Tiles of one storm

    /// A tile's edges, as far as its own storm (the echo joined to its
    /// strongest column) reaches them; nil before tiles.
    static func tileEdges(_ volume: StormVolume) -> TileEdges? {
        let h = volume.header
        guard h.tile != nil else { return nil }
        let nx = h.nx, ny = h.ny, nz = h.nz
        let apron = h.apron.flatMap { $0.count == 3 ? $0 : nil } ?? [0, 0, 0]
        let ax = apron[0], ay = apron[1]
        let width = nx - 2 * ax, height = ny - 2 * ay
        guard width > 0, height > 0 else { return nil }
        var strongest = [Int16](repeating: -1, count: width * height)
        volume.voxels.withUnsafeBytes { raw in
            let v = raw.bindMemory(to: UInt8.self)
            var at = 0
            for _ in 0 ..< nz {
                for y in 0 ..< ny {
                    for x in 0 ..< nx {
                        defer { at += 2 }
                        if x < ax || x >= nx - ax || y < ay || y >= ny - ay || v[at + 1] == 0 { continue }
                        let column = (y - ay) * width + (x - ax)
                        if Int16(v[at]) > strongest[column] { strongest[column] = Int16(v[at]) }
                    }
                }
            }
        }
        let seed = Int16(clamping: Int(ceil((CloudRules.seedDbz - h.dbzFloor) * h.dbzScale)))
        var peak = 0
        for column in 1 ..< strongest.count where strongest[column] > strongest[peak] { peak = column }
        var storm = [UInt8](repeating: 0, count: width * height)
        var queue = strongest[peak] >= seed ? [peak] : []
        if !queue.isEmpty { storm[peak] = 1 }
        while let column = queue.popLast() {
            let x = column % width, y = column / width
            for (nextX, nextY) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                guard nextX >= 0, nextX < width, nextY >= 0, nextY < height else { continue }
                let next = nextY * width + nextX
                if storm[next] != 0 || strongest[next] < seed { continue }
                storm[next] = 1
                queue.append(next)
            }
        }
        let across = { (y: Int) in Array(storm[(y * width) ..< ((y + 1) * width)]) }
        let down = { (x: Int) in (0 ..< height).map { storm[(height - 1 - $0) * width + x] } }
        return TileEdges(north: across(height - 1), south: across(0), west: down(0), east: down(width - 1))
    }

    /// A tile on the map, for `stormsOf`.
    struct StormTile: Sendable {
        var network: String?
        var tile: [Int]?
        var system: String?
        var edges: TileEdges?
    }

    private static func meets(_ a: [UInt8], _ aStart: Double, _ aSize: Double, _ b: [UInt8], _ bStart: Double, _ bSize: Double,
                              _ from: Double, _ to: Double) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        func at(_ side: [UInt8], _ start: Double, _ size: Double, _ whereAt: Double) -> Int {
            min(max(Int(floor((whereAt - start) / size * Double(side.count))), 0), side.count - 1)
        }
        let step = min(aSize / Double(a.count), bSize / Double(b.count)) / 2
        var position = from + step / 2
        while position < to {
            let i = at(a, aStart, aSize, position), j = at(b, bStart, bSize, position)
            if a[i] != 0 && (b[j] != 0 || b[max(j - 1, 0)] != 0 || b[min(j + 1, b.count - 1)] != 0) { return true }
            position += step
        }
        return false
    }

    private static func joined(_ a: StormTile, _ b: StormTile) -> Bool {
        guard let at = a.tile, let bt = b.tile, at.count == 3, bt.count == 3, let ae = a.edges, let be = b.edges,
              a.network == b.network else { return false }
        func square(_ t: [Int]) -> (west: Double, north: Double, east: Double, south: Double, size: Double) {
            let size = pow(2, -Double(t[0]))
            return (Double(t[1]) * size, Double(t[2]) * size, Double(t[1] + 1) * size, Double(t[2] + 1) * size, size)
        }
        let p = square(at), q = square(bt)
        let top = max(p.north, q.north), bottom = min(p.south, q.south)
        let left = max(p.west, q.west), right = min(p.east, q.east)
        if p.east == q.west && top < bottom { return meets(ae.east, p.north, p.size, be.west, q.north, q.size, top, bottom) }
        if q.east == p.west && top < bottom { return meets(ae.west, p.north, p.size, be.east, q.north, q.size, top, bottom) }
        if p.south == q.north && left < right { return meets(ae.south, p.west, p.size, be.north, q.west, q.size, left, right) }
        if q.south == p.north && left < right { return meets(ae.north, p.west, p.size, be.south, q.west, q.size, left, right) }
        return false
    }

    /// Each tile's storm by its key: the list's `system`, else the storm of
    /// the tiles its echo runs into across a seam, else one named after it.
    static func stormsOf(_ tiles: [(String, StormTile)]) -> [String: String] {
        var parent = Array(tiles.indices)
        func root(_ index: Int) -> Int {
            var i = index
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        var named: [String: Int] = [:]
        for (i, entry) in tiles.enumerated() {
            guard let system = entry.1.system else { continue }
            if let first = named[system] { parent[root(i)] = root(first) } else { named[system] = i }
        }
        for i in tiles.indices {
            for j in (i + 1) ..< tiles.count {
                let a = tiles[i].1, b = tiles[j].1
                if a.system != nil && b.system != nil { continue }
                let ri = root(i), rj = root(j)
                if ri == rj { continue }
                if let si = tiles[ri].1.system, let sj = tiles[rj].1.system, si != sj { continue }
                if !joined(a, b) { continue }
                if tiles[ri].1.system != nil { parent[rj] = ri } else { parent[ri] = rj }
            }
        }
        var out: [String: String] = [:]
        for (i, entry) in tiles.enumerated() {
            let r = root(i)
            out[entry.0] = entry.1.system ?? tiles[r].1.system ?? "~\(tiles[r].0)"
        }
        return out
    }

    /// Each storm's peel floor by key: the strongest `coreDbz` among the
    /// tiles of one storm that peel, so they peel as one cloud (`peelFloors`).
    static func peelFloors(_ clouds: [(key: String, system: String?, coreDbz: Double, peels: Bool)]) -> [String: Double] {
        var storms: [String: Double] = [:]
        for cloud in clouds where cloud.peels {
            let storm = cloud.system ?? cloud.key
            storms[storm] = max(storms[storm] ?? CloudRules.dbzLow, cloud.coreDbz)
        }
        var out: [String: Double] = [:]
        for cloud in clouds { out[cloud.key] = cloud.peels ? storms[cloud.system ?? cloud.key]! : CloudRules.dbzLow }
        return out
    }

    /// How far through its peel a storm is: 0 whole, 1 down to its core.
    static func peelAt(_ seconds: Double) -> Double {
        let t = (seconds / CloudRules.peelSeconds).truncatingRemainder(dividingBy: 1)
        let rise = min(max((t - 0.1) / 0.35, 0), 1)
        let fall = min(max((t - 0.6) / 0.35, 0), 1)
        let eased = { (x: Double) in x * x * (3 - 2 * x) }
        return eased(rise) - eased(fall)
    }

    // MARK: The cut

    /// Where the cut passes through the opened tile: through the storm, as
    /// Mercator x and y and a height in its cube scaled to the map.
    static func cutPoint(model: simd_double4x4, extentM: SIMD3<Double>, centreKm: SIMD3<Double>) -> SIMD3<Double> {
        let u = 0.5 + centreKm.x / (extentM.x / 1000)
        let v = 0.5 + centreKm.y / (extentM.y / 1000)
        return SIMD3(model.columns.3.x + model.columns.0.x * u, model.columns.3.y + model.columns.1.y * v,
                     (centreKm.z / (extentM.z / 1000)) * model.columns.2.z)
    }

    /// The opened tile's plane, carried into another cloud's own cube.
    static func carryCut(model: simd_double4x4, opened: simd_double4x4, point: SIMD3<Double>, along: Double)
        -> (normal: SIMD3<Double>, point: SIMD3<Double>) {
        (SIMD3(cos(along) * model.columns.0.x / opened.columns.0.x, -sin(along) * model.columns.1.y / opened.columns.1.y, 0),
         SIMD3((point.x - model.columns.3.x) / model.columns.0.x, (point.y - model.columns.3.y) / model.columns.1.y,
               point.z / model.columns.2.z))
    }

    /// How far a cloud's drawn box stands from the cut on the ground, km.
    static func kmFromCut(model: simd_double4x4, boxMin: SIMD3<Double>, boxMax: SIMD3<Double>, point: SIMD3<Double>,
                          metre: Double) -> Double {
        let xs = [model.columns.3.x + model.columns.0.x * boxMin.x, model.columns.3.x + model.columns.0.x * boxMax.x]
        let ys = [model.columns.3.y + model.columns.1.y * boxMin.y, model.columns.3.y + model.columns.1.y * boxMax.y]
        let dx = max(xs.min()! - point.x, 0, point.x - xs.max()!)
        let dy = max(ys.min()! - point.y, 0, point.y - ys.max()!)
        return hypot(dx, dy) / metre / 1000
    }

    /// Whether every corner of a box lies on the side of a cut that is gone.
    static func cutAway(boxMin: SIMD3<Double>, boxMax: SIMD3<Double>, normal: SIMD3<Double>, point: SIMD3<Double>) -> Bool {
        for corner in 0 ..< 8 {
            let c = SIMD3(corner & 1 == 0 ? boxMin.x : boxMax.x, corner & 2 == 0 ? boxMin.y : boxMax.y,
                          corner & 4 == 0 ? boxMin.z : boxMax.z)
            if simd_dot(normal, c - point) <= 0 { return false }
        }
        return true
    }

    /// A slice angle folded into [-180, 180) (`normaliseCut`).
    static func normaliseCut(_ degrees: Double) -> Double {
        let folded = ((degrees + 180).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) - 180
        return folded == 0 ? 0 : folded
    }

    /// What the dial's caption says (`cutLabel`): by the angle to the track,
    /// or to north for a storm with no track. `t` is core's translate.
    static func cutLabel(_ degrees: Double, track: Bool, _ t: (String, [String: Any]) -> String) -> String {
        let off = abs(normaliseCut(degrees))
        let toAxis = min(off, 180 - off)
        if !track {
            if toAxis < 1 { return t("storm.cut.north_south", [:]) }
            if abs(toAxis - 90) < 1 { return t("storm.cut.east_west", [:]) }
            return t("storm.cut.off_north", ["deg": Int(toAxis.rounded())])
        }
        if toAxis < 1 { return t("storm.cut.along", [:]) }
        if abs(toAxis - 90) < 1 { return t("storm.cut.across", [:]) }
        return t("storm.cut.off_track", ["deg": Int(toAxis.rounded())])
    }
}

// MARK: - Tiles and levels

/// core's `lib/volumeBox.ts`, `lib/volumeLevels.ts`, `lib/cloudFootprint.ts`.
enum CloudTiles {
    /// `T`, the zoom in two digits, x and y in five.
    static func code(_ z: Int, _ x: Int, _ y: Int) -> String {
        "T" + String(format: "%02d%05d%05d", z, x, y)
    }

    /// A tile's middle in Mercator: where a box filling it is centred.
    static func centre(_ z: Int, _ x: Int, _ y: Int) -> (lon: Double, lat: Double) {
        let n = pow(2, Double(z))
        return ((Double(x) + 0.5) / n * 360 - 180, atan(sinh(.pi * (1 - 2 * (Double(y) + 0.5) / n))) * 180 / .pi)
    }

    /// West, south, east, north.
    static func bounds(_ z: Int, _ x: Int, _ y: Int) -> (west: Double, south: Double, east: Double, north: Double) {
        let n = pow(2, Double(z))
        let lat = { (row: Double) in atan(sinh(.pi * (1 - 2 * row / n))) * 180 / .pi }
        return (Double(x) / n * 360 - 180, lat(Double(y + 1)), Double(x + 1) / n * 360 - 180, lat(Double(y)))
    }

    /// The tile a point stands in at zoom `z`.
    static func at(lon: Double, lat: Double, z: Int) -> (x: Int, y: Int) {
        let n = pow(2, Double(z))
        let x = Int(floor((lon + 180) / 360 * n))
        let y = Int(floor((1 - asinh(tan(lat * .pi / 180)) / .pi) / 2 * n))
        let top = Int(n) - 1
        return (min(max(x, 0), top), min(max(y, 0), top))
    }

    /// The finest listed tile, not a coarse one, a point stands in: what a
    /// tap on a coarse tile opens.
    static func fineAt(_ clouds: [CloudEntry], lon: Double, lat: Double) -> CloudEntry? {
        for z in [11, 10] {
            let (x, y) = at(lon: lon, lat: lat, z: z)
            if let found = clouds.first(where: { !$0.isCoarse && $0.tile == [z, x, y] }) { return found }
        }
        return nil
    }

    private static func coarseKey(_ tile: [Int]) -> String? {
        guard tile.count == 3 else { return nil }
        let shift = tile[0] - CloudRules.coarseZoom
        return shift >= 0 ? "\(tile[1] >> shift)/\(tile[2] >> shift)" : nil
    }

    /// The volumes to draw: each coarse tile where `coarse` says so, in
    /// place of the tiles in it; the open volume always, its coarse tile not.
    static func atLevel(_ clouds: [CloudEntry], coarse: ([Int]) -> Bool, openPath: String? = nil) -> [CloudEntry] {
        let fine = clouds.filter { !$0.isCoarse }
        let open = openPath.flatMap { path in clouds.first { $0.path == path && !$0.isCoarse } }
        let openKey = open?.tile.flatMap(coarseKey)
        let parents = clouds.filter { cloud in
            guard cloud.isCoarse, let tile = cloud.tile else { return false }
            return coarseKey(tile) != openKey && coarse(tile)
        }
        let covered = Set(parents.compactMap { $0.tile.flatMap(coarseKey) })
        return parents + fine.filter { cloud in
            guard let tile = cloud.tile, let key = coarseKey(tile) else { return true }
            return !covered.contains(key) || cloud.path == openPath
        }
    }

    /// A zoom-`z` tile's width at a latitude, in MapLibre's metres.
    static func widthM(_ z: Int, lat: Double) -> Double {
        Mercator.circumference * cos(lat * .pi / 180) / pow(2, Double(z))
    }

    /// The square in Mercator around a box's centre, and the cut's spin axis
    /// on the ground (`boxFootprint`): SW, SE, NE, NW, SW as [lon, lat].
    static func footprint(lon: Double, lat: Double, extentM: SIMD2<Double> = SIMD2(40_000, 40_000),
                          centreKm: SIMD2<Double> = .zero) -> (ring: [SIMD2<Double>], pivot: SIMD2<Double>) {
        let x = Mercator.x(lon), y = Mercator.y(lat)
        let metre = Mercator.metre(atLatitude: lat)
        let halfX = extentM.x / 2 * metre, halfY = extentM.y / 2 * metre
        let at = { (dx: Double, dy: Double) in SIMD2(Mercator.lon(x + dx), Mercator.lat(y - dy)) }
        return ([at(-halfX, -halfY), at(halfX, -halfY), at(halfX, halfY), at(-halfX, halfY), at(-halfX, -halfY)],
                at(centreKm.x * 1000 * metre, centreKm.y * 1000 * metre))
    }

    /// One storm's strongest tile, by its `system` (`onePerStorm`, `layers/cloudHints.ts`).
    static func onePerStorm(_ clouds: [CloudEntry]) -> [CloudEntry] {
        var strongest: [String: CloudEntry] = [:]
        for cloud in clouds {
            let storm = cloud.system ?? cloud.path
            if let held = strongest[storm], (cloud.peakDbz ?? 0) <= (held.peakDbz ?? 0) { continue }
            strongest[storm] = cloud
        }
        let kept = Set(strongest.values.map(\.path))
        return clouds.filter { kept.contains($0.path) }
    }
}

// MARK: - Scans

/// core's `lib/scans.ts` and `lib/cloudSuccession.ts`.
enum CloudScans {
    // ISO8601DateFormatter is thread-safe.
    nonisolated(unsafe) private static let iso = ISO8601DateFormatter()
    nonisolated(unsafe) private static let isoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// An ISO time as a scan, epoch seconds.
    static func scanTime(_ value: String?) -> Int? {
        guard let value, let date = iso.date(from: value) ?? isoFraction.date(from: value) else { return nil }
        return Int(floor(date.timeIntervalSince1970))
    }

    static func isBehind(_ scan: Int?, radar: Int?) -> Bool {
        guard let scan, let radar else { return false }
        return scan < radar
    }

    /// Whether a volume is past its scan: not listed, and the list holds a
    /// newer scan of its network.
    static func isPastItsScan(path: String, network: String?, referenceTime: String?, listed: [CloudEntry]) -> Bool {
        if listed.contains(where: { $0.path == path }) { return false }
        guard let scan = scanTime(referenceTime) else { return false }
        let net = network.flatMap { $0.isEmpty ? nil : $0 } ?? "de"
        return listed.contains { $0.networkCode == net && (scanTime($0.referenceTime) ?? .min) > scan }
    }

    /// A storm's footprint as [west, south, east, north] km from `origin`.
    static func footprintKm(_ cloud: CloudVolume, origin: (lon: Double, lat: Double)) -> SIMD4<Double> {
        let h = cloud.header, c = cloud.extent
        let east = (h.lon - origin.lon) * 111.32 * cos(origin.lat * .pi / 180) + c.centreKm.x
        let north = (h.lat - origin.lat) * 111.32 + c.centreKm.y
        return SIMD4(east - c.halfKm.x, north - c.halfKm.y, east + c.halfKm.x, north + c.halfKm.y)
    }

    /// Whether `later` is, most likely, `earlier` as a later scan saw it.
    static func isSuccessor(_ earlier: CloudVolume, _ later: CloudVolume) -> Bool {
        let origin = (earlier.header.lon, earlier.header.lat)
        let a = footprintKm(earlier, origin: origin), b = footprintKm(later, origin: origin)
        let across = min(a[2], b[2]) - max(a[0], b[0])
        let up = min(a[3], b[3]) - max(a[1], b[1])
        guard across > 0, up > 0 else { return false }
        let smaller = min((a[2] - a[0]) * (a[3] - a[1]), (b[2] - b[0]) * (b[3] - b[1]))
        return smaller > 0 && across * up / smaller >= 0.3
    }

    /// Whether an answer may replace the last one passed on: no older than it (`VolumeFeed.offer`).
    static func offers(_ answer: Int?, after newest: Int?) -> Bool {
        guard let answer, let newest else { return true }
        return answer >= newest
    }
}
