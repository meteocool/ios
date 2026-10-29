//
//  ARMarker.swift
//  meteocool
//
//  A marked place, carried between the map and the AR view: a point held on
//  the map, shown in the sky; or a cloud marked in the sky, shown on the map.
//

import Foundation
import simd

/// A place marked on the map or in the AR view.
struct ARMarker: Equatable, Sendable {
    /// What was marked, which says how far to trust where it is.
    enum Source: Equatable, Sendable {
        /// A point held on the map: where it is, exactly.
        case map
        /// A cloud with radar echo along the line of sight: where the echo is.
        case echo
        /// A cloud the radar does not see, taken to be at the usual base of
        /// a cumulus over the ground: right overhead, a guess further out.
        case assumedBase
        /// The ground, below the horizon.
        case ground
    }

    var latitude: Double
    var longitude: Double
    /// Metres above sea level of what was marked; nil for a point on the map.
    var altitude: Double?
    var source: Source

    /// Where a cloud is taken to be when the radar sees nothing along the
    /// line of sight: about where fair-weather cumulus has its base.
    static let assumedBaseM = 1_500.0
    /// Rays flatter than this miss the assumed base by tens of kilometres
    /// for a degree of tilt: too uncertain to mark.
    static let minimumElevation = 4.0

    /// The search part of a link that opens the map on the marked place,
    /// with the precipitation there open, as "Radar" in the hold menu does.
    var mapSearch: String {
        let pair = PointLink.pair(latitude: latitude, longitude: longitude)
        let view = NativeMapLink(latitude: latitude, longitude: longitude, zoom: 10).search.dropFirst()
        // On the radar, where a point is shown, whichever map was up.
        return "?layer=radar&" + view + "&point=" + pair
    }
}

/// The marker's tag: where it is from here and what it stands on.
struct ARMarkerLabelModel: Equatable {
    let title: String
    let detail: String
    let distance: Double
}

extension StormScene {
    /// Where a ray through a screen point marks: the first radar echo along
    /// it, else the ground below the horizon, else the assumed cloud base.
    /// Nil for a ray too flat to place anything it might be looking at.
    func mark(_ point: CGPoint, pose: CameraPose, targets: [(storm: PlacedStorm, group: StormGroup)]) -> ARMarker? {
        let (origin, direction) = pose.ray(through: point)
        let hit: (SIMD3<Float>, ARMarker.Source)
        if let (_, t) = firstEcho(origin: origin, direction: direction, targets: targets) {
            hit = (origin + direction * t, .echo)
        } else {
            let earth = frame.groundSphere()
            let centre = SIMD3<Float>(worldDirection(earth.centre))
            let ground = Self.rayEarthDistance(origin: origin, direction: direction, centre: centre, radius: Float(earth.radius))
            if ground.isFinite {
                guard Double(ground) <= StormFeed.rangeMetres else { return nil }
                hit = (origin + direction * ground, .ground)
            } else {
                guard Self.elevation(ofWorld: direction) >= ARMarker.minimumElevation else { return nil }
                // From inside the sphere of the base, the ray leaves it once.
                let radius = Float(earth.radius + ARMarker.assumedBaseM)
                let toCentre = centre - origin
                let along = dot(toCentre, direction)
                let miss = dot(toCentre, toCentre) - along * along
                let t = along + sqrt(max(0, radius * radius - miss))
                guard t > 0, Double(t) <= StormFeed.rangeMetres else { return nil }
                hit = (origin + direction * t, .assumedBase)
            }
        }
        let place = geodetic(ofWorld: SIMD3<Double>(hit.0))
        return ARMarker(latitude: place.latitude, longitude: place.longitude,
                        altitude: hit.1 == .ground ? nil : place.altitude, source: hit.1)
    }

    /// A world point's latitude, longitude and metres above sea level.
    func geodetic(ofWorld point: SIMD3<Double>) -> (latitude: Double, longitude: Double, altitude: Double) {
        let enu = enuToWorld.inverse * SIMD4(point, 1)
        return frame.geodetic(enu: SIMD3(enu.x, enu.y, enu.z))
    }

    /// The marker as drawn: a pole from the ground up to it, dark under red
    /// so it shows against a bright sky and a dark one. Its top is the
    /// marked cloud, or, for a point on the ground, a height that keeps the
    /// pole about seven degrees tall from here, wherever it is.
    func markerPole(_ marker: ARMarker) -> (lines: [WorldLine], top: SIMD3<Double>, distance: Double) {
        let (distance, _) = Geo.distanceBearing(fromLat: frame.latitude, lon: frame.longitude,
                                                toLat: marker.latitude, lon: marker.longitude)
        let base = world(latitude: marker.latitude, longitude: marker.longitude, altitude: groundAltitude)
        let topAltitude = marker.altitude ?? groundAltitude + min(max(distance * 0.12, 120), 6_000)
        let top = world(latitude: marker.latitude, longitude: marker.longitude, altitude: max(topAltitude, groundAltitude + 50))
        let a = SIMD3<Float>(base), b = SIMD3<Float>(top)
        return ([WorldLine(a: a, b: b, colour: SIMD4(0, 0, 0, 0.55), width: 7),
                 WorldLine(a: a, b: b, colour: SIMD4(1, 0.23, 0.19, 1), width: 4)], top, distance)
    }

    /// The marker's tag.
    func markerLabel(_ marker: ARMarker, place: String?) -> ARMarkerLabelModel {
        let (metres, bearing) = Geo.distanceBearing(fromLat: frame.latitude, lon: frame.longitude,
                                                    toLat: marker.latitude, lon: marker.longitude)
        let km = metres / 1000
        let distance = km < 10 ? String(format: "%.1f km", km) : String(format: "%.0f km", km)
        var title = "\(distance) · \(Geo.compassPoint(bearing, points: Geo.compassPoints))"
        if let place { title = "\(place) · " + title }
        let detail: String
        switch marker.source {
        case .map: detail = NSLocalizedString("ar_marker_from_map", comment: "")
        case .echo: detail = String(format: NSLocalizedString("ar_marker_echo", comment: ""), (marker.altitude ?? 0) / 1000)
        case .assumedBase: detail = String(format: NSLocalizedString("ar_marker_assumed", comment: ""), ARMarker.assumedBaseM / 1000)
        case .ground: detail = NSLocalizedString("ar_marker_ground", comment: "")
        }
        return ARMarkerLabelModel(title: title, detail: detail, distance: metres)
    }
}

extension GeoFrame {
    /// A point in this frame as latitude, longitude and metres above the
    /// ellipsoid (Bowring's method, millimetres at these heights).
    func geodetic(enu: SIMD3<Double>) -> (latitude: Double, longitude: Double, altitude: Double) {
        let p = originECEF + east * enu.x + north * enu.y + up * enu.z
        let a = Self.semiMajor, e2 = Self.eccentricitySquared
        let b = a * (1 - Self.flattening)
        let ep2 = (a * a - b * b) / (b * b)
        let r = hypot(p.x, p.y)
        let θ = atan2(p.z * a, r * b)
        let φ = atan2(p.z + ep2 * b * pow(sin(θ), 3), r - e2 * a * pow(cos(θ), 3))
        let n = a / sqrt(1 - e2 * sin(φ) * sin(φ))
        let altitude = r / cos(φ) - n
        return (φ * 180 / .pi, atan2(p.y, p.x) * 180 / .pi, altitude)
    }
}
