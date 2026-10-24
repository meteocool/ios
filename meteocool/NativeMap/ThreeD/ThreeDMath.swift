//
//  ThreeDMath.swift
//  meteocool
//
//  Web Mercator and 4x4 matrices for the 3D storm map, as MapLibre does them.
//

import Foundation
import simd

/// MapLibre's Mercator world: x east and y south, 0 to 1 across the world
/// (`MercatorCoordinate`), on its sphere of 6,371,008.8 m (core's
/// `lib/cloudFootprint.ts`, `lib/volumeBox.ts`).
///
/// No app dependencies here: `scripts/check.sh` compiles this file alone.
enum Mercator {
    /// MapLibre's earth radius, so a metre here is the metre its Mercator coordinates use.
    static let earthRadius = 6_371_008.8
    static let circumference = 2 * Double.pi * earthRadius
    /// How much taller than life the 3D map draws heights: storms, cells and
    /// ground alike (core's `VERTICAL_SCALE`, `layers/terrain.ts`).
    static let verticalScale = 1.5

    static func x(_ lon: Double) -> Double { (180 + lon) / 360 }

    static func y(_ lat: Double) -> Double {
        (180 - (180 / .pi) * log(tan(.pi / 4 + lat * .pi / 360))) / 360
    }

    static func lon(_ x: Double) -> Double { x * 360 - 180 }

    static func lat(_ y: Double) -> Double {
        (360 / .pi) * atan(exp((180 - y * 360) * .pi / 180)) - 90
    }

    /// Mercator units in one metre at a latitude (`meterInMercatorCoordinateUnits`).
    static func metre(atLatitude lat: Double) -> Double {
        1 / (circumference * cos(lat * .pi / 180))
    }

    /// The point, in Mercator units.
    static func point(lon: Double, lat: Double) -> SIMD2<Double> { SIMD2(x(lon), y(lat)) }
}

/// A zoom-`z` map tile: x from the west, y from the north (XYZ).
struct MapTile: Hashable, Sendable, CustomStringConvertible {
    let z: Int
    let x: Int
    let y: Int

    init(_ z: Int, _ x: Int, _ y: Int) {
        (self.z, self.x, self.y) = (z, x, y)
    }

    var description: String { "\(z)/\(x)/\(y)" }

    /// Its side in Mercator units.
    var size: Double { 1 / Double(1 << z) }
    /// Its north-west corner in Mercator units.
    var origin: SIMD2<Double> { SIMD2(Double(x) * size, Double(y) * size) }

    var parent: MapTile? { z > 0 ? MapTile(z - 1, x >> 1, y >> 1) : nil }

    /// The ancestor at zoom `zoom` (itself when as deep or deeper).
    func ancestor(at zoom: Int) -> MapTile {
        guard zoom < z else { return self }
        let shift = z - zoom
        return MapTile(zoom, x >> shift, y >> shift)
    }

    var children: [MapTile] {
        [MapTile(z + 1, 2 * x, 2 * y), MapTile(z + 1, 2 * x + 1, 2 * y),
         MapTile(z + 1, 2 * x, 2 * y + 1), MapTile(z + 1, 2 * x + 1, 2 * y + 1)]
    }

    /// Where this tile lies inside `ancestor`, as an offset and a scale of
    /// the ancestor's unit square: what to sample of an ancestor's texture.
    func rect(in ancestor: MapTile) -> SIMD4<Float> {
        let scale = Double(1 << (z - ancestor.z))
        let dx = Double(x) - Double(ancestor.x) * scale
        let dy = Double(y) - Double(ancestor.y) * scale
        return SIMD4(Float(dx / scale), Float(dy / scale), Float(1 / scale), Float(1 / scale))
    }

    /// Its latitude at the middle, north edge and south edge.
    var centreLatitude: Double { Mercator.lat((Double(y) + 0.5) * size) }
    var northLatitude: Double { Mercator.lat(Double(y) * size) }
    var southLatitude: Double { Mercator.lat(Double(y + 1) * size) }
}

/// Column-major 4x4 matrices in the layout gl-matrix uses (`mat4.scale`,
/// `translate`, `rotateX`… all post-multiply), so MapLibre's transform ports line for line.
enum Matrix {
    static let identity = matrix_identity_double4x4

    static func scale(_ m: simd_double4x4, _ v: SIMD3<Double>) -> simd_double4x4 {
        m * simd_double4x4(diagonal: SIMD4(v.x, v.y, v.z, 1))
    }

    static func translate(_ m: simd_double4x4, _ v: SIMD3<Double>) -> simd_double4x4 {
        var t = matrix_identity_double4x4
        t.columns.3 = SIMD4(v.x, v.y, v.z, 1)
        return m * t
    }

    static func rotateX(_ m: simd_double4x4, _ angle: Double) -> simd_double4x4 {
        let c = cos(angle), s = sin(angle)
        let r = simd_double4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, c, s, 0), SIMD4(0, -s, c, 0), SIMD4(0, 0, 0, 1)))
        return m * r
    }

    static func rotateZ(_ m: simd_double4x4, _ angle: Double) -> simd_double4x4 {
        let c = cos(angle), s = sin(angle)
        let r = simd_double4x4(columns: (SIMD4(c, s, 0, 0), SIMD4(-s, c, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1)))
        return m * r
    }

    /// gl-matrix's `perspective`: OpenGL's clip space, z from -1 to 1.
    static func perspective(fovy: Double, aspect: Double, near: Double, far: Double) -> simd_double4x4 {
        let f = 1 / tan(fovy / 2)
        let nf = 1 / (near - far)
        return simd_double4x4(columns: (
            SIMD4(f / aspect, 0, 0, 0),
            SIMD4(0, f, 0, 0),
            SIMD4(0, 0, (far + near) * nf, -1),
            SIMD4(0, 0, 2 * far * near * nf, 0)))
    }

    /// OpenGL's clip depth (-1 to 1) to Metal's (0 to 1): applied last.
    static let metalDepth = simd_double4x4(columns: (
        SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 0.5, 0), SIMD4(0, 0, 0.5, 1)))

    static func apply(_ m: simd_double4x4, _ p: SIMD3<Double>) -> SIMD4<Double> {
        m * SIMD4(p.x, p.y, p.z, 1)
    }

    /// Single precision, for the GPU, once everything is composed in double.
    static func float(_ m: simd_double4x4) -> simd_float4x4 {
        simd_float4x4(columns: (SIMD4<Float>(m.columns.0), SIMD4<Float>(m.columns.1),
                                SIMD4<Float>(m.columns.2), SIMD4<Float>(m.columns.3)))
    }
}

/// MapLibre's default ease, `bezier(0.25, 0.1, 0.25, 1)` (`util.ts`
/// `defaultEasing`), solved for x as UnitBezier does.
struct UnitBezier: Sendable {
    let cx, bx, ax, cy, by, ay: Double

    init(_ p1x: Double, _ p1y: Double, _ p2x: Double, _ p2y: Double) {
        cx = 3 * p1x
        bx = 3 * (p2x - p1x) - cx
        ax = 1 - cx - bx
        cy = 3 * p1y
        by = 3 * (p2y - p1y) - cy
        ay = 1 - cy - by
    }

    static let ease = UnitBezier(0.25, 0.1, 0.25, 1)
    /// MapLibre's inertia easing (`handler_inertia.ts`).
    static let inertia = UnitBezier(0, 0, 0.3, 1)

    private func sampleX(_ t: Double) -> Double { ((ax * t + bx) * t + cx) * t }
    private func sampleY(_ t: Double) -> Double { ((ay * t + by) * t + cy) * t }
    private func derivativeX(_ t: Double) -> Double { (3 * ax * t + 2 * bx) * t + cx }

    func solve(_ x: Double) -> Double {
        let x = min(max(x, 0), 1)
        var t = x
        for _ in 0 ..< 8 {
            let error = sampleX(t) - x
            if abs(error) < 1e-6 { return sampleY(t) }
            let d = derivativeX(t)
            if abs(d) < 1e-6 { break }
            t -= error / d
        }
        var lo = 0.0, hi = 1.0
        t = x
        while lo < hi {
            let value = sampleX(t)
            if abs(value - x) < 1e-6 { break }
            if x > value { lo = t } else { hi = t }
            t = (hi - lo) / 2 + lo
            if hi - lo < 1e-7 { break }
        }
        return sampleY(t)
    }
}
