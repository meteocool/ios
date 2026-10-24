//
//  ThreeDCamera.swift
//  meteocool
//
//  The 3D storm map's camera: MapLibre's Mercator transform, so core's
//  framing, residency and level rules port as they are.
//

import Foundation
import simd

/// Where the 3D map looks from, in MapLibre's terms (maplibre-gl 6.10
/// `MercatorTransform._calcMatrices`): a centre on the ground, a zoom
/// (512-point tiles: the flat map's zoom less one), a tilt and a heading,
/// and the ground's height under the centre.
///
/// No app dependencies here: `scripts/check.sh` compiles this file alone.
struct MapCamera: Equatable, Sendable {
    var lon: Double
    var lat: Double
    /// MapLibre's zoom: the flat map's (`latLonZ`) less one.
    var zoom: Double
    /// Degrees from looking straight down.
    var pitch: Double
    /// Degrees clockwise from north.
    var bearing: Double
    /// The ground's height under the centre, in metres as drawn (exaggerated).
    var elevation: Double = 0
    /// The map's size in points.
    var width: Double = 390
    var height: Double = 844

    /// MapLibre's vertical field of view, its default, which the 3D map keeps.
    static let fov = 0.6435011087932844
    /// core's `MIN_ZOOM`, `maxZoom`, `MAX_PITCH` (`Cells3DCapability.ts`).
    static let minZoom = 3.5
    static let maxZoom = 13.0
    static let maxPitch = 84.0
    /// The tilt the map opens at, and the one an opened storm is looked at from.
    static let initialPitch = 55.0
    static let openPitch = 76.0
    /// MapLibre's limit for the horizon (`maxMercatorHorizonAngle`).
    static let horizonAngle = 89.25

    /// Clamped to the map's limits, as MapLibre's transform keeps itself.
    mutating func constrain() {
        zoom = min(max(zoom, Self.minZoom), Self.maxZoom)
        pitch = min(max(pitch, 0), Self.maxPitch)
        bearing = Self.wrapBearing(bearing)
        lat = min(max(lat, -85.051129), 85.051129)
        lon = (lon + 540).truncatingRemainder(dividingBy: 360) - 180
    }

    /// A heading folded into [-180, 180).
    static func wrapBearing(_ degrees: Double) -> Double {
        let folded = ((degrees + 180).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) - 180
        return folded == 0 ? 0 : folded
    }

    var worldSize: Double { 512 * pow(2, zoom) }
    var pitchRadians: Double { pitch * .pi / 180 }
    var bearingRadians: Double { bearing * .pi / 180 }
    var cameraToCenterDistance: Double { 0.5 / tan(Self.fov / 2) * height }
    /// Points per metre at the centre.
    var pixelPerMeter: Double { worldSize / (Mercator.circumference * cos(lat * .pi / 180)) }
    var centre: SIMD2<Double> { Mercator.point(lon: lon, lat: lat) }
    /// The centre's height in Mercator units.
    var elevationMercator: Double { elevation * Mercator.metre(atLatitude: lat) }

    /// How far below the middle of the screen the horizon is, in points (`getMercatorHorizon`).
    var horizon: Double {
        cameraToCenterDistance * min(tan((90 - pitch) * .pi / 180) * 0.85, tan((Self.horizonAngle - pitch) * .pi / 180))
    }

    /// MapLibre's near and far planes, in points (`_calculateNearFarZ`).
    var nearFar: (near: Double, far: Double) {
        let limitedPitch = min(pitch, Self.horizonAngle) * .pi / 180
        let distance = cameraToCenterDistance
        let toSeaLevel = max(distance / 2, distance + elevation * pixelPerMeter / cos(limitedPitch))
        let altitude = cos(pitchRadians) * distance / pixelPerMeter + elevation
        let lowest = min(elevation, 0, altitude - 100)
        let lowestPlane = lowest < 0 ? toSeaLevel - lowest * pixelPerMeter / cos(limitedPitch) : toSeaLevel
        let groundAngle = Double.pi / 2 + pitchRadians
        let fovAboveCenter = Self.fov * 0.5
        let clampAngle = { (a: Double) in min(max(a, 0.01), Double.pi - 0.01) }
        let topHalf = sin(fovAboveCenter) * lowestPlane / sin(clampAngle(.pi - groundAngle - fovAboveCenter))
        let horizonAngle = atan(horizon / distance)
        let minToHorizon = (90 - Self.horizonAngle) * .pi / 180
        let toHorizon = horizonAngle > minToHorizon ? horizonAngle : minToHorizon
        let topHalfHorizon = sin(toHorizon) * lowestPlane / sin(clampAngle(.pi - groundAngle - toHorizon))
        let far = (cos(.pi / 2 - limitedPitch) * min(topHalf, topHalfHorizon) + lowestPlane) * 1.01
        return (height / 50, far)
    }

    /// Mercator units (x east, y south, z up in Mercator units) to Metal's
    /// clip space: MapLibre's `mercatorMatrix` with the camera raised over
    /// the ground under its centre, depth mapped to 0…1.
    var viewProjection: simd_double4x4 {
        let (near, far) = nearFar
        var m = Matrix.perspective(fovy: Self.fov, aspect: width / height, near: near, far: far)
        m = Matrix.scale(m, SIMD3(1, -1, 1))
        m = Matrix.translate(m, SIMD3(0, 0, -cameraToCenterDistance))
        m = Matrix.rotateX(m, pitchRadians)
        m = Matrix.rotateZ(m, -bearingRadians)
        let point = centre * worldSize
        m = Matrix.translate(m, SIMD3(-point.x, -point.y, 0))
        m = Matrix.scale(m, SIMD3(repeating: worldSize))
        m = Matrix.translate(m, SIMD3(0, 0, -elevationMercator))
        return Matrix.metalDepth * m
    }

    /// The camera's position in Mercator units (`cameraMercatorCoordinate`).
    var position: SIMD3<Double> {
        let distance = cameraToCenterDistance / worldSize
        let p = pitchRadians, b = bearingRadians
        return SIMD3(centre.x - sin(p) * sin(b) * distance,
                     centre.y + sin(p) * cos(b) * distance,
                     elevationMercator + cos(p) * distance)
    }

    // MARK: Projection

    /// Where a point in Mercator units lands on screen, in points, and its
    /// clip w (negative behind the camera).
    func project(_ p: SIMD3<Double>, with viewProjection: simd_double4x4? = nil) -> (point: SIMD2<Double>, w: Double) {
        let clip = Matrix.apply(viewProjection ?? self.viewProjection, p)
        let ndc = SIMD2(clip.x, clip.y) / clip.w
        return (SIMD2((ndc.x + 1) / 2 * width, (1 - ndc.y) / 2 * height), clip.w)
    }

    /// A screen point's ray, from the near plane outwards, in Mercator units.
    func ray(_ point: SIMD2<Double>, inverse: simd_double4x4? = nil) -> (origin: SIMD3<Double>, direction: SIMD3<Double>) {
        let inverse = inverse ?? viewProjection.inverse
        let ndc = SIMD2(point.x / width * 2 - 1, 1 - point.y / height * 2)
        let a = inverse * SIMD4(ndc.x, ndc.y, 0, 1), b = inverse * SIMD4(ndc.x, ndc.y, 1, 1)
        let near = SIMD3(a.x, a.y, a.z) / a.w, far = SIMD3(b.x, b.y, b.z) / b.w
        return (near, far - near)
    }

    /// Where a screen point meets the level ground at `height` (Mercator
    /// units), or nil above the horizon.
    func ground(_ point: SIMD2<Double>, height: Double? = nil, inverse: simd_double4x4? = nil) -> SIMD2<Double>? {
        let (origin, direction) = ray(point, inverse: inverse)
        let level = height ?? elevationMercator
        guard abs(direction.z) > 1e-18 else { return nil }
        let t = (level - origin.z) / direction.z
        guard t > 0 else { return nil }
        let hit = origin + direction * t
        return SIMD2(hit.x, hit.y)
    }

    /// The centre moved so that `location` (Mercator) lands on screen at
    /// `point`, as MapLibre's `setLocationAtPoint`.
    mutating func setLocation(_ location: SIMD2<Double>, at point: SIMD2<Double>) {
        let inverse = viewProjection.inverse
        guard let a = ground(point, inverse: inverse),
              let b = ground(SIMD2(width / 2, height / 2), inverse: inverse) else { return }
        let next = location - (a - b)
        lon = Mercator.lon(next.x)
        lat = Mercator.lat(next.y)
        constrain()
    }

    /// The ground the screen shows, west, south, east, north in degrees, as
    /// MapLibre's `getBounds`: the top edge held at the horizon.
    var bounds: (west: Double, south: Double, east: Double, north: Double) {
        let top = max(0, height / 2 - horizon)
        let inverse = viewProjection.inverse
        let corners = [SIMD2(0, top), SIMD2(width, top), SIMD2(width, height), SIMD2(0, height)]
            .compactMap { ground($0, inverse: inverse) }
        guard !corners.isEmpty else { return (lon, lat, lon, lat) }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return (Mercator.lon(xs.min()!), Mercator.lat(ys.max()!), Mercator.lon(xs.max()!), Mercator.lat(ys.min()!))
    }

    // MARK: Covering tiles

    /// The tiles that cover the screen, finer near the camera and coarser
    /// towards the horizon, nearest the centre first: MapLibre's
    /// `coveringTiles` with its default `calculateTileZoom` (9.314 zoom
    /// levels on screen at most, tile count ratio 3), for 512-point tiles.
    /// `heights` gives a tile's lowest and highest ground in Mercator units.
    func coveringTiles(maxZoom: Int, heights: (MapTile) -> (Double, Double) = { _ in (0, 0) }) -> [MapTile] {
        let viewProjection = self.viewProjection
        let camera = position
        let centre = SIMD3(self.centre.x, self.centre.y, elevationMercator)
        let distanceZ = abs(centre.z - camera.z)
        let distanceToCentre3D = simd_length(camera - centre)
        let desired = Int(floor(zoom))
        let nominal = min(max(0, desired), maxZoom)
        let fovDegrees = Self.fov * 180 / .pi

        var stack = [(tile: MapTile(0, 0, 0), full: false)]
        var result: [(MapTile, Double)] = []
        let centreAt = SIMD2(centre.x, centre.y) * Double(1 << nominal)
        while let (tile, full) = stack.popLast() {
            let (low, high) = heights(tile)
            let minX = tile.origin.x, minY = tile.origin.y, size = tile.size
            var fully = full
            if !full {
                let visibility = Self.visibility(minX: minX, minY: minY, size: size, low: min(low, 0), high: max(high, 0),
                                                 viewProjection: viewProjection)
                if visibility == 0 { continue }
                fully = visibility == 2
            }
            let dx = max(minX - camera.x, 0, camera.x - (minX + size))
            let dy = max(minY - camera.y, 0, camera.y - (minY + size))
            let distance2D = hypot(dx, dy)
            let wanted = Self.tileZoom(centreZoom: zoom, distance2D: distance2D, distanceZ: distanceZ,
                                       distanceToCentre3D: distanceToCentre3D, fovDegrees: fovDegrees)
            let z = min(max(0, Int(floor(wanted))), maxZoom)
            if tile.z >= z {
                let scale = Double(1 << max(0, nominal - tile.z))
                let cx = (Double(tile.x) + 0.5) * scale, cy = (Double(tile.y) + 0.5) * scale
                result.append((tile, hypot(centreAt.x - cx, centreAt.y - cy)))
                continue
            }
            for child in tile.children { stack.append((child, fully)) }
        }
        return result.sorted { $0.1 < $1.1 }.map(\.0)
    }

    /// MapLibre's `createCalculateTileZoomFunction(9.314, 3.0)`.
    static func tileZoom(centreZoom: Double, distance2D: Double, distanceZ: Double, distanceToCentre3D: Double,
                         fovDegrees: Double) -> Double {
        let maxLevels = 9.314, ratio = 3.0
        func integral(_ p: Double, _ x1: Double, _ x2: Double) -> Double {
            let n = 10
            let dx = (x2 - x1) / Double(n)
            var sum = 0.0
            for i in 0 ..< n {
                let x = x1 + (Double(i) + 0.5) / Double(n) * (x2 - x1)
                sum += dx * pow(cos(x), p)
            }
            return sum
        }
        let rad = Double.pi / 180
        let behaviour = 2 * ((maxLevels - 1) / log2(cos((horizonAngle - fovDegrees) * rad) / cos(horizonAngle * rad)) - 1)
        let centrePitch = acos(min(max(distanceZ / max(distanceToCentre3D, 1e-18), -1), 1))
        let countPitch0 = 2 * integral(behaviour - 1, 0, fovDegrees / 2 * rad)
        let highest = min(horizonAngle * rad, centrePitch + fovDegrees / 2 * rad)
        let lowest = min(highest, centrePitch - fovDegrees / 2 * rad)
        let count = integral(behaviour - 1, lowest, highest)
        let tilePitch = atan(distance2D / max(distanceZ, 1e-18))
        let distance3D = hypot(distance2D, distanceZ)
        var z = centreZoom
        z += log2(distanceToCentre3D / max(distance3D, 1e-18) / max(0.5, cos(fovDegrees / 2 * rad)))
        z += behaviour * log2(cos(tilePitch)) / 2
        z -= log2(max(1, count / countPitch0 / ratio)) / 2
        return z
    }

    /// 0: outside the frustum; 1: partly in it; 2: wholly in it. A box of
    /// ground, its corners projected and tested against each clip plane.
    static func visibility(minX: Double, minY: Double, size: Double, low: Double, high: Double,
                           viewProjection: simd_double4x4) -> Int {
        var outside = [Int](repeating: 0, count: 6)
        var inside = 0
        for corner in 0 ..< 8 {
            let p = SIMD3(minX + (corner & 1 == 0 ? 0 : size), minY + (corner & 2 == 0 ? 0 : size), corner & 4 == 0 ? low : high)
            let c = Matrix.apply(viewProjection, p)
            let tests = [c.x < -c.w, c.x > c.w, c.y < -c.w, c.y > c.w, c.z < 0, c.z > c.w]
            var any = false
            for (i, out) in tests.enumerated() where out {
                outside[i] += 1
                any = true
            }
            if !any { inside += 1 }
        }
        if outside.contains(8) { return 0 }
        return inside == 8 ? 2 : 1
    }
}

/// A camera move under way: MapLibre's `easeTo` for the Mercator
/// projection (`MercatorCameraHelper.handleEaseTo`), with its offset (the
/// target centre lands that far from the middle of the screen) and its
/// default easing.
struct CameraEase: Sendable {
    let start: MapCamera
    let duration: Double
    let startedAt: Double
    private let endZoom: Double
    private let endPitch: Double
    private let endBearing: Double
    private let from: SIMD2<Double>
    private let delta: SIMD2<Double>
    private let pointAtOffset: SIMD2<Double>
    private let around: (location: SIMD2<Double>, point: SIMD2<Double>)?

    /// `center`, `zoom`, `pitch`, `bearing` as `easeTo` takes them; nil keeps the current one.
    init(from start: MapCamera, center: (lon: Double, lat: Double)? = nil, zoom: Double? = nil, pitch: Double? = nil,
         bearing: Double? = nil, offset: SIMD2<Double> = .zero, around: (lon: Double, lat: Double)? = nil,
         duration: Double, now: Double) {
        self.start = start
        self.duration = duration
        startedAt = now
        endZoom = min(max(zoom ?? start.zoom, MapCamera.minZoom), MapCamera.maxZoom)
        endPitch = min(max(pitch ?? start.pitch, 0), MapCamera.maxPitch)
        endBearing = bearing.map { CameraEase.normaliseBearing($0, from: start.bearing) } ?? start.bearing
        pointAtOffset = SIMD2(start.width / 2, start.height / 2) + offset
        let locationAtOffset = start.ground(pointAtOffset) ?? start.centre
        let targetCentre = center.map { Mercator.point(lon: $0.lon, lat: $0.lat) } ?? locationAtOffset
        from = locationAtOffset * start.worldSize
        delta = targetCentre * start.worldSize - from
        self.around = around.map { at in
            let location = Mercator.point(lon: at.lon, lat: at.lat)
            return (location, start.project(SIMD3(location.x, location.y, start.elevationMercator)).point)
        }
    }

    /// Where it ends: the camera at k = 1.
    var target: MapCamera { camera(at: 1) }

    /// `_normalizeBearing`: the target within half a turn of the start.
    static func normaliseBearing(_ bearing: Double, from current: Double) -> Double {
        var b = MapCamera.wrapBearing(bearing)
        let diff = abs(b - current)
        if abs(b - 360 - current) < diff { b -= 360 }
        if abs(b + 360 - current) < diff { b += 360 }
        return b
    }

    func progress(at now: Double) -> Double {
        duration <= 0 ? 1 : min(max((now - startedAt) / duration, 0), 1)
    }

    /// The camera at eased progress `k`.
    func camera(at k: Double) -> MapCamera {
        var camera = start
        camera.zoom = start.zoom + (endZoom - start.zoom) * k
        camera.pitch = start.pitch + (endPitch - start.pitch) * k
        camera.bearing = start.bearing + (endBearing - start.bearing) * k
        if let around {
            camera.setLocation(around.location, at: around.point)
        } else {
            let finalScale = pow(2, endZoom - start.zoom)
            let scale = pow(2, camera.zoom - start.zoom)
            let base = endZoom > start.zoom ? min(2, finalScale) : max(0.5, finalScale)
            let speedup = pow(base, 1 - k)
            let world = (from + delta * (k * speedup)) * scale
            let centre = world / camera.worldSize
            camera.setLocation(centre, at: pointAtOffset)
        }
        camera.bearing = MapCamera.wrapBearing(camera.bearing)
        return camera
    }

    func camera(atTime now: Double) -> MapCamera {
        camera(at: UnitBezier.ease.solve(progress(at: now)))
    }

    func finished(at now: Double) -> Bool { progress(at: now) >= 1 }
}
