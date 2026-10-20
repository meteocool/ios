//
//  CellVolumeModel.swift
//  meteocool
//
//  A KONRAD3D cell as a solid: core's `lib/cellVolume.ts` and
//  `lib/cellExtrusions.ts`. For each reflectivity threshold the radar reports
//  the ground it covers, how high it reaches and the volume it encloses; the
//  volume over the area is a thickness, which places the body and shapes its
//  taper. The cell is then cut into height bands, each an opaque core column
//  and a glass ring around it, so no two pieces overlap.
//
//  No app dependencies here: `scripts/check.sh` compiles this file alone.
//

import Foundation

/// One threshold of a cell, as `/cells/current` sends it (`CellThreshold`).
struct CellThreshold: Decodable, Equatable, Sendable {
    let dbz: Double
    let areaKm2: Double
    let topM: Double
    let volumeKm3: Double?
    /// Its measured outlines, `[lon, lat]`, where the feed has them.
    let rings: [[[Double]]]?
}

enum CellVolumeModel {
    typealias Point = (lon: Double, lat: Double)

    /// One piece of a band: between two scales of the ground outline.
    struct Ring {
        let dbz: Double
        /// Linear factor on the outline for the outer edge, and the inner (0: the core).
        let outer: Double
        let inner: Double
        /// 0 the opaque core column, 1 the glass around it.
        let tier: Int
        let alpha: Double
        /// This threshold's measured outlines, if any.
        let shape: [[Point]]?
    }

    struct Band {
        /// Metres above sea level.
        let base: Double
        let top: Double
        let rings: [Ring]
    }

    struct Model {
        let code: String
        let centre: Point
        /// The ground outline, decimated, not closed.
        let outline: [Point]
        let outlineKm: [(x: Double, y: Double)]
        let outlineAreaKm2: Double
        let bands: [Band]
        let base: Double
        let top: Double
        let radiusKm: Double
    }

    /// What a cell carries into the model.
    struct Input {
        let code: String
        let lon: Double
        let lat: Double
        let echoBottomM: Double?
        let polygon: [[Double]]?
        let structure: [CellThreshold]?
    }

    static let kmPerDegreeLat = 111.32
    static let ringAlphas = [1.0, 0.2]
    static let minBodyM = 300.0
    static let bandM = 600.0
    static let minBands = 4
    static let maxBands = 16
    static let coreShare = 0.05
    static let ringMinWidth = 0.06
    static let wallGap = 0.004
    static let minRingAreaKm2 = 0.05
    static let minRingPoints = 4
    static let maxOutlinePoints = 22
    static let topFraction = 0.05
    static let minFill = 0.1
    static let maxFill = 0.97
    static let maxExponent = 40.0
    static let liftFill = 0.14

    // MARK: Profile

    private static func smoothstep(_ t: Double) -> Double { t * t * (3 - 2 * t) }

    private static func shape(_ u: Double) -> Double {
        if u <= 0 { return 1 }
        if u >= 1 { return topFraction }
        return 1 + (topFraction - 1) * smoothstep(u)
    }

    /// The cross-section at height fraction `u`, as a fraction of the widest.
    static func profile(_ u: Double, exponent: Double) -> Double { pow(shape(u), exponent) }

    private static let samples: [Double] = (0 ..< 160).map { shape((Double($0) + 0.5) / 160) }

    private static func meanFor(_ exponent: Double) -> Double {
        samples.reduce(0) { $0 + pow($1, exponent) } / Double(samples.count)
    }

    nonisolated(unsafe) private static var exponents: [Int: Double] = [:]
    private static let exponentLock = NSLock()

    /// The exponent whose profile averages `wanted` over its height.
    static func exponentForMean(_ wanted: Double) -> Double {
        let key = Int((min(max(wanted, minFill), maxFill) * 200).rounded())
        if let hit = exponentLock.withLock({ exponents[key] }) { return hit }
        let target = Double(key) / 200
        var low = 0.12, high = maxExponent
        let answer: Double
        if target >= meanFor(low) {
            answer = low
        } else if target <= meanFor(high) {
            answer = high
        } else {
            for _ in 0 ..< 16 {
                let mid = (low + high) / 2
                if meanFor(mid) > target { low = mid } else { high = mid }
            }
            answer = (low + high) / 2
        }
        exponentLock.withLock { exponents[key] = answer }
        return answer
    }

    // MARK: Bodies

    struct Body {
        let dbz: Double
        let areaKm2: Double
        let base: Double
        let top: Double
        let exponent: Double
        let shape: [[Point]]?
    }

    private static func measured(_ layer: CellThreshold) -> [[Point]]? {
        let usable = (layer.rings ?? []).filter { $0.count >= minRingPoints }
            .map { $0.compactMap { $0.count >= 2 ? (lon: $0[0], lat: $0[1]) : nil } }
        return usable.isEmpty ? nil : usable
    }

    /// Each threshold's echo as a solid: where it sits and how it tapers.
    static func bodies(_ cell: Input) -> [Body] {
        let raw = (cell.structure ?? []).filter { $0.areaKm2 > 0 && $0.topM > 0 }.sorted { $0.dbz < $1.dbz }
        guard !raw.isEmpty else { return [] }
        // A stronger threshold cannot cover more ground, nor reach higher, than a weaker one.
        var area = Double.infinity, ceiling = Double.infinity
        let nested = raw.map { layer -> (dbz: Double, areaKm2: Double, top: Double, volumeKm3: Double?, shape: [[Point]]?) in
            area = min(area, layer.areaKm2)
            ceiling = min(ceiling, layer.topM)
            return (layer.dbz, area, ceiling, layer.volumeKm3, measured(layer))
        }
        let floor = min(cell.echoBottomM ?? 0, nested[0].top - minBodyM)
        var out: [Body] = []
        for layer in nested {
            let depthM: Double? = (layer.volumeKm3 ?? 0) > 0 && layer.areaKm2 > 0 ? (layer.volumeKm3! / layer.areaKm2) * 1000 : nil
            let rooted = max(layer.top - floor, minBodyM)
            var base = depthM.map { $0 / rooted >= liftFill ? floor : layer.top - $0 / liftFill } ?? floor
            base = max(base, out.last?.base ?? floor)
            base = min(base, layer.top - minBodyM)
            let height = max(layer.top - base, minBodyM)
            let exponent = depthM.map { exponentForMean($0 / height) } ?? 1
            out.append(Body(dbz: layer.dbz, areaKm2: layer.areaKm2, base: base, top: layer.top, exponent: exponent, shape: layer.shape))
        }
        return out
    }

    // MARK: Outline

    static func ellipse(lon: Double, lat: Double, majorKm: Double, minorKm: Double, angleDeg: Double) -> [Point] {
        let bearing = angleDeg * .pi / 180
        let lonScale = kmPerDegreeLat * cos(lat * .pi / 180)
        return (0 ... 36).map { i in
            let t = 2 * Double.pi * Double(i) / 36
            let along = majorKm * cos(t), across = minorKm * sin(t)
            let north = along * cos(bearing) - across * sin(bearing)
            let east = along * sin(bearing) + across * cos(bearing)
            return (lon + east / lonScale, lat + north / kmPerDegreeLat)
        }
    }

    static func footprint(_ cell: Input, areaKm2: Double) -> [Point] {
        guard let polygon = cell.polygon, polygon.count >= 3 else {
            let radius = sqrt(max(areaKm2, 0.1) / .pi)
            return Array(ellipse(lon: cell.lon, lat: cell.lat, majorKm: radius, minorKm: radius, angleDeg: 0).dropLast())
        }
        var ring = polygon.compactMap { $0.count >= 2 ? (lon: $0[0], lat: $0[1]) : nil }
        if ring.count > 3, let a = ring.first, let b = ring.last, a.lon == b.lon, a.lat == b.lat { ring.removeLast() }
        guard ring.count > maxOutlinePoints else { return ring }
        let step = Double(ring.count) / Double(maxOutlinePoints)
        return (0 ..< maxOutlinePoints).map { ring[Int(Double($0) * step)] }
    }

    static func shoelace(_ ring: [(x: Double, y: Double)]) -> Double {
        var sum = 0.0
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }

    static func toLocalKm(_ ring: [Point], centre: Point) -> [(x: Double, y: Double)] {
        let lonScale = kmPerDegreeLat * cos(centre.lat * .pi / 180)
        return ring.map { ((($0.lon - centre.lon) * lonScale), ($0.lat - centre.lat) * kmPerDegreeLat) }
    }

    /// The point rings shrink towards: the cell's centroid, unless it has
    /// drifted outside its own outline.
    static func shrinkCentre(_ cell: Input, outline: [Point]) -> Point {
        let lons = outline.map(\.lon), lats = outline.map(\.lat)
        guard let minLon = lons.min(), let maxLon = lons.max(), let minLat = lats.min(), let maxLat = lats.max() else { return (cell.lon, cell.lat) }
        if cell.lon >= minLon, cell.lon <= maxLon, cell.lat >= minLat, cell.lat <= maxLat { return (cell.lon, cell.lat) }
        return ((minLon + maxLon) / 2, (minLat + maxLat) / 2)
    }

    // MARK: The model

    /// The cell as disjoint bands of rings, or nil without a structure.
    static func model(_ cell: Input) -> Model? {
        let solids = bodies(cell)
        guard let envelopeBody = solids.first else { return nil }
        let outline = footprint(cell, areaKm2: envelopeBody.areaKm2)
        let centre = shrinkCentre(cell, outline: outline)
        let outlineKm = toLocalKm(outline, centre: centre)
        let outlineArea = abs(shoelace(outlineKm))
        guard outlineArea > 0 else { return nil }
        let base = envelopeBody.base, top = envelopeBody.top
        let span = max(top - base, minBodyM)
        let count = min(max(Int((span / bandM).rounded()), minBands), maxBands)
        let height = span / Double(count)
        var bands: [Band] = []
        for k in 0 ..< count {
            let bandBase = base + Double(k) * height, bandTop = bandBase + height
            let middle = bandBase + height / 2
            var widest = Double.infinity
            var stops: [(dbz: Double, scale: Double, shape: [[Point]]?)] = []
            for body in solids where middle > body.base && middle < body.top {
                let area = min(body.areaKm2 * profile((middle - body.base) / (body.top - body.base), exponent: body.exponent), widest)
                widest = area
                if area < minRingAreaKm2 { continue }
                stops.append((body.dbz, sqrt(area / outlineArea), body.shape))
            }
            guard let envelope = stops.first else { continue }
            var core = envelope
            for stop in stops.dropFirst() {
                if stop.scale * stop.scale < envelope.scale * envelope.scale * coreShare { break }
                core = stop
            }
            var rings: [Ring] = []
            let separate = core.dbz != envelope.dbz
            if separate, core.scale < envelope.scale * (1 - ringMinWidth) {
                rings.append(Ring(dbz: envelope.dbz, outer: envelope.scale, inner: core.scale * (1 + wallGap), tier: 1,
                                  alpha: ringAlphas[1], shape: envelope.shape))
            }
            rings.append(Ring(dbz: core.dbz, outer: rings.isEmpty ? envelope.scale : core.scale, inner: 0, tier: 0,
                              alpha: ringAlphas[0], shape: core.shape))
            bands.append(Band(base: bandBase, top: bandTop, rings: rings))
        }
        guard !bands.isEmpty else { return nil }
        let radius = outlineKm.map { hypot($0.x, $0.y) }.max() ?? 0
        return Model(code: cell.code, centre: centre, outline: outline, outlineKm: outlineKm, outlineAreaKm2: outlineArea,
                     bands: bands, base: base, top: top, radiusKm: radius)
    }

    // MARK: Extrusions

    /// One extruded piece: an outer ring (and a hole) between two heights.
    struct Piece {
        let dbz: Double
        let base: Double
        let top: Double
        let tier: Int
        let outer: [Point]
        /// The hole, the outline at a smaller scale; nil for a column.
        let hole: [Point]?
    }

    static let minScale = 0.02

    static func scale(_ ring: [Point], about centre: Point, ratio: Double) -> [Point] {
        let k = sqrt(max(ratio, 0))
        return ring.map { (centre.lon + ($0.lon - centre.lon) * k, centre.lat + ($0.lat - centre.lat) * k) }
    }

    private static func centroid(_ ring: [Point]) -> Point {
        (ring.reduce(0) { $0 + $1.lon } / Double(ring.count), ring.reduce(0) { $0 + $1.lat } / Double(ring.count))
    }

    /// A measured shape resized to the area the profile gives this height
    /// (`resized`): each ring about its own middle.
    static func resized(_ shapes: [[Point]], areaRatio: Double, outlineAreaKm2: Double, centre: Point) -> [[Point]] {
        let measured = shapes.reduce(0) { $0 + abs(shoelace(toLocalKm($1, centre: centre))) }
        guard measured > 0 else { return shapes }
        let ratio = areaRatio * outlineAreaKm2 / measured
        return shapes.map { scale($0, about: centroid($0), ratio: ratio) }
    }

    /// The model's pieces (`cellVolumeFeatures`). The glass around a measured
    /// core keeps the outline's own hole: a strip between two scales of the
    /// same outline is what this draws.
    static func pieces(_ model: Model) -> [Piece] {
        model.bands.flatMap { band in
            band.rings.flatMap { ring -> [Piece] in
                guard ring.outer >= minScale else { return [] }
                if ring.tier == 0, let shape = ring.shape {
                    return resized(shape, areaRatio: ring.outer * ring.outer, outlineAreaKm2: model.outlineAreaKm2, centre: model.centre)
                        .map { Piece(dbz: ring.dbz, base: band.base, top: band.top, tier: 0, outer: $0, hole: nil) }
                }
                let outer = scale(model.outline, about: model.centre, ratio: ring.outer * ring.outer)
                let hole = ring.inner >= minScale && ring.inner < ring.outer
                    ? scale(model.outline, about: model.centre, ratio: ring.inner * ring.inner) : nil
                return [Piece(dbz: ring.dbz, base: band.base, top: band.top, tier: ring.tier, outer: outer, hole: hole)]
            }
        }
    }
}
