//
//  StormInside.swift
//  meteocool
//
//  Inside a storm's radar volume, in its panel: the cutaway (core's
//  `CellCutaway.svelte`), a vertical cut turning slowly and turned by a drag;
//  the CAPPI on the 3D map (`CappiSweep.svelte`), everything above a height
//  cut away, the height sweeping up and down; and the radars it was built
//  from (`VolumeProvenance.svelte`, `RadarMinimap.svelte`). The raymarch is
//  the AR view's and the 3D map's.
//

import MetalKit
import SwiftUI

/// Fetches and decodes one volume off the asset host.
@MainActor
final class VolumeLoader: ObservableObject {
    @Published private(set) var volume: StormVolume?
    @Published private(set) var failed = false
    private var path: String?

    /// The same volume once more, after it failed to arrive.
    func retry() {
        guard let path else { return }
        self.path = nil
        load(path)
    }

    func load(_ path: String) {
        guard path != self.path else { return }
        self.path = path
        volume = nil
        failed = false
        guard let url = URL(string: path, relativeTo: NetworkHelper.assetURL) else { failed = true; return }
        Task { [weak self] in
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            let decoded: StormVolume? = await {
                guard let (data, response) = try? await URLSession.shared.data(for: request),
                      (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                return await Task.detached(priority: .userInitiated) { try? StormVolume.decode(data) }.value
            }()
            guard let self, self.path == path else { return }
            self.volume = decoded
            self.failed = decoded == nil
        }
    }
}

/// How a volume is cut open.
enum VolumeCut: Equatable {
    /// A vertical plane through the middle, at this many degrees from east.
    case vertical(Double)
    /// Everything above this many km over the box's floor cut away.
    case slab(Double)
}

/// One storm's volume alone, raymarched, seen from a camera turning round it.
struct StormVolumeView: UIViewRepresentable {
    let volume: StormVolume
    let palette: String
    let cut: VolumeCut
    /// Radians round the storm.
    let spin: Double
    /// Radians above the horizontal.
    let tilt: Double

    func makeUIView(context: Context) -> VolumeCanvas {
        let view = VolumeCanvas()
        view.update(volume: volume, palette: palette, cut: cut, spin: spin, tilt: tilt)
        return view
    }

    func updateUIView(_ view: VolumeCanvas, context: Context) {
        view.update(volume: volume, palette: palette, cut: cut, spin: spin, tilt: tilt)
    }
}

final class VolumeCanvas: MTKView, MTKViewDelegate {
    private var renderer: StormRenderer?
    private var volume: StormVolume?
    private var cut = VolumeCut.vertical(0)
    private var spin = 0.0
    private var tilt = 0.32

    init() {
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        isOpaque = false
        backgroundColor = .clear
        layer.isOpaque = false
        isPaused = true
        enableSetNeedsDisplay = true
        delegate = self
        MainActor.assumeIsolated {
            renderer = StormRenderer(view: self)
            renderer?.resolutionScale = 0.75
        }
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @MainActor
    func update(volume: StormVolume, palette: String, cut: VolumeCut, spin: Double, tilt: Double) {
        self.volume = volume
        self.cut = cut
        self.spin = spin
        self.tilt = tilt
        renderer?.setPalette(palette)
        setNeedsDisplay()
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { render() }
    }

    @MainActor
    private func render() {
        guard let renderer, let volume, bounds.width > 0 else { return }
        let header = volume.header
        let extent = volume.extentM, origin = volume.originM
        // The world as the AR view has it: x east, y up, z south; metres.
        let east = SIMD3<Double>(1, 0, 0), north = SIMD3<Double>(0, 0, -1), up = SIMD3<Double>(0, 1, 0)
        let corner = east * origin.x + north * origin.y + up * origin.z
        let boxToWorld = simd_double4x4(columns: (SIMD4(east * extent.x, 0), SIMD4(north * extent.y, 0),
                                                  SIMD4(up * extent.z, 0), SIMD4(corner, 1)))
        let bounds3 = volume.marchBounds ?? (SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 1, 1))
        let middle = (SIMD3<Double>(bounds3.min) + SIMD3<Double>(bounds3.max)) / 2
        let target4 = boxToWorld * SIMD4(middle, 1)
        let target = SIMD3(target4.x, target4.y, target4.z)
        let reach = max(extent.x * Double(bounds3.max.x - bounds3.min.x), extent.y * Double(bounds3.max.y - bounds3.min.y),
                        extent.z * Double(bounds3.max.z - bounds3.min.z)) / 2
        let distance = max(reach, 4_000) * 2.3
        let eye = target + SIMD3(sin(spin) * distance * cos(tilt), sin(tilt) * distance, cos(spin) * distance * cos(tilt))
        let forward = simd_normalize(target - eye)
        let side = simd_normalize(simd_cross(forward, up))
        let trueUp = simd_cross(side, forward)
        let view = simd_float4x4(columns: (
            SIMD4(Float(side.x), Float(trueUp.x), Float(-forward.x), 0),
            SIMD4(Float(side.y), Float(trueUp.y), Float(-forward.y), 0),
            SIMD4(Float(side.z), Float(trueUp.z), Float(-forward.z), 0),
            SIMD4(Float(-simd_dot(side, eye)), Float(-simd_dot(trueUp, eye)), Float(simd_dot(forward, eye)), 1)))
        let projection = PreviewCamera.perspective(fovY: Float(36.87 * Double.pi / 180), aspect: Float(bounds.width / bounds.height),
                                                   near: Float(distance * 0.05), far: Float(distance * 6))
        let pose = CameraPose(view: view, projection: projection, position: SIMD3<Float>(eye), viewport: bounds.size)

        var u = VolumeUniforms()
        u.inverseViewProjection = pose.viewProjection.inverse
        u.worldToBox = simd_float4x4(converting: boxToWorld.inverse)
        u.camera = SIMD4(SIMD3<Float>(eye), 1)
        u.earth = SIMD4(0, -6_371_000, 0, 6_371_000)
        u.extentKm = SIMD4(SIMD3<Float>(extent / 1000), 0)
        u.light = SIMD4(simd_normalize(SIMD3<Float>(0.35, -0.3, 0.88)), 0)
        u.shells = SIMD4(35, 45, 55, 0)
        u.boxMin = SIMD4(bounds3.min, 0)
        u.boxMax = SIMD4(bounds3.max, 0)
        u.slab = SIMD2(-1, 2)
        u.dbzFloor = Float(header.dbzFloor)
        u.dbzScale = Float(header.dbzScale)
        u.low = Float(StormVolume.dbzLow)
        u.dim = 1
        u.behind = 0
        switch cut {
        case .vertical(let degrees):
            let along = degrees * .pi / 180
            // The cut's normal in the box's own axes, which are not a cube in metres.
            let n = simd_normalize(SIMD3<Double>(cos(along) * extent.x, -sin(along) * extent.y, 0))
            u.planeNormal = SIMD4(Float(n.x), Float(n.y), Float(n.z), 1)
            u.planePoint = SIMD4(SIMD3<Float>(middle), 1)
        case .slab(let km):
            u.slab = SIMD2(-1, Float((km * 1000 - origin.z) / extent.z))
        }
        let storm = StormRenderer.Storm(path: "inside:" + header.code, volume: volume, uniforms: u,
                                        boxToWorld: simd_float4x4(converting: boxToWorld), distance: Float(distance), system: header.code)
        renderer.draw(StormRenderer.Frame(background: .clear, pose: pose, storms: [storm], under: [], over: []), in: self)
    }
}

/// The cutaway: the volume cut down the middle across the storm's track,
/// turning once round it, the cut turned by a drag (`CellCutaway`).
struct StormCutaway: View {
    let volume: StormVolume
    let palette: String
    /// The storm's heading, which the first cut runs along.
    let headingDeg: Double?
    @ObservedObject var cut: StormCut

    @State private var started = Date()
    @State private var dragFrom: Double?
    @Environment(\.accessibilityReduceMotion) private var still

    /// One turn in 24 s, then it rests (`TURN_SECONDS`, `TURNS`).
    static let turnSeconds = 24.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: still)) { context in
            let elapsed = min(context.date.timeIntervalSince(started), Self.turnSeconds)
            let spin = still ? Double.pi * 0.25 : elapsed / Self.turnSeconds * 2 * .pi
            StormVolumeView(volume: volume, palette: palette, cut: .vertical((headingDeg ?? 0) + cut.shown), spin: spin, tilt: 0.32)
        }
        .gesture(DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragFrom == nil {
                    cut.stopSweep(keep: true)
                    dragFrom = cut.angle
                }
                cut.set((dragFrom ?? 0) + value.translation.width * 0.6)
            }
            .onEnded { _ in dragFrom = nil })
        .accessibilityElement()
        .accessibilityLabel(CoreStrings.t("storm.cut.cutaway_aria"))
        .accessibilityValue(CutAngle.label(cut.shown, reference: headingDeg == nil ? .north : .track))
        .accessibilityAdjustableAction { direction in
            cut.stopSweep(keep: true)
            cut.set(cut.angle + (direction == .increment ? 15 : -15))
        }
        .accessibilityIdentifier("nativeMap.storm.cutaway")
    }
}

/// Under the cutaway: the two cuts that mean something, a tap away, and
/// what the picture is (`CellCutaway.svelte`'s buttons and caption). The cut
/// on shows by its style, not its size.
struct CutawaySnaps: View {
    @ObservedObject var cut: StormCut
    let reference: CutAngle.Reference

    var body: some View {
        let (first, second) = CutAngle.snapLabels(reference)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                snap(first, to: 0, on: abs(cut.angle) < 1 || abs(cut.angle) > 179, id: "nativeMap.storm.cut.along")
                snap(second, to: 90, on: abs(abs(cut.angle) - 90) < 1, id: "nativeMap.storm.cut.across")
            }
            Text(CoreStrings.t("storm.cut.cutaway_caption", ["cut": CutAngle.label(cut.shown, reference: reference)]))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("nativeMap.storm.cut.caption")
        }
        .padding(.top, 4)
    }

    private func snap(_ title: String, to degrees: Double, on: Bool, id: String) -> some View {
        Button {
            cut.stopSweep(keep: false)
            withAnimation(.easeOut(duration: 0.2)) { cut.set(degrees) }
        } label: {
            Text(title)
                .font(.subheadline.weight(on ? .semibold : .regular))
                .foregroundStyle(on ? Color.white : Color.primary)
                .padding(.horizontal, 14)
                .frame(minHeight: 32)
                .background(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(.tertiarySystemFill)), in: Capsule())
                // The hit region a finger needs, round a smaller capsule.
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier(id)
    }
}

/// The CAPPI: everything above a height cut away, the height sweeping from
/// the echo's base to its top twice and coming to rest; a drag holds a height.
struct StormCappi: View {
    let volume: StormVolume
    let palette: String

    @State private var started = Date()
    @State private var held: Double?
    @State private var dragFrom: Double?
    @Environment(\.accessibilityReduceMotion) private var still

    static let cycleSeconds = 16.0
    static let turnSeconds = 60.0
    static let cycles = 2.0
    static let restAt = 0.6

    private var range: (low: Double, high: Double) {
        let ceiling = volume.extentM.z / 1000
        let b = volume.marchBounds ?? (SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 1, 1))
        let floor = volume.originM.z / 1000
        return (max(0.25, floor + Double(b.min.z) * ceiling), min(floor + ceiling, floor + Double(b.max.z) * ceiling + 0.5))
    }

    private func height(at elapsed: Double) -> Double {
        if let held { return held }
        let (low, high) = range
        let end = Self.cycles + acos(1 - 2 * Self.restAt) / (2 * .pi)
        let phase = still ? end : min(elapsed / Self.cycleSeconds, end)
        return low + (high - low) * (1 - cos(phase * 2 * .pi)) / 2
    }

    /// The ruler beside the slice (`RULER_PX` wide): every 2 km up to just
    /// above the storm, the storm's span marked, and the slice's height.
    private func ruler(_ km: Double) -> some View {
        let (low, high) = range
        let ceiling = volume.extentM.z / 1000
        let top = min(ceiling, (high + 1).rounded(.up))
        let ticks = stride(from: 0.0, through: top, by: 2).map { $0 }
        return GeometryReader { geometry in
            let h = geometry.size.height
            let y = { (value: Double) -> CGFloat in CGFloat(1 - value / max(top, 0.1)) * h }
            ZStack(alignment: .topLeading) {
                Capsule().fill(Color.accentColor.opacity(0.25))
                    .frame(width: 3, height: max(2, y(low) - y(high)))
                    .offset(x: 4, y: y(high))
                ForEach(ticks, id: \.self) { tick in
                    Text("\(Int(tick))")
                        .scaledFont(10, relativeTo: .caption2, digits: true)
                        .foregroundStyle(.tertiary)
                        .position(x: 24, y: y(tick))
                }
                Text(String(format: "%.1f", km))
                    .scaledFont(10, weight: .bold, relativeTo: .caption2, digits: true)
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 3)
                    .background(.thinMaterial, in: Capsule())
                    .position(x: 24, y: y(km))
            }
        }
        .frame(width: 44)
        .accessibilityHidden(true)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: still)) { context in
            let elapsed = context.date.timeIntervalSince(started)
            let km = height(at: elapsed)
            VStack(alignment: .leading, spacing: 6) {
                // The slice is the slider: dragged, or adjusted by VoiceOver.
                HStack(spacing: 0) {
                    StormVolumeView(volume: volume, palette: palette, cut: .slab(km),
                                    spin: still ? 0.6 : elapsed / Self.turnSeconds * 2 * .pi, tilt: 0.72)
                    ruler(km)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if dragFrom == nil { dragFrom = held ?? height(at: Date().timeIntervalSince(started)) }
                        let (low, high) = range
                        held = min(high, max(low, (dragFrom ?? 0) - value.translation.height * 0.04))
                    }
                    .onEnded { _ in dragFrom = nil })
                .accessibilityElement()
                .accessibilityLabel(CoreStrings.t("storm.volume.cappi_height"))
                .accessibilityValue(String(format: "%.1f km", km))
                .accessibilityAdjustableAction { direction in
                    let (low, high) = range
                    held = min(high, max(low, (held ?? height(at: Date().timeIntervalSince(started))) + (direction == .increment ? 0.5 : -0.5)))
                }
                .accessibilityIdentifier("nativeMap.storm.cappi")
                Text(CoreStrings.t("storm.volume.cappi_caption", ["km": String(format: "%.1f", km)]))
                    .scaledFont(12, relativeTo: .caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("nativeMap.storm.cappi.caption")
            }
        }
    }
}

/// Where the radars stand round the storm, their reach dashed (`RadarMinimap`).
struct RadarMinimap: View {
    let radars: [RadarSites.Contribution]
    let lat: Double
    let lon: Double
    /// The radar a row is pointing at, picked out.
    var highlight: String?

    /// `MIN_HALF_KM`, `ZOOM_OUT`.
    static let minHalfKm = 80.0
    static let zoomOut = 1.4

    var body: some View {
        Canvas { context, size in
            let known = radars.compactMap { radar in radar.site.map { (radar, $0) } }
            let kmPerLon = 111.32 * cos(lat * .pi / 180)
            let points = known.map { radar, site in (radar, site, ((site.lon - lon) * kmPerLon, (site.lat - lat) * 110.57)) }
            let far = points.map { max(abs($0.2.0), abs($0.2.1)) }.max() ?? 0
            let half = max(Self.minHalfKm, far * Self.zoomOut)
            let scale = min(size.width, size.height) / 2 / half
            let middle = CGPoint(x: size.width / 2, y: size.height / 2)
            func at(_ km: (Double, Double)) -> CGPoint { CGPoint(x: middle.x + km.0 * scale, y: middle.y - km.1 * scale) }
            for (_, site, km) in points {
                let centre = at(km)
                let r = site.rangeKm * scale
                context.stroke(Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r)),
                               with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            for (radar, _, km) in points {
                let p = at(km)
                let picked = radar.code == highlight
                let r: CGFloat = picked ? 5 : 3.5
                context.stroke(Path { $0.move(to: middle); $0.addLine(to: p) },
                               with: .color(picked ? .accentColor : .secondary.opacity(0.35)), lineWidth: picked ? 2 : 1)
                context.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                             with: .color(highlight == nil || picked ? .accentColor : .secondary))
                context.draw(Text(radar.name).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary),
                             at: CGPoint(x: p.x, y: p.y - 9))
            }
            context.fill(Path(ellipseIn: CGRect(x: middle.x - 5, y: middle.y - 5, width: 10, height: 10)), with: .color(.red))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityHidden(true)
    }
}
