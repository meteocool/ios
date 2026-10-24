//
//  CellSolids.swift
//  meteocool
//
//  The 3D map's KONRAD3D cells as solids (core's `cell-volume-0/1` extrusion
//  layers and `cell-footprint`): each piece of `CellVolumeModel` extruded between
//  its band's heights, coloured by its reflectivity, the core opaque and the
//  ring around it glass; and each cell's outline on the ground.
//

import Metal
import simd

@MainActor
final class CellSolids {
    private(set) var current: StormRenderer.Solids?
    private(set) var footprints: [WorldLine] = []
    private var builtFor = ""

    /// Builds again when the cells, the cells hidden by volumes, the scene's
    /// origin or the palette changed.
    func update(cells: [TrackedCell], hidden: Set<String>, scene: StormScene, device: MTLDevice, key: String) {
        let full = key + "|" + hidden.sorted().joined(separator: ",")
        guard full != builtFor else { return }
        builtFor = full
        var opaque: [SolidVertex] = []
        var glass: [SolidVertex] = []
        var lines: [WorldLine] = []
        for cell in cells where !hidden.contains(cell.code) {
            let input = CellVolumeModel.Input(code: cell.code, lon: cell.lon, lat: cell.lat, echoBottomM: cell.echoBottomM,
                                         polygon: cell.polygon, structure: cell.structure)
            guard let model = CellVolumeModel.model(input) else { continue }
            for piece in CellVolumeModel.pieces(model) {
                let rgb = Colormaps.colour(dbz: piece.dbz, palette: scene.palette)
                let alpha = Float(CellVolumeModel.ringAlphas[min(piece.tier, 1)])
                let colour = SIMD4<Float>(Float(rgb.x) / 255, Float(rgb.y) / 255, Float(rgb.z) / 255, alpha)
                if piece.tier == 0 {
                    Self.extrude(piece, scene: scene, colour: colour, into: &opaque)
                } else {
                    Self.extrude(piece, scene: scene, colour: colour, into: &glass)
                }
            }
            // The outline on the ground, in the cell's severity colour.
            if let polygon = cell.polygon, polygon.count >= 3 {
                let rgb = Self.severity[max(0, min(cell.severity ?? 0, 3))]
                let points = polygon.compactMap { $0.count >= 2 ? Self.world(scene, lon: $0[0], lat: $0[1], metres: 30) : nil }
                for (a, b) in zip(points, points.dropFirst() + points.prefix(1)) {
                    lines.append(WorldLine(a: a, b: b, colour: SIMD4(rgb, 0.7), width: 1.2))
                }
            }
        }
        footprints = lines
        let all = opaque + glass
        guard !all.isEmpty, let buffer = device.makeBuffer(bytes: all, length: all.count * MemoryLayout<SolidVertex>.stride) else {
            current = nil
            return
        }
        current = StormRenderer.Solids(vertices: buffer, opaqueCount: opaque.count, glassCount: glass.count,
                                       light: simd_normalize(SIMD3<Float>(-0.4, 0.8, 0.45)))
    }

    /// Severity colours (`layers/cells.ts`).
    static let severity: [SIMD3<Float>] = [
        SIMD3(0x2f, 0x9e, 0x44) / 255, SIMD3(0xf0, 0xb4, 0x29) / 255, SIMD3(0xe0, 0x31, 0x31) / 255, SIMD3(0x9c, 0x36, 0xb5) / 255,
    ]

    /// A point of the scene's world, heights stretched as the storms are.
    private static func world(_ scene: StormScene, lon: Double, lat: Double, metres: Double) -> SIMD3<Float> {
        let w = scene.world(latitude: lat, longitude: lon, altitude: metres * ThreeDScale.vertical)
        return SIMD3(Float(w.x), Float(w.y), Float(w.z))
    }

    /// Walls, roof and floor of one piece. A ring between two scales of the
    /// same outline is a strip between them; a column a fan from its middle.
    private static func extrude(_ piece: CellVolumeModel.Piece, scene: StormScene, colour: SIMD4<Float>, into out: inout [SolidVertex]) {
        let outer = piece.outer
        guard outer.count >= 3 else { return }
        let bottom = outer.map { world(scene, lon: $0.lon, lat: $0.lat, metres: piece.base) }
        let top = outer.map { world(scene, lon: $0.lon, lat: $0.lat, metres: piece.top) }
        let middle = outer.reduce(SIMD3<Float>()) { $0 + world(scene, lon: $1.lon, lat: $1.lat, metres: piece.base) } / Float(outer.count)
        let up = SIMD3<Float>(0, 1, 0)

        func triangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, normal: SIMD3<Float>) {
            for p in [a, b, c] {
                out.append(SolidVertex(position: SIMD4(p, 1), normal: SIMD4(normal, 0), colour: colour))
            }
        }
        func wall(_ lower: [SIMD3<Float>], _ upper: [SIMD3<Float>], facingOut: Bool) {
            for i in lower.indices {
                let j = (i + 1) % lower.count
                let edge = lower[j] - lower[i]
                var normal = simd_normalize(simd_cross(edge, up))
                let outward = simd_dot(normal, (lower[i] + lower[j]) / 2 - middle) > 0
                if outward != facingOut { normal = -normal }
                triangle(lower[i], lower[j], upper[j], normal: normal)
                triangle(lower[i], upper[j], upper[i], normal: normal)
            }
        }
        wall(bottom, top, facingOut: true)
        if let hole = piece.hole, hole.count == outer.count {
            let holeBottom = hole.map { world(scene, lon: $0.lon, lat: $0.lat, metres: piece.base) }
            let holeTop = hole.map { world(scene, lon: $0.lon, lat: $0.lat, metres: piece.top) }
            wall(holeBottom, holeTop, facingOut: false)
            for i in outer.indices {
                let j = (i + 1) % outer.count
                triangle(top[i], top[j], holeTop[j], normal: up)
                triangle(top[i], holeTop[j], holeTop[i], normal: up)
                triangle(bottom[i], holeBottom[j], bottom[j], normal: -up)
                triangle(bottom[i], holeBottom[i], holeBottom[j], normal: -up)
            }
        } else {
            let topMiddle = top.reduce(SIMD3<Float>(), +) / Float(top.count)
            for i in outer.indices {
                let j = (i + 1) % outer.count
                triangle(top[i], top[j], topMiddle, normal: up)
                triangle(bottom[j], bottom[i], middle, normal: -up)
            }
        }
    }
}
