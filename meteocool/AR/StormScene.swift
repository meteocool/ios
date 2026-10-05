//
//  StormScene.swift
//  meteocool
//
//  What the AR view draws this frame, and where.
//

import Foundation
import simd

/// The ways of looking at a storm. Each changes how the volume is drawn; a
/// mode with a slider applies the slider to the selected storm, or to every
/// storm when none is selected.
enum ARViewMode: String, CaseIterable, Identifiable, Sendable {
    /// The storm as on the 3D map.
    case live
    /// Strip the shell down to the core.
    case peel
    /// A vertical cut facing the viewer, moved through the storm like a scan.
    case slice
    /// A vertical cut through the core, turned away from the line of sight.
    case turn
    /// The 3D map's own cut, along the storm's track, where an overhang shows.
    case track
    /// Everything below a height removed: the reflectivity at that height,
    /// seen from underneath (a CAPPI).
    case floor
    /// Thin surfaces at three reflectivities.
    case shells
    /// The lowest kilometre and a half: what reaches the ground.
    case shaft
    /// Above 8 km: the anvil and any overshooting top.
    case tops
    /// What the radars saw, and where they could not look.
    case radar
    /// Where the storm is heading: forecast ellipses, track and motion.
    case nowcast

    var id: String { rawValue }

    var title: String { NSLocalizedString("ar_mode_\(rawValue)", comment: "AR view mode") }

    struct Slider: Equatable, Sendable {
        let range: ClosedRange<Double>
        let initial: Double
        /// Format for the value, with one `%@` for the number.
        let format: String
    }

    var slider: Slider? {
        switch self {
        case .peel: return Slider(range: 0 ... 1, initial: 0.5, format: "%@ dBZ")
        case .slice: return Slider(range: -15 ... 15, initial: 0, format: "%@ km")
        case .turn: return Slider(range: -80 ... 80, initial: 45, format: "%@°")
        case .track: return Slider(range: -10 ... 10, initial: 0, format: "%@ km")
        case .floor: return Slider(range: 1 ... 12, initial: 4, format: "%@ km")
        default: return nil
        }
    }

    /// Whether the mode needs a tracked cell's heading.
    var needsMotion: Bool { self == .track }
}

/// Where the camera is and how it projects, in the world frame: ARKit's,
/// x east, y up, z south, metres, origin where the session started.
struct CameraPose {
    var view: simd_float4x4
    var projection: simd_float4x4
    var position: SIMD3<Float>
    /// Points, the size the projection was made for.
    var viewport: CGSize

    var viewProjection: simd_float4x4 { projection * view }
    var forward: SIMD3<Float> {
        let inverse = view.inverse
        return -normalize(SIMD3(inverse.columns.2.x, inverse.columns.2.y, inverse.columns.2.z))
    }

    /// Screen point (points, origin top left) of a world point, or nil behind the camera.
    func project(_ p: SIMD3<Float>) -> CGPoint? {
        let clip = viewProjection * SIMD4(p, 1)
        guard clip.w > 0.01 else { return nil }
        let ndc = SIMD2(clip.x, clip.y) / clip.w
        return CGPoint(x: CGFloat(ndc.x + 1) / 2 * viewport.width, y: CGFloat(1 - ndc.y) / 2 * viewport.height)
    }

    /// The world ray through a screen point.
    func ray(through point: CGPoint) -> (origin: SIMD3<Float>, direction: SIMD3<Float>) {
        let ndc = SIMD2(Float(point.x / viewport.width) * 2 - 1, 1 - Float(point.y / viewport.height) * 2)
        let far = viewProjection.inverse * SIMD4(ndc.x, ndc.y, 0.5, 1)
        return (position, normalize(SIMD3(far.x, far.y, far.z) / far.w - position))
    }

    /// Horizontal field of view in degrees.
    var horizontalFOV: Double {
        2 * atan(1 / Double(projection.columns.0.x)) * 180 / .pi
    }
}

/// A world-space line segment the renderer draws a fixed number of pixels wide.
struct WorldLine {
    var a: SIMD3<Float>
    var b: SIMD3<Float>
    /// Straight RGBA, not premultiplied.
    var colour: SIMD4<Float>
    var width: Float
}

/// One storm's box, placed.
struct PlacedStorm {
    let entry: StormEntry
    let volume: StormVolume?
    let cell: TrackedCell?
    /// Unit cube to world.
    let boxToWorld: simd_double4x4
    let worldToBox: simd_double4x4
    /// The core at sea level, and the box's own axes, in the world.
    let centre: SIMD3<Double>
    let east: SIMD3<Double>
    let north: SIMD3<Double>
    let up: SIMD3<Double>
    let distance: Double
    let bearing: Double
    /// Where the label floats: over the echo top.
    let anchor: SIMD3<Double>
    /// Minutes the box was moved along the cell's track, when extrapolating.
    let extrapolatedMinutes: Double?
    let age: TimeInterval?
}

/// Everything about one storm a label needs.
struct StormLabelModel: Equatable {
    let path: String
    let code: String
    let title: String
    let detail: String
    let flags: [String]
    let age: String
    let openable: Bool
    let selected: Bool
    let distance: Double
}

/// What the scene turns into uniforms, lines and labels each frame.
@MainActor
final class StormScene {
    /// Where the viewer stood when the frame was set; the world's origin.
    private(set) var frame: GeoFrame
    var alignmentError: Double = 0
    var mode: ARViewMode = .live
    var sliderValue: Double = 0
    var extrapolate = false
    var showLightning = true
    var selectedPath: String?
    var palette = "classic"
    var now = Date()

    /// Old enough that the storm has visibly moved since: drawn in greys,
    /// as the map draws a storm a scan behind its radar.
    static let staleAfter: TimeInterval = 15 * 60
    /// Dead reckoning goes no further than this: past it the motion vector
    /// is a guess about a storm that may have turned or died.
    static let maxExtrapolationMinutes = 30.0
    /// How far over the ground the ground overlays are drawn, in metres.
    static let overlayHeight = 1_000.0
    /// How much of its opacity a storm keeps when it cannot be opened (core's DIM_UNOPENABLE).
    static let dimUnopenable: Float = 0.45

    init(frame: GeoFrame) {
        self.frame = frame
    }

    func move(to frame: GeoFrame) { self.frame = frame }

    /// The ground the viewer stands on, in metres above sea level.
    var groundAltitude: Double { max(0, frame.altitude - 1.6) }

    // MARK: Frames

    /// The viewer's ENU frame in the world: rotated by the heading error, then
    /// ARKit's axes (x east, y up, z south).
    var enuToWorld: simd_double4x4 {
        let ε = alignmentError * .pi / 180
        // Counter-clockwise about up by ε, which takes `ε` off every azimuth.
        let rotation = simd_double4x4(columns: (
            SIMD4(cos(ε), sin(ε), 0, 0),
            SIMD4(-sin(ε), cos(ε), 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(0, 0, 0, 1)))
        let swap = simd_double4x4(columns: (
            SIMD4(1, 0, 0, 0),   // east -> x
            SIMD4(0, 0, -1, 0),  // north -> -z
            SIMD4(0, 1, 0, 0),   // up -> y
            SIMD4(0, 0, 0, 1)))
        return swap * rotation
    }

    func world(latitude: Double, longitude: Double, altitude: Double) -> SIMD3<Double> {
        let enu = frame.enu(latitude: latitude, longitude: longitude, altitude: altitude)
        let w = enuToWorld * SIMD4(enu, 1)
        return SIMD3(w.x, w.y, w.z)
    }

    private func worldDirection(_ enu: SIMD3<Double>) -> SIMD3<Double> {
        let w = enuToWorld * SIMD4(enu, 0)
        return SIMD3(w.x, w.y, w.z)
    }

    /// True azimuth, in degrees, of a world direction.
    func trueAzimuth(ofWorld direction: SIMD3<Float>) -> Double {
        Geo.normalise(atan2(Double(direction.x), Double(-direction.z)) * 180 / .pi + alignmentError)
    }

    /// Azimuth in ARKit's own frame, taking its -z as north.
    static func frameAzimuth(ofWorld direction: SIMD3<Float>) -> Double {
        Geo.normalise(atan2(Double(direction.x), Double(-direction.z)) * 180 / .pi)
    }

    static func elevation(ofWorld direction: SIMD3<Float>) -> Double {
        asin(Double(max(-1, min(1, normalize(direction).y)))) * 180 / .pi
    }

    // MARK: Placement

    func place(_ entry: StormEntry, volume: StormVolume?, cell: TrackedCell?) -> PlacedStorm {
        let age = entry.scanDate.map { now.timeIntervalSince($0) }
        var lat = entry.lat, lon = entry.lon
        var extrapolated: Double?
        if extrapolate, let cell, let age, cell.speedKmh != nil, cell.headingDeg != nil {
            let minutes = min(max(age / 60, 0), Self.maxExtrapolationMinutes)
            (lat, lon) = DeadReckoning.advance(lat: lat, lon: lon, headingDeg: cell.headingDeg,
                                               speedKmh: cell.speedKmh, minutes: minutes)
            extrapolated = minutes
        }
        let boxFrame = GeoFrame(latitude: lat, longitude: lon, altitude: 0)
        let axes = frame.axes(of: boxFrame)
        let east = worldDirection(axes.east), north = worldDirection(axes.north), up = worldDirection(axes.up)
        let centre = world(latitude: lat, longitude: lon, altitude: 0)

        // The box's grid, or core's standard 40 x 40 x 16 km around the core
        // when the volume has not loaded yet.
        let extent = volume?.extentM ?? SIMD3(40_000, 40_000, 16_000)
        let origin = volume?.originM ?? SIMD3(-20_000, -20_000, 0)
        let corner = centre + east * origin.x + north * origin.y + up * origin.z
        let boxToWorld = simd_double4x4(columns: (
            SIMD4(east * extent.x, 0),
            SIMD4(north * extent.y, 0),
            SIMD4(up * extent.z, 0),
            SIMD4(corner, 1)))

        let (distance, bearing) = Geo.distanceBearing(fromLat: frame.latitude, lon: frame.longitude, toLat: lat, lon: lon)
        let top = cell?.echoTopM ?? volume?.echoTopM ?? 9_000
        let anchor = centre + up * (top + 900)
        return PlacedStorm(entry: entry, volume: volume, cell: cell, boxToWorld: boxToWorld, worldToBox: boxToWorld.inverse,
                           centre: centre, east: east, north: north, up: up, distance: distance, bearing: bearing,
                           anchor: anchor, extrapolatedMinutes: extrapolated, age: age)
    }

    // MARK: Volume uniforms

    /// Whether the mode's settings apply to this storm: the selected one, or
    /// all of them while none is.
    func modeApplies(to storm: PlacedStorm) -> Bool {
        selectedPath == nil || selectedPath == storm.entry.path
    }

    func uniforms(for storm: PlacedStorm, volume: StormVolume, pose: CameraPose, target: CGSize, light: SIMD3<Float>) -> VolumeUniforms {
        var u = VolumeUniforms()
        u.inverseViewProjection = pose.viewProjection.inverse
        u.worldToBox = simd_float4x4(converting: storm.worldToBox)
        u.camera = SIMD4(pose.position, 1)
        let earth = frame.groundSphere()
        let earthCentre = worldDirection(earth.centre)
        u.earth = SIMD4(Float(earthCentre.x), Float(earthCentre.y), Float(earthCentre.z), Float(earth.radius))
        u.extentKm = SIMD4(SIMD3<Float>(volume.extentM / 1000), 0)
        u.light = SIMD4(light, 0)
        u.shells = SIMD4(35, 45, 55, 0)
        u.viewport = SIMD2(Float(target.width), Float(target.height))
        u.slab = SIMD2(-1, 2)
        u.dbzFloor = Float(volume.header.dbzFloor)
        u.dbzScale = Float(volume.header.dbzScale)
        u.low = Float(StormVolume.dbzLow)
        u.steps = 96
        u.dim = storm.entry.openable ? 1 : Self.dimUnopenable
        u.behind = (storm.age ?? 0) > Self.staleAfter ? 1 : 0
        u.ghost = 0
        u.mode = 0

        let applies = modeApplies(to: storm)
        // A storm not selected while another is: drawn as itself, a little dimmer,
        // so the selected one stands out.
        if !applies { u.dim *= 0.6; return u }

        switch mode {
        case .live, .nowcast:
            break
        case .peel:
            u.low = Float(StormVolume.dbzLow + sliderValue * (volume.coreDbz - StormVolume.dbzLow))
        case .shells:
            u.mode = 1
            // Only the shells the storm reaches; a shower has no 55 dBZ shell.
            let top = volume.maxDbz
            u.shells = SIMD4(35, top >= 45 ? 45 : 999, top >= 55 ? 55 : 999, 0)
        case .radar:
            u.mode = 2
        case .shaft:
            let height = (groundAltitude + 1_500 - volume.originM.z) / volume.extentM.z
            u.slab = SIMD2(-1, Float(height))
            u.ghost = 0.12
        case .tops:
            let height = (8_000 - volume.originM.z) / volume.extentM.z
            u.slab = SIMD2(Float(height), 2)
            u.ghost = 0.12
        case .slice, .turn, .track, .floor:
            if let (point, normal) = cutPlane(for: storm, pose: pose) {
                let p = storm.worldToBox * SIMD4(point, 1)
                // Normals transform by the inverse transpose of the point map.
                let linear = simd_double3x3(columns: (
                    SIMD3(storm.boxToWorld.columns.0.x, storm.boxToWorld.columns.0.y, storm.boxToWorld.columns.0.z),
                    SIMD3(storm.boxToWorld.columns.1.x, storm.boxToWorld.columns.1.y, storm.boxToWorld.columns.1.z),
                    SIMD3(storm.boxToWorld.columns.2.x, storm.boxToWorld.columns.2.y, storm.boxToWorld.columns.2.z)))
                let n = normalize(linear.transpose * normal)
                u.planePoint = SIMD4(Float(p.x), Float(p.y), Float(p.z), 1)
                u.planeNormal = SIMD4(Float(n.x), Float(n.y), Float(n.z), 1)
            }
        }
        return u
    }

    /// The cut for the cutting modes, in the world: a point on the plane and
    /// its normal, which points at the half that is removed.
    func cutPlane(for storm: PlacedStorm, pose: CameraPose) -> (SIMD3<Double>, SIMD3<Double>)? {
        let camera = SIMD3<Double>(pose.position)
        var toStorm = storm.centre - camera
        toStorm -= dot(toStorm, storm.up) * storm.up
        guard length(toStorm) > 1 else { return nil }
        let away = normalize(toStorm)
        switch mode {
        case .slice:
            // Normal towards the viewer: the near half goes, the cut faces them.
            return (storm.centre + away * sliderValue * 1000, -away)
        case .turn:
            let θ = sliderValue * .pi / 180
            let right = cross(away, storm.up)
            let normal = -(away * cos(θ)) + right * sin(θ)
            return (storm.centre, normal)
        case .track:
            guard let heading = storm.cell?.headingDeg else { return nil }
            let h = heading * .pi / 180
            let along = storm.east * sin(h) + storm.north * cos(h)
            var normal = cross(storm.up, along)
            // Remove the side facing the viewer, so the face looks at them.
            if dot(normal, camera - storm.centre) < 0 { normal = -normal }
            return (storm.centre + normal * sliderValue * 1000, normal)
        case .floor:
            // Everything below the height goes; the cut face looks down at the viewer.
            return (storm.centre + storm.up * sliderValue * 1000, -storm.up)
        default:
            return nil
        }
    }

    // MARK: Picking

    /// The storm under a screen point: the nearest one a ray through it
    /// enters where the shader draws cloud.
    func pick(_ point: CGPoint, pose: CameraPose, storms: [PlacedStorm]) -> PlacedStorm? {
        let (origin, direction) = pose.ray(through: point)
        let earth = frame.groundSphere()
        let earthCentre = SIMD3<Float>(worldDirection(earth.centre))
        let limit = Self.rayEarthDistance(origin: origin, direction: direction, centre: earthCentre, radius: Float(earth.radius))
        var best: (PlacedStorm, Float)?
        for storm in storms {
            guard let volume = storm.volume else { continue }
            let toBox = simd_float4x4(converting: storm.worldToBox)
            let o4 = toBox * SIMD4(origin, 1), d4 = toBox * SIMD4(direction, 0)
            let o = SIMD3(o4.x, o4.y, o4.z), d = SIMD3(d4.x, d4.y, d4.z)
            let low = Float(modeApplies(to: storm) && mode == .peel
                ? StormVolume.dbzLow + sliderValue * (volume.coreDbz - StormVolume.dbzLow) : StormVolume.dbzLow)
            if let t = volume.firstHit(origin: o, direction: d, low: low, within: limit), t < (best?.1 ?? .infinity) {
                best = (storm, t)
            }
        }
        return best?.0
    }

    static func rayEarthDistance(origin: SIMD3<Float>, direction: SIMD3<Float>, centre: SIMD3<Float>, radius: Float) -> Float {
        let toCentre = centre - origin
        let along = dot(toCentre, direction)
        let miss = dot(toCentre, toCentre) - along * along
        guard miss < radius * radius else { return .infinity }
        let t = along - sqrt(radius * radius - miss)
        return t > 0 ? t : .infinity
    }

    // MARK: Lines

    /// Lines drawn under the storms (on the ground) and over them (lightning,
    /// the height scale).
    func lines(storms: [PlacedStorm], feed: StormFeed, pose: CameraPose) -> (under: [WorldLine], over: [WorldLine]) {
        var under: [WorldLine] = []
        var over: [WorldLine] = []
        // Paths, footprints and forecasts float a kilometre over the ground.
        // On the ground itself, seen from eye height, anything further than a
        // few kilometres lies flat on the horizon line and cannot be read.
        let ground = groundAltitude + Self.overlayHeight
        let selected = storms.first { $0.entry.path == selectedPath }

        if let selected {
            // The footprint, and a height scale beside it.
            let radius = max(4_000, sqrt((selected.entry.areaKm2 ?? 50) / .pi) * 1000)
            under += circle(lat: selected.entry.lat, lon: selected.entry.lon, radius: radius, altitude: ground,
                            colour: SIMD4(1, 1, 1, 0.7), width: 2)
            over += heightScale(for: selected, radius: radius, pose: pose)
        }

        for storm in storms {
            guard let cell = storm.cell else { continue }
            let isSelected = storm.entry.path == selectedPath
            if isSelected || mode == .nowcast {
                // Where it has been: the track's centroids on the ground.
                if let track = feed.track(for: storm.entry), track.path.count > 1 {
                    let points = track.path.map { world(latitude: $0[1], longitude: $0[0], altitude: ground) }
                    under += polyline(points, colour: SIMD4(1, 0.6, 0.2, 0.85), width: 3)
                }
                // Where it is going: the motion over the next quarter hour.
                if let heading = cell.headingDeg, let speed = cell.speedKmh, speed > 0 {
                    under += arrow(lat: cell.lat, lon: cell.lon, heading: heading, metres: speed * 250,
                                   altitude: ground, colour: SIMD4(0.4, 0.9, 1, 0.9))
                }
                // The forecast's one-sigma ellipses.
                for point in cell.forecast ?? [] {
                    let major = (point.majorKm ?? 3) * 1000, minor = (point.minorKm ?? 3) * 1000
                    under += ellipse(lat: point.lat, lon: point.lon, major: major, minor: minor, angle: point.angleDeg ?? 0,
                                     altitude: ground, colour: SIMD4(0.4, 0.9, 1, 0.55), width: 1.5)
                }
                if let forecast = cell.forecast, forecast.count > 1 {
                    let points = forecast.map { world(latitude: $0.lat, longitude: $0.lon, altitude: ground) }
                    under += polyline(points, colour: SIMD4(0.4, 0.9, 1, 0.55), width: 1.5)
                }
            }
        }

        for meso in feed.mesocyclones {
            let (metres, _) = Geo.distanceBearing(fromLat: frame.latitude, lon: frame.longitude, toLat: meso.lat, lon: meso.lon)
            guard metres < StormFeed.rangeMetres else { continue }
            under += circle(lat: meso.lat, lon: meso.lon, radius: max(meso.diameterM / 2, 1_000), altitude: ground,
                            colour: SIMD4(1, 0.3, 0.9, 0.9), width: 3)
        }

        if showLightning {
            for strike in feed.strikes {
                over += bolt(strike, ground: groundAltitude)
            }
        }
        return (under, over)
    }

    private func polyline(_ points: [SIMD3<Double>], colour: SIMD4<Float>, width: Float) -> [WorldLine] {
        zip(points, points.dropFirst()).map { WorldLine(a: SIMD3<Float>($0), b: SIMD3<Float>($1), colour: colour, width: width) }
    }

    private func circle(lat: Double, lon: Double, radius: Double, altitude: Double, colour: SIMD4<Float>, width: Float) -> [WorldLine] {
        ellipse(lat: lat, lon: lon, major: radius, minor: radius, angle: 0, altitude: altitude, colour: colour, width: width)
    }

    /// An ellipse on the ground, its major axis along `angle` (clockwise from north).
    private func ellipse(lat: Double, lon: Double, major: Double, minor: Double, angle: Double,
                         altitude: Double, colour: SIMD4<Float>, width: Float) -> [WorldLine] {
        let count = 32
        let points = (0 ... count).map { i -> SIMD3<Double> in
            let t = Double(i) / Double(count) * 2 * .pi
            let x = major * cos(t), y = minor * sin(t)
            let bearing = angle + atan2(y, x) * 180 / .pi
            let p = Geo.destination(lat: lat, lon: lon, bearing: bearing, metres: hypot(x, y))
            return world(latitude: p.lat, longitude: p.lon, altitude: altitude)
        }
        return polyline(points, colour: colour, width: width)
    }

    private func arrow(lat: Double, lon: Double, heading: Double, metres: Double, altitude: Double, colour: SIMD4<Float>) -> [WorldLine] {
        let tip = Geo.destination(lat: lat, lon: lon, bearing: heading, metres: metres)
        let start = world(latitude: lat, longitude: lon, altitude: altitude)
        let end = world(latitude: tip.lat, longitude: tip.lon, altitude: altitude)
        var lines = polyline([start, end], colour: colour, width: 3)
        for side in [-150.0, 150.0] {
            let barb = Geo.destination(lat: tip.lat, lon: tip.lon, bearing: heading + side, metres: metres * 0.2)
            lines += polyline([end, world(latitude: barb.lat, longitude: barb.lon, altitude: altitude)], colour: colour, width: 3)
        }
        return lines
    }

    /// A vertical scale at the side of the storm facing the viewer's right,
    /// a tick every 2 km.
    private func heightScale(for storm: PlacedStorm, radius: Double, pose: CameraPose) -> [WorldLine] {
        let camera = SIMD3<Double>(pose.position)
        var toStorm = storm.centre - camera
        toStorm -= dot(toStorm, storm.up) * storm.up
        guard length(toStorm) > 1 else { return [] }
        let right = normalize(cross(normalize(toStorm), storm.up))
        let base = storm.centre + right * radius + storm.up * groundAltitude
        let colour = SIMD4<Float>(1, 1, 1, 0.8)
        var lines = polyline([base, storm.centre + right * radius + storm.up * 16_000], colour: colour, width: 1.5)
        for km in stride(from: 2.0, through: 16, by: 2) {
            let at = storm.centre + right * radius + storm.up * km * 1000
            lines += polyline([at, at + right * 1_200], colour: colour, width: 1.5)
        }
        return lines
    }

    /// Heights of the scale's ticks, in world space, for their labels.
    func heightTicks(for storm: PlacedStorm, pose: CameraPose) -> [(km: Int, point: SIMD3<Float>)] {
        let camera = SIMD3<Double>(pose.position)
        var toStorm = storm.centre - camera
        toStorm -= dot(toStorm, storm.up) * storm.up
        guard length(toStorm) > 1 else { return [] }
        let radius = max(4_000, sqrt((storm.entry.areaKm2 ?? 50) / .pi) * 1000)
        let right = normalize(cross(normalize(toStorm), storm.up))
        return stride(from: 2, through: 16, by: 2).map { km in
            (km, SIMD3<Float>(storm.centre + right * (radius + 1_500) + storm.up * Double(km) * 1000))
        }
    }

    /// A strike as a jagged bolt from cloud base to the ground, fading over
    /// ten minutes; the last minute's are brighter and thicker.
    private func bolt(_ strike: LightningStrike, ground: Double) -> [WorldLine] {
        let age = now.timeIntervalSince(strike.time)
        guard age < 600, age > -60 else { return [] }
        let fade = Float(1 - max(age, 0) / 600)
        let fresh = age < 60
        let colour = SIMD4<Float>(1, 0.95, 0.55, (fresh ? 1 : 0.65) * fade)
        // A deterministic zigzag, so a bolt does not flicker frame to frame.
        var seed = UInt64(bitPattern: Int64(strike.time.timeIntervalSince1970 * 1000))
        func jitter() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 33) / Double(1 << 31) - 0.5
        }
        let base = ground + 4_000
        var points: [SIMD3<Double>] = []
        for i in 0 ... 5 {
            let h = base - (base - ground) * Double(i) / 5
            let offset = i == 0 || i == 5 ? 0 : jitter() * 700
            let p = Geo.destination(lat: strike.lat, lon: strike.lon, bearing: jitter() * 360, metres: abs(offset))
            points.append(world(latitude: p.lat, longitude: p.lon, altitude: h))
        }
        return polyline(points, colour: colour, width: fresh ? 3 : 1.5)
    }

    // MARK: Labels

    func label(for storm: PlacedStorm, feed: StormFeed) -> StormLabelModel {
        let german = Locale.preferredLanguages.first?.hasPrefix("de") == true
        let km = storm.distance / 1000
        let distance = km < 10 ? String(format: "%.1f km", km) : String(format: "%.0f km", km)
        let direction = Geo.compassPoint(storm.bearing, german: german)
        var title = "\(distance) · \(direction)"
        if let placement = feed.track(for: storm.entry)?.properties.placement {
            title = "\(placement.place) · " + title
        }

        var parts: [String] = []
        if let dbz = storm.cell?.maxDbz ?? storm.entry.peakDbz ?? storm.volume?.maxDbz {
            parts.append(String(format: "%.0f dBZ", dbz))
        }
        if let top = storm.cell?.echoTopM ?? storm.volume?.echoTopM {
            parts.append(String(format: NSLocalizedString("ar_label_top", comment: ""), top / 1000))
        }
        if let speed = storm.cell?.speedKmh, let heading = storm.cell?.headingDeg, speed > 0 {
            parts.append(String(format: "→ %@ %.0f km/h", Geo.compassPoint(heading, german: german), speed))
        }

        var flags: [String] = []
        if let cell = storm.cell {
            if (cell.hailFlag ?? 0) > 0 { flags.append("cloud.hail.fill") }
            if (cell.gustFlag ?? 0) > 0 { flags.append("wind") }
            if (cell.heavyRainFlag ?? 0) > 0 { flags.append("cloud.heavyrain.fill") }
            if (cell.mesoSeverity ?? 0) > 0 { flags.append("tornado") }
            if (cell.lightningRate ?? 0) > 0 { flags.append("bolt.fill") }
        }
        if let rate = storm.cell?.lightningRate, rate > 0 {
            parts.append(String(format: NSLocalizedString("ar_label_lightning", comment: ""), rate))
        }

        var age = ""
        if let seconds = storm.age {
            age = String(format: NSLocalizedString("ar_label_age", comment: ""), max(0, Int(seconds / 60)))
        }
        if let minutes = storm.extrapolatedMinutes, minutes > 0 {
            age += " · " + String(format: NSLocalizedString("ar_label_extrapolated", comment: ""), Int(minutes.rounded()))
        }
        if !storm.entry.openable {
            age += " · " + NSLocalizedString("ar_label_poorly_seen", comment: "")
        }

        return StormLabelModel(path: storm.entry.path, code: storm.entry.code, title: title,
                               detail: parts.joined(separator: " · "), flags: flags, age: age,
                               openable: storm.entry.openable, selected: storm.entry.path == selectedPath,
                               distance: storm.distance)
    }

    // MARK: Light

    /// Towards the sun in the storm's own frame while it is up; core's fixed
    /// light from the south-west otherwise. The storm's sunlit side faces the sun.
    func light() -> SIMD3<Float> {
        let sun = SunPosition.at(now, latitude: frame.latitude, longitude: frame.longitude)
        guard sun.elevation > 2 else { return normalize(SIMD3(-0.45, -0.7, 0.75)) }
        let az = sun.azimuth * .pi / 180, el = sun.elevation * .pi / 180
        return SIMD3(Float(sin(az) * cos(el)), Float(cos(az) * cos(el)), Float(sin(el)))
    }
}

extension simd_float4x4 {
    init(converting m: simd_double4x4) {
        self.init(columns: (SIMD4<Float>(m.columns.0), SIMD4<Float>(m.columns.1),
                            SIMD4<Float>(m.columns.2), SIMD4<Float>(m.columns.3)))
    }
}
