//
//  CellModelView.swift
//  meteocool
//
//  A KONRAD3D cell's measured model in its panel, turning once (core's
//  `CellModel3D.svelte`): the solid `CellVolumeModel` builds, lifted out of
//  the map and seen from low over the horizon, with its ground outline and
//  a height ruler. Drawn by hand, painter's algorithm, as core draws it: a
//  few hundred flat faces with no textures. Nothing is stretched: a
//  kilometre up is a kilometre across.
//

import simd
import SwiftUI

/// The faces of a cell's model, built once per cell (core's `build`).
struct CellMesh {
    struct Face {
        var idx: [Int]
        var rgb: SIMD3<Double>
        var alpha: Double
        /// An opaque ring's faces pointing away are dropped; through glass
        /// the far wall is part of the depth.
        var cullable: Bool
    }

    /// x east km, y north km, z km above sea level.
    var verts: [SIMD3<Double>] = []
    var faces: [Face] = []
    var outline: [(x: Double, y: Double)] = []
    var frame: CellVolumeModel.Frame

    /// Outlines decimated again: the picture is a few hundred points wide.
    static let facePoints = 14

    init(_ model: CellVolumeModel.Model, palette: String) {
        frame = CellVolumeModel.frameOf(model)
        outline = model.outlineKm
        let ring = Self.resample(model.outlineKm, Self.facePoints)
        let n = ring.count
        func push(_ x: Double, _ y: Double, _ z: Double) -> Int {
            verts.append(SIMD3(x, y, z))
            return verts.count - 1
        }
        for band in model.bands {
            let low = band.base / 1000, high = band.top / 1000
            for piece in band.rings {
                let c = Colormaps.colour(dbz: piece.dbz, palette: palette)
                let rgb = SIMD3(Double(c.x), Double(c.y), Double(c.z))
                let cullable = piece.alpha >= 1
                func wall(_ scale: Double, outward: Bool) {
                    let base = ring.map { push($0.x * scale, $0.y * scale, low) }
                    let top = ring.map { push($0.x * scale, $0.y * scale, high) }
                    for i in 0 ..< n {
                        let j = (i + 1) % n
                        let idx = outward ? [base[i], base[j], top[j], top[i]] : [base[j], base[i], top[i], top[j]]
                        faces.append(Face(idx: idx, rgb: rgb, alpha: piece.alpha, cullable: cullable))
                    }
                }
                wall(piece.outer, outward: true)
                if piece.inner > 0 { wall(piece.inner, outward: false) }
                // The roof: quads across the annulus, or the core's cap.
                if piece.inner > 0 {
                    let outer = ring.map { push($0.x * piece.outer, $0.y * piece.outer, high) }
                    let inner = ring.map { push($0.x * piece.inner, $0.y * piece.inner, high) }
                    for i in 0 ..< n {
                        let j = (i + 1) % n
                        faces.append(Face(idx: [outer[i], outer[j], inner[j], inner[i]], rgb: rgb, alpha: piece.alpha, cullable: cullable))
                    }
                } else {
                    faces.append(Face(idx: ring.map { push($0.x * piece.outer, $0.y * piece.outer, high) },
                                      rgb: rgb, alpha: piece.alpha, cullable: cullable))
                }
            }
        }
    }

    private static func resample(_ ring: [(x: Double, y: Double)], _ count: Int) -> [(x: Double, y: Double)] {
        guard ring.count > count else { return ring }
        let step = Double(ring.count) / Double(count)
        return (0 ..< count).map { ring[Int(Double($0) * step)] }
    }
}

struct CellModelView: View {
    let input: CellVolumeModel.Input
    /// The family's frame, so a cell half its parent's size is drawn half
    /// the size; nil for the cell's own.
    let frame: CellVolumeModel.Frame?
    let palette: String

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var still
    @State private var mesh: CellMesh?
    @State private var started = Date()
    @State private var turned = false
    @State private var held: Double?
    @State private var dragFrom: Double?

    /// Camera height over the horizon: low, because the vertical is the point.
    static let elevation = 19 * Double.pi / 180
    /// Radians a second: a turn in about twenty seconds, then at rest.
    static let spin = 0.32
    static let restAngle = 0.6
    /// Sun over the viewer's left shoulder, in the model's turning frame.
    static let light = SIMD3<Double>(-0.46, -0.58, 0.67)
    static let rulerStepsKm: [Double] = [1, 2, 5, 10, 20]
    static let minTickPt = 13.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: still || turned || held != nil)) { context in
            let angle = angle(at: context.date)
            Canvas { gc, size in
                if let mesh { draw(mesh, in: &gc, size: size, angle: angle) }
            }
        }
        .frame(height: 200)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragFrom == nil { dragFrom = held ?? angle(at: Date()) }
                held = (dragFrom ?? 0) + value.translation.width * 0.012
            }
            .onEnded { _ in dragFrom = nil })
        .task(id: "\(input.code)|\(palette)") {
            mesh = CellVolumeModel.model(input).map { CellMesh($0, palette: palette) }
            started = Date()
            turned = false
            try? await Task.sleep(for: .seconds(2 * .pi / Self.spin))
            turned = true
        }
        .accessibilityElement()
        .accessibilityLabel(CoreStrings.t("storm.model_aria"))
        .accessibilityAdjustableAction { direction in
            held = (held ?? angle(at: Date())) + (direction == .increment ? 0.4 : -0.4)
        }
        .accessibilityIdentifier("nativeMap.storm.structure")
    }

    private func angle(at date: Date) -> Double {
        if let held { return held }
        if still { return Self.restAngle }
        return Self.restAngle + min(date.timeIntervalSince(started) * Self.spin, 2 * .pi)
    }

    /// Orthographic, yawed by `angle` and seen from `elevation`: screen right
    /// is east, up is `(0, sin, cos)`, towards the viewer `(0, -cos, sin)`.
    private func draw(_ mesh: CellMesh, in gc: inout GraphicsContext, size: CGSize, angle: Double) {
        let dark = scheme == .dark
        let ink: (Double) -> Color = { opacity in
            dark ? Color(red: 235 / 255, green: 238 / 255, blue: 245 / 255).opacity(opacity)
                : Color(red: 20 / 255, green: 24 / 255, blue: 32 / 255).opacity(opacity)
        }
        let cosA = cos(angle), sinA = sin(angle)
        let sinE = sin(Self.elevation), cosE = cos(Self.elevation)
        func up(_ y: Double, _ z: Double) -> Double { y * sinE + z * cosE }

        let fit = frame ?? mesh.frame
        let radius = fit.radiusKm
        let upLow = min(up(-radius, fit.lowKm), up(radius, fit.lowKm))
        let upHigh = max(up(-radius, fit.highKm), up(radius, fit.highKm))
        let gutter = 34.0, pad = 10.0
        let width = Double(size.width), height = Double(size.height)
        let scale = min((width - gutter - pad * 2) / (2 * radius), (height - pad * 2) / max(upHigh - upLow, 0.5))
        let cx = gutter + (width - gutter) / 2
        let cy = height - pad + upLow * scale

        let projected = mesh.verts.map { v -> SIMD3<Double> in
            let rx = v.x * cosA - v.y * sinA
            let ry = v.x * sinA + v.y * cosA
            return SIMD3(cx + rx * scale, cy - up(ry, v.z) * scale, -ry * cosE + v.z * sinE)
        }

        // The ground outline: the clear air under a high base is otherwise hard to see.
        var ground = Path()
        for (i, p) in mesh.outline.enumerated() {
            let point = CGPoint(x: cx + (p.x * cosA - p.y * sinA) * scale, y: cy - (p.x * sinA + p.y * cosA) * sinE * scale)
            if i == 0 { ground.move(to: point) } else { ground.addLine(to: point) }
        }
        ground.closeSubpath()
        gc.fill(ground, with: .color(ink(0.09)))
        gc.stroke(ground, with: .color(ink(0.28)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

        // Far faces first; an opaque face wound clockwise on screen points away.
        var order: [(index: Int, depth: Double)] = []
        for (index, face) in mesh.faces.enumerated() {
            if face.cullable, Self.signedArea(face.idx, projected) >= 0 { continue }
            let depth = face.idx.reduce(0) { $0 + projected[$1].z } / Double(face.idx.count)
            order.append((index, depth))
        }
        order.sort { $0.depth < $1.depth }
        for (index, _) in order {
            let face = mesh.faces[index]
            let shade = Self.lambert(face.idx, mesh.verts, cosA, sinA)
            var path = Path()
            for (i, v) in face.idx.enumerated() {
                let point = CGPoint(x: projected[v].x, y: projected[v].y)
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
            let rgb = face.rgb * shade / 255
            gc.fill(path, with: .color(Color(red: min(rgb.x, 1), green: min(rgb.y, 1), blue: min(rgb.z, 1)).opacity(face.alpha)))
        }

        // A height scale down the left: "tall" needs a number. The step is
        // the first that leaves room between labels at this scale.
        let y = { (km: Double) in cy - km * cosE * scale }
        let step = Self.rulerStepsKm.first { $0 * cosE * scale >= Self.minTickPt } ?? Self.rulerStepsKm.last!
        let x = 26.0
        var ruler = Path()
        ruler.move(to: CGPoint(x: x, y: y(max(fit.lowKm, 0))))
        ruler.addLine(to: CGPoint(x: x, y: y(fit.highKm)))
        var km = 0.0
        while km <= fit.highKm + 1e-6 {
            ruler.move(to: CGPoint(x: x - 3, y: y(km)))
            ruler.addLine(to: CGPoint(x: x, y: y(km)))
            gc.draw(Text(StormRules.toFixed(km, 0)).font(.system(size: 9)).foregroundStyle(ink(0.6)),
                    at: CGPoint(x: x - 5, y: y(km)), anchor: .trailing)
            km += step
        }
        gc.stroke(ruler, with: .color(ink(0.3)), lineWidth: 1)
        gc.draw(Text("km").font(.system(size: 9)).foregroundStyle(ink(0.6)), at: CGPoint(x: 2, y: y(fit.highKm) - 10), anchor: .leading)
    }

    private static func signedArea(_ idx: [Int], _ p: [SIMD3<Double>]) -> Double {
        var sum = 0.0
        for i in idx.indices {
            let a = p[idx[i]], b = p[idx[(i + 1) % idx.count]]
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }

    /// Flat shading from the face's normal, in the model's turning frame.
    private static func lambert(_ idx: [Int], _ verts: [SIMD3<Double>], _ cosA: Double, _ sinA: Double) -> Double {
        func at(_ v: Int) -> SIMD3<Double> {
            let p = verts[v]
            return SIMD3(p.x * cosA - p.y * sinA, p.x * sinA + p.y * cosA, p.z)
        }
        let p = at(idx[0]), q = at(idx[1]), r = at(idx[2 % idx.count])
        let n = simd_cross(q - p, r - p)
        let length = simd_length(n)
        let dot = length > 0 ? abs(simd_dot(n, light) / length) : 0
        return 0.74 + 0.34 * dot
    }
}

extension CellModelView {
    /// A KONRAD3D track's newest detection, as the model reads it; nil
    /// without a measured structure.
    static func input(_ track: TrackProperties) -> CellVolumeModel.Input? {
        guard let at = track.series.last, !track.structure.isEmpty else { return nil }
        return CellVolumeModel.Input(
            code: track.code, lon: at.lon, lat: at.lat, echoBottomM: track.echoBottomM,
            polygon: track.polygon?.map { [$0.lon, $0.lat] },
            structure: track.structure.map {
                CellThreshold(dbz: Double($0.dbz), areaKm2: $0.areaKm2, topM: $0.topM, volumeKm3: $0.volumeKm3, rings: nil)
            })
    }

    /// The frame for `track` among its family (`frameFor`).
    static func familyFrame(_ track: TrackProperties, family: [String: TrackProperties]) -> CellVolumeModel.Frame? {
        guard let own = input(track).flatMap(CellVolumeModel.model).map(CellVolumeModel.frameOf) else { return nil }
        let relatives = family.values.filter { $0.code != track.code }
            .compactMap { input($0).flatMap(CellVolumeModel.model).map(CellVolumeModel.frameOf) }
        return CellVolumeModel.familyFrame(own: own, relatives: relatives)
    }
}
