//
//  ThreeDMap.swift
//  meteocool
//
//  core's 3D storm map (`caps/Cells3DCapability.ts`), native: the radar's
//  storm volumes raymarched over the map, on the ground the radar is draped
//  over, seen from an orbiting camera. The volumes, their modes, tags and
//  lines are the AR view's (`StormFeed`, `StormScene`, `StormRenderer`).
//

import Combine
import MapKit
import MetalKit
import SwiftUI
import UIKit

/// How much taller than life heights are drawn, storms and ground alike
/// (core's `VERTICAL_SCALE`).
enum ThreeDScale {
    static let vertical = 1.5
    static let stretch = simd_double4x4(diagonal: SIMD4(1, vertical, 1, 1))
    static let stretchF = simd_float4x4(diagonal: SIMD4(1, Float(vertical), 1, 1))
}

/// Where the 3D map looks from: a point on the ground, how far from it,
/// how far tilted from straight down and turned from north.
struct OrbitCamera: Equatable {
    var latitude: Double
    var longitude: Double
    /// Metres from the eye to the point.
    var distance: Double
    /// Degrees from looking straight down.
    var pitch: Double
    /// Degrees clockwise from north.
    var bearing: Double

    /// MapLibre's field of view (`0.6435` rad).
    static let fovY = 36.87
    static let distances = 2_500.0 ... 1_800_000.0
    static let pitches = 0.0 ... 78.0

    /// The flat map's view, as the 3D map first shows it: the same ground
    /// filling the screen's height, tilted.
    static func from(center: CLLocationCoordinate2D, zoom: Double, heading: Double, height: Double) -> OrbitCamera {
        let metresPerPoint = 40_075_016.686 * cos(center.latitude * .pi / 180) / (256 * pow(2, zoom))
        let distance = metresPerPoint * height / (2 * tan(fovY / 2 * .pi / 180))
        return OrbitCamera(latitude: center.latitude, longitude: center.longitude,
                           distance: min(max(distance, distances.lowerBound), distances.upperBound),
                           pitch: 55, bearing: heading)
    }

    /// The flat map's zoom for this view, to hand the camera back.
    func zoom(height: Double) -> Double {
        let metresPerPoint = distance * 2 * tan(Self.fovY / 2 * .pi / 180) / max(height, 1)
        return log2(40_075_016.686 * cos(latitude * .pi / 180) / (256 * metresPerPoint))
    }

    @MainActor
    func pose(in scene: StormScene, viewport: CGSize) -> CameraPose {
        let target = scene.world(latitude: latitude, longitude: longitude, altitude: 0)
        let b = bearing * .pi / 180, p = pitch * .pi / 180
        // The world's axes: x east, y up, z south.
        let ahead = SIMD3<Double>(sin(b), 0, -cos(b))
        let skyward = SIMD3<Double>(0, 1, 0)
        let eye = target - ahead * distance * sin(p) + skyward * distance * cos(p)
        let forward = normalize(target - eye)
        let up = normalize(ahead * cos(p) + skyward * sin(p))
        let side = normalize(cross(forward, up))
        let trueUp = cross(side, forward)
        let view = simd_float4x4(columns: (
            SIMD4(Float(side.x), Float(trueUp.x), Float(-forward.x), 0),
            SIMD4(Float(side.y), Float(trueUp.y), Float(-forward.y), 0),
            SIMD4(Float(side.z), Float(trueUp.z), Float(-forward.z), 0),
            SIMD4(Float(-dot(side, eye)), Float(-dot(trueUp, eye)), Float(dot(forward, eye)), 1)))
        let aspect = Float(viewport.width / max(viewport.height, 1))
        let near = Float(max(20, distance * 0.02))
        let far = Float(distance * 6 + 900_000)
        let projection = PreviewCamera.perspective(fovY: Float(Self.fovY * .pi / 180), aspect: aspect, near: near, far: far)
        return CameraPose(view: view, projection: projection, position: SIMD3<Float>(eye), viewport: viewport)
    }

    /// Ground metres per screen point at the point looked at.
    func metresPerPoint(height: Double) -> Double {
        distance * 2 * tan(Self.fovY / 2 * .pi / 180) / max(height, 1)
    }
}

// MARK: - Ground

/// The map under the storms: Apple's map of the area, the radar draped
/// over it, raised by the terrain where that is on, as a mesh in the
/// scene's world.
@MainActor
final class ThreeDGround {
    private(set) var current: StormRenderer.MapGround?
    private(set) var centre: CLLocationCoordinate2D?
    private(set) var radius = 0.0
    private var building = false
    private var builtFor: String?
    private var token = 0

    /// The ground picture's side: four times the pixels where the memory
    /// allows (the picture and its mipmaps are some 90 MB at 4096).
    static let pixels = ProcessInfo.processInfo.physicalMemory >= 6 << 30 ? 4096 : 2048
    static let grid = 64

    /// Whether `camera` needs another ground: a first one, moved too far, or
    /// zoomed in or out enough that this one is too coarse or too small.
    func wants(_ camera: OrbitCamera, key: String) -> Bool {
        guard let centre, current != nil else { return true }
        if key != builtFor { return true }
        let away = Geo.distanceBearing(fromLat: centre.latitude, lon: centre.longitude, toLat: camera.latitude, lon: camera.longitude).metres
        let wanted = Self.radius(for: camera)
        return away > radius * 0.35 || wanted > radius * 1.25 || wanted < radius * 0.4
    }

    static func radius(for camera: OrbitCamera) -> Double {
        min(max(camera.distance * 2.6, 40_000), 900_000)
    }

    /// `replacing` builds even while another build runs, which it supersedes;
    /// `ready` runs in the same turn the new ground takes over (the scene's
    /// origin moving with it, so nothing is drawn misplaced or missing).
    func build(_ camera: OrbitCamera, key: String, scene: StormScene, device: MTLDevice, radar: RadarEngine, dark: Bool,
               terrain: Bool, replacing: Bool = false, ready: (@MainActor () -> Void)? = nil) {
        guard !building || replacing else { return }
        building = true
        token += 1
        let mine = token
        let centre = CLLocationCoordinate2D(latitude: camera.latitude, longitude: camera.longitude)
        let radius = Self.radius(for: camera)
        let middle = MKMapPoint(centre)
        let side = 2 * radius * MKMapPointsPerMeterAtLatitude(centre.latitude)
        let rect = MKMapRect(x: middle.x - side / 2, y: middle.y - side / 2, width: side, height: side)
        Task { @MainActor in
            defer { if mine == self.token { self.building = false } }
            async let snapshot = Self.snapshot(rect, dark: dark)
            async let heights = terrain ? Self.terrain(rect) : nil
            let drape = await Self.drape(rect, radar: radar)
            let map = await snapshot
            let relief = await heights
            guard let picture = Self.compose(map, drape: drape, dark: dark),
                  let texture = try? await MTKTextureLoader(device: device).newTexture(cgImage: picture, options: [
                      .generateMipmaps: true, .SRGB: false, .textureUsage: MTLTextureUsage.shaderRead.rawValue,
                  ]),
                  let (vertices, indices, count) = Self.mesh(rect, scene: scene, heights: relief, device: device),
                  mine == self.token else { return }
            let haze: SIMD4<Float> = dark ? SIMD4(0.09, 0.11, 0.14, Float(radius * 1.15)) : SIMD4(0.80, 0.84, 0.88, Float(radius * 1.15))
            ready?()
            self.current = StormRenderer.MapGround(texture: texture, vertices: vertices, indices: indices, indexCount: count,
                                                   haze: haze, horizonDip: 0)
            self.centre = centre
            self.radius = radius
            self.builtFor = key
        }
    }

    /// Forget it: the scene moved, so its mesh is somewhere else now.
    func reset() {
        token += 1
        building = false
        current = nil
        centre = nil
    }

    private static func snapshot(_ rect: MKMapRect, dark: Bool) async -> CGImage? {
        let options = MKMapSnapshotter.Options()
        options.mapRect = rect
        // At 1x over the whole texture rather than 2x over half of it: the
        // same pixels, but finer tiles and labels half the size, which the
        // tilted camera magnifies near the bottom of the screen.
        options.size = CGSize(width: pixels, height: pixels)
        options.traitCollection = UITraitCollection(traitsFrom: [UITraitCollection(displayScale: 1),
                                                                  UITraitCollection(userInterfaceStyle: dark ? .dark : .light)])
        let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        configuration.pointOfInterestFilter = .excludingAll
        options.preferredConfiguration = configuration
        return await withCheckedContinuation { continuation in
            MKMapSnapshotter(options: options).start { snapshot, _ in continuation.resume(returning: snapshot?.image.cgImage) }
        }
    }

    /// The radar on screen over the area; a few tries while its tiles load.
    private static func drape(_ rect: MKMapRect, radar: RadarEngine) async -> CGImage? {
        for attempt in 0 ..< 10 {
            let image: CGImage? = await withCheckedContinuation { continuation in
                radar.drape(rect, pixels: pixels) { continuation.resume(returning: $0) }
            }
            if let image { return image }
            try? await Task.sleep(for: .milliseconds(attempt < 3 ? 300 : 800))
        }
        return nil
    }

    private static func compose(_ map: CGImage?, drape: CGImage?, dark: Bool) -> CGImage? {
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let all = CGRect(x: 0, y: 0, width: pixels, height: pixels)
        context.setFillColor(dark ? CGColor(red: 0.09, green: 0.11, blue: 0.14, alpha: 1) : CGColor(red: 0.85, green: 0.87, blue: 0.86, alpha: 1))
        context.fill(all)
        if let map { context.draw(map, in: all) }
        if let drape {
            context.setAlpha(CGFloat(ThreeDPaint.radarOpacity) * 1.6)
            context.interpolationQuality = .none
            context.draw(drape, in: all)
        }
        return context.makeImage()
    }

    /// Mapterhorn's terrarium tiles over the area, as metres per grid point.
    private static func terrain(_ rect: MKMapRect) async -> [Double]? {
        let z = max(0, min(10, Int(floor(log2(MKMapSize.world.width / (rect.width / 2))))))
        guard let range = RadarTileKey.range(z: z, covering: rect) else { return nil }
        var tiles: [String: (width: Int, height: Int, bytes: [UInt8])] = [:]
        await withTaskGroup(of: (String, (Int, Int, [UInt8])?).self) { group in
            for x in range.x {
                for y in range.y {
                    group.addTask {
                        guard let url = URL(string: "https://map.meteocool.com/mapterhorn-20261002/\(z)/\(x)/\(y).webp"),
                              let (data, response) = try? await URLSession.meteocool.data(from: url),
                              (response as? HTTPURLResponse)?.statusCode == 200,
                              let image = UIImage(data: data)?.cgImage else { return ("\(x)/\(y)", nil) }
                        let width = image.width, height = image.height
                        var bytes = [UInt8](repeating: 0, count: width * height * 4)
                        guard let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return ("\(x)/\(y)", nil) }
                        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                        return ("\(x)/\(y)", (width, height, bytes))
                    }
                }
            }
            for await (key, tile) in group { if let tile { tiles[key] = tile } }
        }
        guard !tiles.isEmpty else { return nil }
        let n = grid
        var out = [Double](repeating: 0, count: (n + 1) * (n + 1))
        let tileSide = MKMapSize.world.width / Double(1 << z)
        for j in 0 ... n {
            for i in 0 ... n {
                let x = rect.minX + rect.width * Double(i) / Double(n)
                let y = rect.minY + rect.height * Double(j) / Double(n)
                let tx = Int(x / tileSide), ty = Int(y / tileSide)
                guard let tile = tiles["\(tx)/\(ty)"] else { continue }
                let px = min(tile.width - 1, max(0, Int((x / tileSide - Double(tx)) * Double(tile.width))))
                let py = min(tile.height - 1, max(0, Int((y / tileSide - Double(ty)) * Double(tile.height))))
                let o = (py * tile.width + px) * 4
                let metres = Double(tile.bytes[o]) * 256 + Double(tile.bytes[o + 1]) + Double(tile.bytes[o + 2]) / 256 - 32_768
                out[j * (n + 1) + i] = max(0, metres)
            }
        }
        return out
    }

    private static func mesh(_ rect: MKMapRect, scene: StormScene, heights: [Double]?, device: MTLDevice) -> (MTLBuffer, MTLBuffer, Int)? {
        let n = grid
        var vertices: [GroundVertex] = []
        vertices.reserveCapacity((n + 1) * (n + 1))
        for j in 0 ... n {
            for i in 0 ... n {
                let point = MKMapPoint(x: rect.minX + rect.width * Double(i) / Double(n), y: rect.minY + rect.height * Double(j) / Double(n))
                let c = point.coordinate
                let altitude = (heights?[j * (n + 1) + i] ?? 0) * ThreeDScale.vertical
                let w = scene.world(latitude: c.latitude, longitude: c.longitude, altitude: altitude)
                vertices.append(GroundVertex(position: SIMD4(Float(w.x), Float(w.y), Float(w.z), 1),
                                             uv: SIMD2(Float(i) / Float(n), Float(j) / Float(n))))
            }
        }
        var indices: [UInt32] = []
        indices.reserveCapacity(n * n * 6)
        for j in 0 ..< n {
            for i in 0 ..< n {
                let a = UInt32(j * (n + 1) + i), b = a + 1, c = a + UInt32(n + 1), d = c + 1
                indices += [a, c, b, b, c, d]
            }
        }
        guard let vb = device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<GroundVertex>.stride),
              let ib = device.makeBuffer(bytes: indices, length: indices.count * MemoryLayout<UInt32>.stride) else { return nil }
        return (vb, ib, indices.count)
    }
}

// MARK: - The view

/// What the 3D map's controls show.
@MainActor
final class ThreeDState: ObservableObject {
    @Published var mode: ARViewMode = .live
    @Published var slider: Double = 0
    @Published var sliderText = ""
    @Published var status: String?
    @Published var bearing: Double = 0
    /// Looking at the storms from the side rather than straight down.
    @Published var tilted = false
    @Published var dark = true
    @Published var selected: String?
    /// The scan the storms are from: nil for the newest (`cloudsTime`).
    @Published var scanShown: Int?
    @Published var scanLoading: Int?
    @Published var scanProgress = 0.0
    @Published var scanNote: String?
    @Published var newestScan: Int?
    var pickScan: (Int?) -> Void = { _ in }
    var openGuide: () -> Void = {}
    var setMode: (ARViewMode) -> Void = { _ in }
    var setSlider: (Double) -> Void = { _ in }
    var north: () -> Void = {}
    var tilt: () -> Void = {}
    var open: () -> Void = {}
}

/// The 3D map over the flat one while `cells3d` is the map shown.
@MainActor
final class ThreeDMapView: UIView, MTKViewDelegate, UIGestureRecognizerDelegate {
    private weak var map: NativeMapContext?
    private let metalView = MTKView()
    private let labels = StormLabelLayer()
    /// The reader's position on the ground (core's `showLocation`), as the
    /// flat map's blue dot.
    private let locationDot = LocationDot()
    private var userLocation: CLLocationCoordinate2D?
    private let state = ThreeDState()
    private let feed = StormFeed()
    private let ground = ThreeDGround()
    private let cellSolids = CellSolids()
    private var renderer: StormRenderer?
    private var scene: StormScene?
    private var hud: UIView?
    private(set) var camera = OrbitCamera(latitude: 49, longitude: 11, distance: 400_000, pitch: 55, bearing: 0)
    private var lastPose: CameraPose?
    private var placed: [PlacedStorm] = []
    private var groups: [StormGroup] = []
    private var drawn: [(storm: PlacedStorm, group: StormGroup)] = []
    private var labelModels: [String: StormLabelModel] = [:]
    private var labelsBuiltAt = Date.distantPast
    private var sliderValues: [ARViewMode: Double] = [:]
    private var pitchStart: Double?
    private var stepKey = ""

    /// The modes that make sense from above (not the AR view's walking ones).
    static let modes: [ARViewMode] = [.live, .peel, .shells, .slice, .turn, .shaft, .tops, .floor]

    init(map: NativeMapContext) {
        self.map = map
        super.init(frame: .zero)
        backgroundColor = .black
        accessibilityIdentifier = "nativeMap.3d"

        metalView.translatesAutoresizingMaskIntoConstraints = false
        metalView.preferredFramesPerSecond = 60
        metalView.delegate = self
        metalView.isAccessibilityElement = true
        metalView.accessibilityLabel = CoreStrings.t("storm_cells_3d")
        metalView.accessibilityIdentifier = "nativeMap.3d.canvas"
        addSubview(metalView)
        renderer = StormRenderer(view: metalView)
        renderer?.onGPUTime = { [timing, resolution] seconds in
            if FrameTiming.on { timing.gpu(seconds) }
            resolution.report(seconds)
        }
        labels.translatesAutoresizingMaskIntoConstraints = false
        labels.onSelect = { [weak self] key in self?.select(key, toggle: true) }
        labels.onOpen = { [weak self] key in self?.openOnMap(key) }
        labels.rightClearance = ChromeTheme.controlColumn
        addSubview(locationDot)
        addSubview(labels)
        let host = UIHostingController(rootView: ThreeDHUD(state: state, model: map.model).chromeTypeSize())
        host.view.backgroundColor = .clear
        host.sizingOptions = .intrinsicContentSize
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host.view)
        hud = host.view
        NSLayoutConstraint.activate([
            metalView.topAnchor.constraint(equalTo: topAnchor),
            metalView.bottomAnchor.constraint(equalTo: bottomAnchor),
            metalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            labels.topAnchor.constraint(equalTo: topAnchor),
            labels.bottomAnchor.constraint(equalTo: bottomAnchor),
            labels.leadingAnchor.constraint(equalTo: leadingAnchor),
            labels.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.view.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: ChromeTheme.gutter),
            host.view.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -ChromeTheme.gutter),
            host.view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -21),
        ])

        state.setMode = { [weak self] in self?.setMode($0) }
        state.setSlider = { [weak self] in self?.setSlider($0) }
        // North up, looking straight down (`guide_3d.compass_does`).
        state.north = { [weak self] in
            guard let self else { return }
            self.touched()
            self.camera.bearing = 0
            self.camera.pitch = OrbitCamera.pitches.lowerBound
            self.cameraSettled()
        }
        // The tilt's onscreen alternative, as Maps' 2D/3D button: tilted,
        // straight down, and back.
        state.tilt = { [weak self] in
            guard let self else { return }
            self.touched()
            self.camera.pitch = self.camera.pitch > Self.flatPitch ? OrbitCamera.pitches.lowerBound : Self.tiltedPitch
            self.cameraSettled()
        }
        state.pickScan = { [weak self] in self?.pickScan($0) }
        state.openGuide = { [weak self] in self?.openGuide() }
        state.open = { [weak self] in
            guard let self, let key = self.scene?.selectedKey else { return }
            self.open(key)
        }
        feed.onChange = { [weak self] in self?.feedChanged() }
        locationChanged = map.model.$userLocation.sink { [weak self] location in
            DispatchQueue.main.async { self?.userLocation = location?.coordinate }
        }
        // The storm closed (its panel, the layer switcher): its highlight goes too.
        stormClosed = map.model.$stormOpen.dropFirst().filter { !$0 }.sink { [weak self] _ in
            DispatchQueue.main.async { self?.select(nil, toggle: false) }
        }
        openedChanged = map.model.$opened.removeDuplicates().sink { [weak self] opened in
            DispatchQueue.main.async { self?.openedDidChange(opened) }
        }
        installGestures()
        installActions()
    }

    static let flatPitch = 5.0
    static let tiltedPitch = 55.0

    private var stormClosed: AnyCancellable?
    private var openedChanged: AnyCancellable?
    private var locationChanged: AnyCancellable?

    /// Full rate while a finger moves the map and a moment after; half when
    /// it is only looked at, where the storms' own motion reads the same and
    /// the GPU and battery do half the work.
    private var touchedAt = CACurrentMediaTime()
    static let idleAfter: CFTimeInterval = 2
    private func touched() {
        touchedAt = CACurrentMediaTime()
        if metalView.preferredFramesPerSecond != 60 { metalView.preferredFramesPerSecond = 60 }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Showing

    /// Opens on the flat map's view, tilted: framed on the first frame
    /// drawn, once the flat map has been laid out and placed (a link opening
    /// on the 3D map arrives before either).
    func show() {
        framePending = true
        openedKey = nil
        feed.start()
        touched()
        metalView.isPaused = false
        refreshStatus()
    }

    private var framePending = false
    private let timing = FrameTiming()
    private let resolution = AdaptiveResolution()
    private struct PlaceKey: Equatable {
        let revision: Int
        let latitude: Double
        let longitude: Double
    }
    private var placedFor: PlaceKey?
    private var groupByKey: [String: StormGroup] = [:]

    private func frame(from mapView: MKMapView, zoom: Double) {
        framePending = false
        camera = OrbitCamera.from(center: mapView.centerCoordinate, zoom: zoom, heading: mapView.camera.heading,
                                  height: Double(mapView.bounds.height))
        if let link = pendingLink {
            pendingLink = nil
            place(link)
        }
        // A storm opened in 3D from elsewhere: framed in the room the panel
        // leaves, from low down, among its neighbours.
        if let focus = map?.model.focus3D {
            map?.model.focus3D = nil
            stand(on: focus, bearing: camera.bearing)
        }
        let frame = GeoFrame(latitude: camera.latitude, longitude: camera.longitude, altitude: 0)
        if let scene { scene.move(to: frame) } else { scene = StormScene(frame: frame) }
        applySettings()
        ground.reset()
        feed.viewer = (camera.latitude, camera.longitude)
    }

    // MARK: The open storm

    /// The storm open in the panel, and the key of the 3D map's storm it is
    /// once found among them; whether that one is cut (`TIER_UNOPENABLE`).
    private var opened: OpenedStorm?
    private var openedKey: String?
    private var openedCut = false

    /// A storm opened, closed, or the same one with a newer heading.
    private func openedDidChange(_ next: OpenedStorm?) {
        let same = next?.isSame(as: opened) ?? false
        opened = next
        guard !same else { return }
        openedKey = nil
        openedCut = false
        if next == nil { map?.model.cut.stopSweep(keep: false) }
        resolveOpened()
    }

    /// Finds the open storm among the 3D map's, once they are placed:
    /// highlighted, cut along its track where it stands, the cut turned to
    /// face the camera and the camera stood before it, then swung a while
    /// (core's `openSelection`, `frameOpened`, `startSweep`).
    private func resolveOpened() {
        guard let opened, openedKey == nil, let map, map.model.capability == .cells3d, !isHidden, !framePending,
              let group = groups.first(where: { group in
                  (opened.volume != nil && group.tiles.contains { $0.entry.path == opened.volume })
                      || (opened.cell != nil && group.cell?.code == opened.cell)
              }) ?? successor(of: opened)
        else { return }
        openedKey = group.key
        select(group.key, toggle: false)
        // Not seen well enough to open: whole on the map, and nothing cut.
        guard group.reference.entry.tier != 1 else { return }
        openedCut = true
        faceCut(group, heading: opened.headingDeg ?? 0)
        map.model.cut.startSweep()
    }

    /// A box of sky's own volume gone from the list, a newer scan in its
    /// place (an older link, or one made just before the scan): the openable
    /// storm standing where it stood.
    private func successor(of opened: OpenedStorm) -> StormGroup? {
        guard opened.cell == nil, let lat = opened.latitude, let lon = opened.longitude, feed.status == .ready else { return nil }
        let near = groups.filter(\.openable).map { group in
            (group, group.tiles.map { RadarSites.distanceKm(lat, lon, $0.entry.lat, $0.entry.lon) }.min() ?? .infinity)
        }
        guard let best = near.min(by: { $0.1 < $1.1 }), best.1 < Self.successorKm else { return nil }
        return best.0
    }

    static let successorKm = 10.0

    /// The half kept is whichever faces the camera: a cut turned half way
    /// round is the same cut. Then, unless a link has just set the camera,
    /// the camera stands square to the cut, from low down.
    private func faceCut(_ group: StormGroup, heading: Double) {
        guard let cut = map?.model.cut else { return }
        var direction = heading + cut.angle
        let facing = CutAngle.normalise(direction - 90 - camera.bearing)
        let flipped = CutAngle.normalise(direction + 90 - camera.bearing)
        if abs(flipped) < abs(facing) {
            direction += 180
            cut.set(cut.angle + 180)
        }
        if let at = linkCameraAt, CACurrentMediaTime() - at < Self.linkCameraKept { return }
        let peak = group.reference.entry
        stand(on: ThreeDFocus(latitude: peak.lat, longitude: peak.lon, areaKm2: group.areaKm2, topM: group.echoTopM),
              bearing: Geo.normalise(direction - 90))
    }

    /// The open storm's cut on this frame: its key and the way it runs.
    private func openCut() -> (key: String, alongDeg: Double)? {
        guard openedCut, let openedKey, let opened, let cut = map?.model.cut else { return nil }
        return (openedKey, (opened.headingDeg ?? 0) + cut.shown)
    }

    /// The camera stood where `focus` fills the room the panel leaves,
    /// looking along `bearing`.
    private func stand(on focus: ThreeDFocus, bearing: Double) {
        guard let map else { return }
        // The flat map's size: this view covers the same ground, and may
        // not have been laid out yet on its first frame.
        let size = map.mapView.bounds.size
        let phone = traitCollection.horizontalSizeClass == .compact
        var room = FramingRoom.of(width: Double(size.width), height: Double(size.height), phone: phone)
        // A wide screen's panel stands left of the app's buttons.
        if !phone { room.right = max(room.right - Double(ChromeTheme.controlColumn - 12), room.width / 2) }
        let stand = OrbitFraming.stand(lat: focus.latitude, lon: focus.longitude, widthM: focus.widthM, heightM: focus.heightM,
                                       bearing: bearing, room: room, fovY: OrbitCamera.fovY)
        camera.bearing = bearing
        if [stand.latitude, stand.longitude, stand.distance].allSatisfy(\.isFinite) {
            camera.latitude = stand.latitude
            camera.longitude = stand.longitude
            camera.distance = min(max(stand.distance, OrbitCamera.distances.lowerBound), OrbitCamera.distances.upperBound)
            camera.pitch = min(stand.pitch, OrbitCamera.pitches.upperBound)
        } else {
            camera.latitude = focus.latitude
            camera.longitude = focus.longitude
        }
        touched()
    }

    // MARK: Links

    /// A link's camera (`setCamera`): where, how tilted, which way.
    struct LinkCamera {
        var view: NativeMapLink?
        var pitch: Double?
        var bearing: Double?
    }

    private var pendingLink: LinkCamera?
    private var linkCameraAt: CFTimeInterval?
    /// How long a camera a link set is kept from an opening storm's framing.
    static let linkCameraKept: CFTimeInterval = 3

    func applyLink(_ link: LinkCamera) {
        if link.pitch != nil || link.bearing != nil { linkCameraAt = CACurrentMediaTime() }
        if framePending { pendingLink = link } else { place(link) }
    }

    private func place(_ link: LinkCamera) {
        if let view = link.view, let map {
            camera = OrbitCamera.from(center: CLLocationCoordinate2D(latitude: view.latitude, longitude: view.longitude), zoom: view.zoom,
                                      heading: camera.bearing, height: Double(map.mapView.bounds.height))
        }
        if let pitch = link.pitch { camera.pitch = min(max(pitch, OrbitCamera.pitches.lowerBound), OrbitCamera.pitches.upperBound) }
        if let bearing = link.bearing { camera.bearing = bearing }
        touched()
        cameraSettled()
    }

    /// The app's location button (core's `lookAt`): the camera over the
    /// reader, as tilted and turned as it was; nearer when `zoom` is given.
    func lookAt(_ coordinate: CLLocationCoordinate2D, zoom: Double?) {
        guard let map else { return }
        if framePending {
            let view = NativeMapLink(latitude: coordinate.latitude, longitude: coordinate.longitude, zoom: zoom ?? map.zoomLevel)
            pendingLink = LinkCamera(view: view, pitch: nil, bearing: nil)
            return
        }
        let pitch = camera.pitch
        if let zoom {
            camera = OrbitCamera.from(center: coordinate, zoom: zoom, heading: camera.bearing, height: Double(map.mapView.bounds.height))
            camera.pitch = pitch
        } else {
            camera.latitude = coordinate.latitude
            camera.longitude = coordinate.longitude
        }
        touched()
        cameraSettled()
    }

    func hide() {
        feed.stop()
        metalView.isPaused = true
        // The swing only where the cut is drawn.
        map?.model.cut.stopSweep(keep: true)
    }

    func wake() {
        feed.stop()
        feed.start()
    }

    func applySettings() {
        guard let scene, let map else { return }
        scene.palette = UserDefaults(suiteName: "group.org.frcy.app.meteocool")?.string(forKey: "radarColorMapping") ?? "classic"
        renderer?.setPalette(scene.palette)
        scene.showLightning = map.isOn(.lightning)
        scene.mode = state.mode
        scene.sliderValue = state.slider
        state.dark = map.model.isDark
    }

    /// The radar step drawn on the ground changed: drape it again.
    func stepChanged(_ step: RadarStep) {
        stepKey = step.time.map(String.init) ?? ""
    }

    // MARK: Feed

    private func feedChanged() {
        labelsBuiltAt = .distantPast
        refreshStatus()
    }

    // MARK: The guide

    /// What the marks mean and how to move the map (`Guide3D.svelte`).
    private func openGuide() {
        guard let map else { return }
        var controller: UIViewController?
        let guide = ThreeDGuide(palette: scene?.palette ?? "classic", cellsShown: map.isOn(.cells3d)) { controller?.dismiss(animated: true) }
        let host = UIHostingController(rootView: guide)
        controller = host
        host.modalPresentationStyle = .pageSheet
        host.sheetPresentationController?.detents = [.medium(), .large()]
        host.sheetPresentationController?.prefersGrabberVisible = true
        map.host?.presentOverMap(host)
    }

    // MARK: Earlier scans

    /// One of the last two hours' scans, looked for in the bucket, or the
    /// newest again (`Cells3DCapability.showScan`). The radar under it is
    /// the same scan's.
    private func pickScan(_ scan: Int?) {
        guard let map else { return }
        guard let scan else {
            feed.showLatest()
            state.scanShown = nil
            state.scanLoading = nil
            map.player.showLive()
            return
        }
        state.scanLoading = scan
        state.scanProgress = 0
        state.scanNote = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.feed.showScan(scan) { [weak self] share in self?.state.scanProgress = share }
            guard self.state.scanLoading == scan else { return }
            self.state.scanLoading = nil
            if result.found {
                self.state.scanShown = scan
                map.player.show(time: scan)
            } else {
                self.state.scanNote = CoreStrings.t(result.failed ? "time_3d.failed" : "time_3d.nothing", ["time": StatusPill.clock(scan)])
                try? await Task.sleep(for: .seconds(6))
                if self.state.scanNote != nil { self.state.scanNote = nil }
            }
        }
    }

    /// Runs with every rebuild of the labels; a published value is set only
    /// when it changes, or the tray (and a menu open in it) redraws each time.
    private func refreshStatus() {
        if state.newestScan != feed.newestScan { state.newestScan = feed.newestScan }
        let status: String? = switch feed.status {
        case .loading: NSLocalizedString("ar_status_loading", comment: "")
        case .failed: NSLocalizedString("ar_status_failed", comment: "")
        // What was placed is what is near: ranking every box again by
        // distance here was the 3D map's longest stall.
        case .ready: placed.isEmpty ? NSLocalizedString("ar_no_storms", comment: "") : nil
        }
        if state.status != status { state.status = status }
    }

    // MARK: Modes

    private func setMode(_ mode: ARViewMode) {
        touched()
        state.mode = mode
        let value = sliderValues[mode] ?? mode.slider?.initial ?? 0
        state.slider = value
        scene?.mode = mode
        scene?.sliderValue = value
        refreshSliderText()
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func setSlider(_ value: Double) {
        touched()
        state.slider = value
        sliderValues[state.mode] = value
        scene?.sliderValue = value
        refreshSliderText()
    }

    private func refreshSliderText() {
        guard let slider = state.mode.slider else { state.sliderText = ""; return }
        let value = state.slider
        let number: String
        switch state.mode {
        case .peel:
            if let key = scene?.selectedKey, let group = groups.first(where: { $0.key == key }) {
                number = String(format: "%.0f", StormVolume.dbzLow + value * (group.peelFloor - StormVolume.dbzLow))
            } else {
                state.sliderText = String(format: "%.0f %%", value * 100)
                return
            }
        case .slice, .turn:
            number = String(format: "%+.0f", value)
        default:
            number = String(format: "%.1f", value)
        }
        state.sliderText = String(format: slider.format, number)
    }

    private func select(_ key: String?, toggle: Bool) {
        guard let scene else { return }
        let next = toggle && scene.selectedKey == key ? nil : key
        guard next != scene.selectedKey else { return }
        scene.selectedKey = next
        state.selected = next
        labelsBuiltAt = .distantPast
        refreshSliderText()
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// The label's "Open on Map": the flat radar map, centred on the storm,
    /// with it open there.
    private func openOnMap(_ key: String) {
        guard let map, let peak = feed.entries.filter({ $0.stormKey == key }).max(by: { ($0.peakDbz ?? 0) < ($1.peakDbz ?? 0) })
        else { return }
        let zoom = max(map.zoomLevel, 8)
        map.setCapability(.radar)
        map.place(NativeMapLink(latitude: peak.lat, longitude: peak.lon, zoom: zoom), animated: false)
        open(key)
    }

    /// A storm's details: by its cell where it has one, else by the tile
    /// holding its peak (`MapLink.search`), on the map's own sheet.
    private func open(_ key: String) {
        let tiles = feed.entries.filter { $0.stormKey == key }
        guard let peak = tiles.first(where: \.isStormPeak) ?? tiles.max(by: { ($0.peakDbz ?? 0) < ($1.peakDbz ?? 0) }) else { return }
        let cell = tiles.compactMap { feed.cell(for: $0) }.max { ($0.maxDbz ?? 0) < ($1.maxDbz ?? 0) }
        if let cell, MapLink.isCellCode(cell.code) {
            map?.openLink(["cell": cell.code])
        } else {
            map?.model.volumeRequest = RadarVolume(path: peak.path, coverage: peak.coverage ?? 0, code: peak.code, lon: peak.lon,
                                                   lat: peak.lat, referenceTime: peak.referenceTime ?? peak.scannedAt ?? "",
                                                   network: peak.network ?? "de", scannedAt: peak.scannedAt, bytes: peak.bytes,
                                                   tier: peak.tier ?? 2, system: peak.system, peakDbz: peak.peakDbz,
                                                   areaKm2: peak.areaKm2)
        }
    }

    // MARK: Gestures

    private func installGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        let tilt = UIPanGestureRecognizer(target: self, action: #selector(tilted(_:)))
        tilt.minimumNumberOfTouches = 2
        tilt.maximumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        let rotate = UIRotationGestureRecognizer(target: self, action: #selector(rotated(_:)))
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        tap.require(toFail: double)
        for recognizer in [pan, tilt, pinch, rotate, tap, double] as [UIGestureRecognizer] {
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
        }
    }

    /// The map moves under the finger even where a storm's tag is: a drag,
    /// pinch or turn that starts on one cancels its tap. A tap on a tag is
    /// the tag's own, and the HUD keeps its touches.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let view = touch.view else { return true }
        if let hud, view.isDescendant(of: hud) { return false }
        return !(gestureRecognizer is UITapGestureRecognizer && view.isDescendant(of: labels))
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Pinch and turn together, as a map does; a tilt alone.
        let pair: Set<String> = [String(describing: UIPinchGestureRecognizer.self), String(describing: UIRotationGestureRecognizer.self)]
        return pair.contains(String(describing: type(of: gestureRecognizer))) && pair.contains(String(describing: type(of: other)))
    }

    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        touched()
        let translation = recognizer.translation(in: metalView)
        recognizer.setTranslation(.zero, in: metalView)
        let perPoint = camera.metresPerPoint(height: Double(metalView.bounds.height))
        // Towards the top of the screen is ahead; tilted, the ground there is further.
        let ahead = Double(translation.y) * perPoint / max(cos(camera.pitch * .pi / 180), 0.35)
        let across = -Double(translation.x) * perPoint
        let b = camera.bearing * .pi / 180
        let east = across * cos(b) + ahead * sin(b)
        let north = -across * sin(b) + ahead * cos(b)
        let moved = Geo.destination(lat: camera.latitude, lon: camera.longitude, bearing: atan2(east, north) * 180 / .pi,
                                    metres: hypot(east, north))
        camera.latitude = min(max(moved.lat, -80), 80)
        camera.longitude = moved.lon
        map?.model.detour?.camera = nil
        if recognizer.state == .ended { cameraSettled() }
    }

    @objc private func tilted(_ recognizer: UIPanGestureRecognizer) {
        touched()
        let translation = recognizer.translation(in: metalView)
        recognizer.setTranslation(.zero, in: metalView)
        camera.pitch = min(max(camera.pitch - Double(translation.y) * 0.3, OrbitCamera.pitches.lowerBound), OrbitCamera.pitches.upperBound)
    }

    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        touched()
        camera.distance = min(max(camera.distance / Double(recognizer.scale), OrbitCamera.distances.lowerBound), OrbitCamera.distances.upperBound)
        recognizer.scale = 1
        map?.model.detour?.camera = nil
        if recognizer.state == .ended { cameraSettled() }
    }

    @objc private func rotated(_ recognizer: UIRotationGestureRecognizer) {
        touched()
        camera.bearing = Geo.normalise(camera.bearing - Double(recognizer.rotation) * 180 / .pi)
        recognizer.rotation = 0
    }

    /// A tap on a storm opens it, as core's click does: its panel at once
    /// and the storm cut open; a tap on open sky closes the one open.
    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        touched()
        guard let pose = lastPose, let scene else { return }
        let key = scene.pick(recognizer.location(in: metalView), pose: pose, targets: drawn)?.key
        select(key, toggle: false)
        if let key {
            open(key)
        } else if map?.model.selectedStorm != nil {
            map?.model.selectedStorm = nil
        }
    }

    /// Every gesture's alternative for VoiceOver, Voice Control and Switch
    /// Control: zoom, turn and tilt in steps.
    private func installActions() {
        func action(_ key: String, _ change: @escaping (inout OrbitCamera) -> Void) -> UIAccessibilityCustomAction {
            UIAccessibilityCustomAction(name: NSLocalizedString(key, comment: "")) { [weak self] _ in
                guard let self else { return false }
                self.touched()
                change(&self.camera)
                self.map?.model.detour?.camera = nil
                self.cameraSettled()
                return true
            }
        }
        let distances = OrbitCamera.distances, pitches = OrbitCamera.pitches
        metalView.accessibilityCustomActions = [
            action("native_map_3d_zoom_in") { $0.distance = max(distances.lowerBound, $0.distance / 2) },
            action("native_map_3d_zoom_out") { $0.distance = min(distances.upperBound, $0.distance * 2) },
            action("native_map_3d_turn_left") { $0.bearing = Geo.normalise($0.bearing - 45) },
            action("native_map_3d_turn_right") { $0.bearing = Geo.normalise($0.bearing + 45) },
            action("native_map_3d_tilt") { $0.pitch = min(pitches.upperBound, $0.pitch + 20) },
            action("native_map_3d_flat") { $0.pitch = pitches.lowerBound },
        ]
    }

    @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
        touched()
        camera.distance = max(OrbitCamera.distances.lowerBound, camera.distance / 2)
        cameraSettled()
    }

    /// The storms are fetched around where the camera looks; far enough
    /// away the scene is moved under it.
    private func cameraSettled() {
        feed.viewer = (camera.latitude, camera.longitude)
        guard let scene, let map, let renderer else { return }
        let away = Geo.distanceBearing(fromLat: scene.frame.latitude, lon: scene.frame.longitude,
                                       toLat: camera.latitude, lon: camera.longitude).metres
        // Far from the scene's origin: moved under the camera, once the
        // ground for there is ready, so the old one stays until it is.
        if away > 150_000 {
            let next = GeoFrame(latitude: camera.latitude, longitude: camera.longitude, altitude: 0)
            let fresh = StormScene(frame: next)
            fresh.palette = scene.palette
            ground.build(camera, key: groundKey(map, scene: scene), scene: fresh, device: renderer.device, radar: map.radar,
                         dark: map.model.isDark, terrain: map.isOn(.terrain3d), replacing: true) { [weak self] in
                self?.scene?.move(to: next)
            }
        }
    }

    /// What the ground is built for: the radar step and its palette, the
    /// map's look, the terrain switch.
    private func groundKey(_ map: NativeMapContext, scene: StormScene) -> String {
        "\(stepKey)|\(map.model.isDark)|\(map.isOn(.terrain3d))|\(scene.palette)"
    }

    // MARK: Drawing

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { render(in: view) }
    }

    private func render(in view: MTKView) {
        let started = CACurrentMediaTime()
        defer {
            if FrameTiming.on {
                timing.frame(cpu: CACurrentMediaTime() - started, storms: drawn.count,
                             drawable: view.drawableSize, scale: renderer?.resolutionScale ?? 0)
            }
        }
        guard let map else { return }
        if framePending {
            guard map.mapView.bounds.height > 0 else { return }
            frame(from: map.mapView, zoom: map.zoomLevel)
        }
        guard let renderer, let scene else { return }
        renderer.resolutionScale = resolution.scale
        if CACurrentMediaTime() - touchedAt > Self.idleAfter, view.preferredFramesPerSecond != 30 {
            view.preferredFramesPerSecond = 30
        }
        let viewport = view.bounds.size
        guard viewport.width > 0 else { return }
        let pose = camera.pose(in: scene, viewport: viewport)
        lastPose = pose
        let key = groundKey(map, scene: scene)
        if ground.wants(camera, key: key) {
            ground.build(camera, key: key, scene: scene, device: renderer.device, radar: map.radar, dark: map.model.isDark,
                         terrain: map.isOn(.terrain3d))
        }
        scene.now = Date()
        scene.alignmentError = 0
        // Placed again only when the storms or the scene's origin change: the
        // boxes stand still between scans, and placing them all each frame
        // was most of a frame's time on a phone.
        let placeKey = PlaceKey(revision: feed.revision, latitude: scene.frame.latitude, longitude: scene.frame.longitude)
        if placeKey != placedFor {
            placedFor = placeKey
            placed = scene.placeAll(feed.nearbyEntries, volumes: feed.volumes) { [feed] in feed.cell(for: $0) }
            groups = scene.groups(placed)
            groupByKey = Dictionary(uniqueKeysWithValues: groups.map { ($0.key, $0) })
            drawn = drawTargets(scene: scene, groupByKey: groupByKey)
        }
        if opened != nil, openedKey == nil { resolveOpened() }
        scene.openCut = openCut()
        let light = scene.light()
        let target = CGSize(width: view.drawableSize.width * renderer.resolutionScale,
                            height: view.drawableSize.height * renderer.resolutionScale)
        let eye = SIMD3<Double>(pose.position)
        let storms = drawn.compactMap { storm, group -> StormRenderer.Storm? in
            guard let volume = storm.volume, volume.marchBounds != nil else { return nil }
            var uniforms = scene.uniforms(for: storm, group: group, volume: volume, pose: pose, target: target, light: light)
            // Taller than life, as the ground is; and never grey, however
            // far the scan is behind (a storm in colour reads as a storm).
            let stretched = ThreeDScale.stretch * storm.boxToWorld
            uniforms.worldToBox = simd_float4x4(converting: stretched.inverse)
            uniforms.behind = 0
            let centre = storm.centre + storm.up * 6_000
            return StormRenderer.Storm(path: storm.entry.path, volume: volume, uniforms: uniforms,
                                       boxToWorld: simd_float4x4(converting: stretched),
                                       distance: Float(length(centre - eye)),
                                       system: storm.entry.coarse == true ? storm.entry.path : storm.stormKey)
        }
        var lines = scene.lines(groups: groups, feed: feed, pose: pose)
        lines.under = lines.under.map(Self.stretch)
        lines.over = lines.over.map(Self.stretch)
        // KONRAD3D's cells as solids, where the switch is on; not inside a
        // radar volume that draws the same weather measured another way.
        var solids: StormRenderer.Solids?
        if map.isOn(.cells3d) {
            let nearby = feed.cells.filter { cell in
                Geo.distanceBearing(fromLat: camera.latitude, lon: camera.longitude, toLat: cell.lat, lon: cell.lon).metres <= StormFeed.rangeMetres
            }
            var hasher = Hasher()
            for cell in nearby {
                hasher.combine(cell.code)
                hasher.combine(cell.t)
            }
            let key = "\(hasher.finalize())|\(scene.frame.latitude),\(scene.frame.longitude)|\(scene.palette)"
            cellSolids.update(cells: nearby, hidden: Self.insideVolumes(nearby, drawn: drawn), scene: scene, device: renderer.device, key: key)
            solids = cellSolids.current
            lines.under += cellSolids.footprints
        }
        renderer.retain(only: Set(feed.volumes.keys))
        let background: StormRenderer.Background = ground.current.map { .map($0) } ?? .sky(horizonDip: 0)
        renderer.draw(StormRenderer.Frame(background: background, pose: pose, storms: storms, under: lines.under, over: lines.over,
                                          solids: solids),
                      in: view)
        updateOverlays(pose: pose)
        if abs(state.bearing - camera.bearing) > 0.5 { state.bearing = camera.bearing }
        if state.tilted != (camera.pitch > Self.flatPitch) { state.tilted = camera.pitch > Self.flatPitch }
        #if DEBUG
        // The camera's tilt and turn, and whether a storm is drawn cut open.
        let tilt = "\(Int(camera.pitch.rounded())),\(Int(CutAngle.normalise(camera.bearing.rounded())))"
            + String(format: ",%.2f,%.2f", camera.latitude, camera.longitude) + (scene.openCut != nil ? ",cut" : "")
        if view.accessibilityValue != tilt { view.accessibilityValue = tilt }
        #endif
    }

    /// The cells standing inside a drawn volume's box (core's `hiddenCodes`).
    private static func insideVolumes(_ cells: [TrackedCell], drawn: [(storm: PlacedStorm, group: StormGroup)]) -> Set<String> {
        let boxes = drawn.compactMap { storm, _ -> (lon: Double, lat: Double, halfX: Double, halfY: Double)? in
            guard let volume = storm.volume else { return nil }
            return (storm.entry.lon, storm.entry.lat, volume.extentM.x / 2000, volume.extentM.y / 2000)
        }
        guard !boxes.isEmpty else { return [] }
        return Set(cells.filter { cell in
            boxes.contains { box in
                abs((cell.lon - box.lon) * 111.32 * cos(box.lat * .pi / 180)) <= box.halfX && abs((cell.lat - box.lat) * 110.57) <= box.halfY
            }
        }.map(\.code))
    }

    private static func stretch(_ line: WorldLine) -> WorldLine {
        var line = line
        line.a.y *= Float(ThreeDScale.vertical)
        line.b.y *= Float(ThreeDScale.vertical)
        return line
    }

    private func drawTargets(scene: StormScene, groupByKey: [String: StormGroup]) -> [(storm: PlacedStorm, group: StormGroup)] {
        let placedByPath = Dictionary(placed.map { ($0.entry.path, $0) }, uniquingKeysWith: { first, _ in first })
        return feed.drawPlan().compactMap { unit -> (storm: PlacedStorm, group: StormGroup)? in
            if unit.coarse != true {
                guard let storm = placedByPath[unit.path], let group = groupByKey[storm.stormKey] else { return nil }
                return (storm, group)
            }
            let inside = placed.filter { $0.entry.coarseParent == unit.tile }
            var count: [String: Int] = [:]
            for storm in inside { count[storm.stormKey, default: 0] += 1 }
            guard let key = count.max(by: { a, b in a.value != b.value ? a.value < b.value
                      : (groupByKey[a.key]?.peakDbz ?? 0) < (groupByKey[b.key]?.peakDbz ?? 0) })?.key,
                  let group = groupByKey[key] else { return nil }
            return (scene.place(unit, volume: feed.volumes[unit.path], cell: group.cell), group)
        }
    }

    private func updateOverlays(pose: CameraPose) {
        guard let scene else { return }
        let now = Date()
        func project(_ p: SIMD3<Double>) -> CGPoint? {
            pose.project(SIMD3<Float>(Float(p.x), Float(p.y * ThreeDScale.vertical), Float(p.z)))
        }
        if now.timeIntervalSince(labelsBuiltAt) > 0.5 {
            // A map is not looked at from where its origin is: no distance
            // and bearing, the storm's own numbers lead. The selected storm
            // and the strongest few on screen are named, not every shower.
            let bounds = bounds.insetBy(dx: 20, dy: 60)
            let shown = groups.filter { group in project(group.anchor).map(bounds.contains) ?? false }
                .sorted { ($0.peakDbz ?? 0) > ($1.peakDbz ?? 0) }
                .prefix(4)
            let keys = Set(shown.map { $0.key } + [scene.selectedKey].compactMap { $0 })
            labelModels = Dictionary(uniqueKeysWithValues: groups.filter { keys.contains($0.key) }.map { group in
                let label = scene.label(for: group, feed: feed)
                return (group.key, StormLabelModel(key: label.key, code: label.code, title: label.detail, detail: "",
                                                   flags: label.flags, age: label.age, openable: label.openable,
                                                   selected: label.selected, distance: label.distance))
            })
            labelsBuiltAt = now
            refreshStatus()
        }
        labels.layout(groups.compactMap { group in labelModels[group.key].map { ($0, project(group.anchor)) } })
        if let userLocation, let at = project(scene.world(latitude: userLocation.latitude, longitude: userLocation.longitude, altitude: 0)),
           bounds.insetBy(dx: -20, dy: -20).contains(at) {
            locationDot.center = at
            locationDot.isHidden = false
        } else {
            locationDot.isHidden = true
        }
        let selected = groups.first { $0.key == scene.selectedKey }
        labels.layoutTicks(selected.map { group in
            scene.heightTicks(for: group, pose: pose).map { tick in
                (tick.km, pose.project(SIMD3(tick.point.x, tick.point.y * Float(ThreeDScale.vertical), tick.point.z)))
            }
        } ?? [])
    }
}

// MARK: - Controls

/// The 3D map's tray: the ways to look into the storms, the slider of the
/// one chosen, north, and what the feed is doing.
struct ThreeDHUD: View {
    @ObservedObject var state: ThreeDState
    @ObservedObject var model: NativeMapModel

    private var theme: ChromeTheme { ChromeTheme(dark: model.isDark) }

    var body: some View {
        VStack(spacing: 8) {
            if let note = state.scanNote ?? state.status {
                Text(note)
                    .scaledFont(13, weight: .semibold, relativeTo: .footnote)
                    .foregroundStyle(theme.text)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .chromeGlass(theme, in: Capsule())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier(state.scanNote != nil ? "nativeMap.3d.scanNote" : "nativeMap.3d.status")
            }
            HStack {
                scanPicker
                Spacer()
                Button(action: state.openGuide) {
                    Text(CoreStrings.t("guide_3d.pill"))
                        .scaledFont(13, weight: .semibold, relativeTo: .footnote)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .foregroundStyle(theme.text)
                        .chromeGlass(theme, in: Capsule(), interactive: true)
                        .hitTarget()
                }
                .buttonStyle(PressScale())
                .accessibilityHint(CoreStrings.t("guide_3d.open"))
                .accessibilityIdentifier("nativeMap.3d.guideButton")
                if state.selected != nil {
                    Button(action: state.open) {
                        HStack(spacing: 4) {
                            Text(CoreStrings.t("storm.hint.details"))
                            Image(systemName: "chevron.right").imageScale(.small)
                        }
                        .scaledFont(13, weight: .semibold, relativeTo: .footnote)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .foregroundStyle(theme.accent)
                        .chromeGlass(theme, in: Capsule(), interactive: true)
                        .hitTarget()
                    }
                    .buttonStyle(PressScale())
                    .accessibilityIdentifier("nativeMap.3d.details")
                }
                Button(action: state.tilt) {
                    Text(state.tilted ? "2D" : "3D")
                        .scaledFont(13, weight: .semibold, relativeTo: .footnote)
                        .foregroundStyle(theme.text)
                        .frame(width: 40, height: 40)
                        .chromeGlass(theme, in: Circle(), interactive: true)
                        .hitTarget()
                }
                .buttonStyle(PressScale())
                .accessibilityLabel(NSLocalizedString(state.tilted ? "native_map_3d_flat" : "native_map_3d_tilt", comment: ""))
                .accessibilityIdentifier("nativeMap.3d.tilt")
                Button(action: state.north) {
                    Image(systemName: "location.north.line.fill")
                        .scaledFont(15, weight: .semibold, relativeTo: .subheadline)
                        .rotationEffect(.degrees(-state.bearing))
                        .foregroundStyle(theme.text)
                        .frame(width: 40, height: 40)
                        .chromeGlass(theme, in: Circle(), interactive: true)
                        .hitTarget()
                }
                .buttonStyle(PressScale())
                .accessibilityLabel(NSLocalizedString("compass_N", comment: ""))
                .accessibilityIdentifier("nativeMap.3d.north")
            }
            VStack(spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(ThreeDMapView.modes) { mode in
                            Button { state.setMode(mode) } label: {
                                Text(mode.title)
                                    .scaledFont(13, weight: .semibold, relativeTo: .footnote)
                                    .padding(.horizontal, 12)
                                    .frame(height: 32)
                                    .foregroundStyle(state.mode == mode ? Color.white : theme.text)
                                    .background(state.mode == mode ? theme.accent : theme.tint, in: Capsule())
                            }
                            .buttonStyle(PressScale())
                            .accessibilityAddTraits(state.mode == mode ? .isSelected : [])
                            .accessibilityIdentifier("nativeMap.3d.mode.\(mode.rawValue)")
                        }
                    }
                    .padding(.horizontal, 2)
                }
                if let slider = state.mode.slider {
                    HStack(spacing: 10) {
                        Slider(value: Binding(get: { state.slider }, set: { state.setSlider($0) }), in: slider.range)
                            .accessibilityIdentifier("nativeMap.3d.slider")
                        Text(state.sliderText)
                            .scaledFont(13, weight: .semibold, relativeTo: .footnote, digits: true)
                            .foregroundStyle(theme.text2)
                            .frame(minWidth: 64, alignment: .trailing)
                    }
                }
            }
            .padding(12)
            .chromeGlass(theme, in: RoundedRectangle(cornerRadius: ChromeTheme.trayRadius, style: .continuous))
        }
        .environment(\.colorScheme, theme.colorScheme)
    }
}

extension ThreeDHUD {
    /// Newest first; one picked so long ago the newest has moved two hours on
    /// stays in the list (`ScanPicker.svelte`'s `withShown`).
    var offeredScans: [Int] {
        guard let newest = state.newestScan else { return [] }
        let scans = ScanHistory.earlierScans(newest: newest)
        guard let shown = state.scanShown, !scans.contains(shown) else { return scans }
        return scans + [shown]
    }

    /// "-35m", "-1h", "-1h5m" behind the newest, as the timeline marks its steps.
    static func behind(_ scan: Int, from newest: Int) -> String {
        let minutes = Int((Double(newest - scan) / 60).rounded())
        if minutes % 60 == 0 { return CoreStrings.t("chrome.playback.offset_hours", ["sign": "-", "hours": minutes / 60]) }
        if minutes < 60 { return CoreStrings.t("chrome.playback.offset_minutes", ["sign": "-", "minutes": minutes]) }
        return CoreStrings.t("chrome.playback.offset_hours_minutes", ["sign": "-", "hours": minutes / 60, "minutes": minutes % 60])
    }

    /// A row: the scan's time, how far behind the newest it is, checked
    /// while it is the one on the map; nil is "Latest".
    private func scanRow(_ name: String, when: String?, scan: Int?) -> some View {
        Toggle(isOn: Binding(get: { state.scanShown == scan }, set: { _ in state.pickScan(scan) })) {
            Text(name)
            if let when { Text(when) }
        }
    }

    /// "Latest", or one of the last two hours' scans (`ScanPicker.svelte`):
    /// filled with its time while the map is not live.
    @ViewBuilder
    var scanPicker: some View {
        let theme = ChromeTheme(dark: model.isDark)
        let face = state.scanLoading ?? state.scanShown
        Menu {
            // Toggles, for the system's check on the scan on the map and a
            // subtitle under each time.
            Section(CoreStrings.t("time_3d.title")) {
                scanRow(CoreStrings.t("time_3d.latest"), when: state.newestScan.map(StatusPill.clock), scan: nil)
                ForEach(offeredScans, id: \.self) { scan in
                    scanRow(StatusPill.clock(scan), when: state.newestScan.map { Self.behind(scan, from: $0) }, scan: scan)
                }
            }
        } label: {
            HStack(spacing: 6) {
                if state.scanLoading != nil {
                    ProgressView(value: state.scanProgress).progressViewStyle(.circular).controlSize(.mini)
                } else {
                    Image(systemName: "clock.arrow.circlepath").scaledFont(13, weight: .semibold, relativeTo: .footnote)
                }
                Text(face.map(StatusPill.clock) ?? CoreStrings.t("time_3d.latest"))
                    .scaledFont(13, weight: .semibold, relativeTo: .footnote, digits: true)
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .foregroundStyle(state.scanShown != nil ? Color.white : theme.text)
            .background(state.scanShown != nil ? AnyShapeStyle(theme.accent) : AnyShapeStyle(Color.clear), in: Capsule())
            .chromeGlass(theme, in: Capsule(), interactive: true)
            .hitTarget()
        }
        .accessibilityLabel(face.map { CoreStrings.t("time_3d.past_aria", ["time": StatusPill.clock($0)]) } ?? CoreStrings.t("time_3d.latest_aria"))
        .accessibilityHint(CoreStrings.t("time_3d.choose"))
        .accessibilityIdentifier("nativeMap.3d.scan")
    }
}

/// The 3D map's frame times on the console every two seconds, while
/// `MC_FRAME_TIMING` is set: frames a second, the main thread's time per
/// frame and the GPU's.
/// The storms' render resolution, kept to what the GPU draws in time: a
/// phone's GPU raymarching dozens of storms took longer than a frame at the
/// simulator's half resolution. Lowered while frames run long, raised again
/// when there is room, a step a second at most.
final class AdaptiveResolution: @unchecked Sendable {
    static let range: ClosedRange<CGFloat> = 0.3 ... 0.5
    static let step: CGFloat = 0.05
    /// Under 60 Hz's 16.7 ms with room for the rest of the frame.
    static let slow = 0.012
    static let fast = 0.006
    private let lock = NSLock()
    private var current: CGFloat = range.upperBound
    private var times: [Double] = []
    private var changedAt = CACurrentMediaTime()

    var scale: CGFloat { lock.withLock { current } }

    /// A frame's GPU time, from Metal's thread.
    func report(_ seconds: Double) {
        lock.withLock {
            times.append(seconds)
            let now = CACurrentMediaTime()
            guard times.count >= 20, now - changedAt >= 1 else { return }
            let typical = times.sorted()[times.count / 2]
            times.removeAll(keepingCapacity: true)
            changedAt = now
            if typical > Self.slow {
                current = max(Self.range.lowerBound, current - Self.step)
            } else if typical < Self.fast {
                current = min(Self.range.upperBound, current + Self.step)
            }
        }
    }
}

final class FrameTiming: @unchecked Sendable {
    static let on = ProcessInfo.processInfo.environment["MC_FRAME_TIMING"] != nil
    private let lock = NSLock()
    private var cpu: [Double] = []
    private var gpu: [Double] = []
    private var since = CACurrentMediaTime()

    func frame(cpu seconds: Double, storms: Int, drawable: CGSize, scale: CGFloat) {
        lock.withLock {
            cpu.append(seconds)
            let now = CACurrentMediaTime()
            guard now - since >= 2 else { return }
            func ms(_ values: [Double], _ f: ([Double]) -> Double) -> String {
                values.isEmpty ? "-" : String(format: "%.1f", f(values) * 1000)
            }
            let sorted = cpu.sorted()
            let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            print(String(format: "FRAMES fps=%.1f", Double(cpu.count) / (now - since)),
                  "cpu avg=\(ms(cpu) { $0.reduce(0, +) / Double($0.count) }) p95=\(ms([p95]) { $0[0] }) max=\(ms(cpu) { $0.max()! })",
                  "gpu avg=\(ms(gpu) { $0.reduce(0, +) / Double($0.count) }) max=\(ms(gpu) { $0.max()! })",
                  "storms=\(storms) drawable=\(Int(drawable.width))x\(Int(drawable.height)) scale=\(scale)")
            fflush(stdout)
            cpu.removeAll(keepingCapacity: true)
            gpu.removeAll(keepingCapacity: true)
            since = now
        }
    }

    func gpu(_ seconds: Double) {
        lock.withLock { gpu.append(seconds) }
    }
}

// MARK: - The part

/// Shows the 3D map while `cells3d` is the map, and hands the camera back
/// to the flat map when it goes.
@MainActor
final class ThreeDMap: NativeMapFeature {
    private weak var map: NativeMapContext?
    private var view: ThreeDMapView?

    func attach(to map: NativeMapContext) {
        self.map = map
    }

    func capabilityDidChange(_ capability: NativeMapModel.Capability) {
        guard let map else { return }
        if capability == .cells3d {
            let view = self.view ?? makeView(map)
            view.isHidden = false
            view.show()
        } else if let view, !view.isHidden {
            view.hide()
            view.isHidden = true
            // The flat map takes up where the 3D one was looking.
            let camera = view.camera
            map.place(NativeMapLink(latitude: camera.latitude, longitude: camera.longitude,
                                    zoom: min(max(camera.zoom(height: Double(map.mapView.bounds.height)), 3), 14)), animated: false)
        }
    }

    private func makeView(_ map: NativeMapContext) -> ThreeDMapView {
        let view = ThreeDMapView(map: map)
        view.translatesAutoresizingMaskIntoConstraints = false
        // Over the flat map, under the app's controls and the map's chrome.
        map.view.insertSubview(view, aboveSubview: map.mapView)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: map.view.topAnchor),
            view.bottomAnchor.constraint(equalTo: map.view.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: map.view.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: map.view.trailingAnchor),
        ])
        self.view = view
        return view
    }

    func settingsDidChange() { view?.applySettings() }

    func stepDidChange(_ step: RadarStep) { view?.stepChanged(step) }

    /// A link's `pitch` and `bearing`, and its view, for the 3D map shown
    /// (core's `parseLink`: tilted at most 85, turned folded).
    func open(_ link: [String: String]) -> Bool {
        guard let map, map.model.capability == .cells3d else { return false }
        func number(_ key: String) -> Double? { link[key].flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil } }
        let camera = ThreeDMapView.LinkCamera(view: link["latLonZ"].flatMap { NativeMapLink(search: "latLonZ=" + $0) },
                                              pitch: number("pitch").map { min(max($0, 0), 85) },
                                              bearing: number("bearing").map(CutAngle.normalise))
        guard camera.view != nil || camera.pitch != nil || camera.bearing != nil else { return false }
        (view ?? makeView(map)).applyLink(camera)
        // The storm, the cut, the point are other parts'.
        return false
    }

    func linkParameters() -> [String: String] {
        guard let view, map?.model.capability == .cells3d else { return [:] }
        return ["pitch": String(Int(view.camera.pitch.rounded())),
                "bearing": String(Int(CutAngle.normalise(view.camera.bearing.rounded())))]
    }

    func lookAt(_ coordinate: CLLocationCoordinate2D, zoom: Double?) -> Bool {
        guard let view, map?.model.capability == .cells3d else { return false }
        view.lookAt(coordinate, zoom: zoom)
        return true
    }

    func linkView() -> NativeMapLink? {
        guard let view, let map, map.model.capability == .cells3d else { return nil }
        let camera = view.camera
        return NativeMapLink(latitude: camera.latitude, longitude: camera.longitude,
                             zoom: camera.zoom(height: Double(map.mapView.bounds.height)))
    }

    func wake() {
        if map?.model.capability == .cells3d { view?.wake() }
    }

    func stop() { view?.hide() }
}

/// The reader on the 3D map: MapKit's blue dot, white-rimmed, over the
/// ground where they are.
final class LocationDot: UIView {
    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 22, height: 22))
        isUserInteractionEnabled = false
        isHidden = true
        backgroundColor = .white
        layer.cornerRadius = 11
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.3
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 1)
        let core = UIView(frame: bounds.insetBy(dx: 4, dy: 4))
        core.backgroundColor = .systemBlue
        core.layer.cornerRadius = 7
        addSubview(core)
        isAccessibilityElement = true
        accessibilityLabel = NSLocalizedString("my_location", comment: "")
        accessibilityIdentifier = "nativeMap.3d.location"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
