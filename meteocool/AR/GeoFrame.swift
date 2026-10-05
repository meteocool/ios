//
//  GeoFrame.swift
//  meteocool
//
//  Where things are, as seen from where the viewer stands.
//

import Foundation
import simd

/// A local east-north-up frame on the WGS84 ellipsoid.
///
/// The AR view places every storm in the viewer's own ENU frame, by way of
/// ECEF, rather than on a flat map: at storm distances the earth's curvature
/// is not a rounding error. A cloud base 60 km away sits about 280 m lower
/// than a flat frame puts it, and 100 km away nearly 800 m. The same
/// transform also tilts each storm's box by the angle between the two
/// verticals, which is half a degree at 60 km.
struct GeoFrame: Sendable {
    static let semiMajor = 6_378_137.0
    static let flattening = 1 / 298.257_223_563
    static let eccentricitySquared = flattening * (2 - flattening)

    let latitude: Double
    let longitude: Double
    let altitude: Double
    let originECEF: SIMD3<Double>
    let east: SIMD3<Double>
    let north: SIMD3<Double>
    let up: SIMD3<Double>

    init(latitude: Double, longitude: Double, altitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        originECEF = Self.ecef(latitude: latitude, longitude: longitude, altitude: altitude)
        let φ = latitude * .pi / 180, λ = longitude * .pi / 180
        east = SIMD3(-sin(λ), cos(λ), 0)
        north = SIMD3(-sin(φ) * cos(λ), -sin(φ) * sin(λ), cos(φ))
        up = SIMD3(cos(φ) * cos(λ), cos(φ) * sin(λ), sin(φ))
    }

    /// Earth-centred, earth-fixed coordinates of a geodetic point, in metres.
    static func ecef(latitude: Double, longitude: Double, altitude: Double) -> SIMD3<Double> {
        let φ = latitude * .pi / 180, λ = longitude * .pi / 180
        let n = semiMajor / sqrt(1 - eccentricitySquared * sin(φ) * sin(φ))
        return SIMD3((n + altitude) * cos(φ) * cos(λ),
                     (n + altitude) * cos(φ) * sin(λ),
                     (n * (1 - eccentricitySquared) + altitude) * sin(φ))
    }

    /// A geodetic point in this frame: x east, y north, z up, metres.
    func enu(latitude: Double, longitude: Double, altitude: Double) -> SIMD3<Double> {
        enu(ecef: Self.ecef(latitude: latitude, longitude: longitude, altitude: altitude))
    }

    func enu(ecef: SIMD3<Double>) -> SIMD3<Double> {
        let d = ecef - originECEF
        return SIMD3(dot(d, east), dot(d, north), dot(d, up))
    }

    /// A direction given in ECEF, in this frame.
    func rotate(_ v: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(dot(v, east), dot(v, north), dot(v, up))
    }

    /// The axes of another point's own ENU frame, in this frame's coordinates.
    func axes(of other: GeoFrame) -> (east: SIMD3<Double>, north: SIMD3<Double>, up: SIMD3<Double>) {
        (rotate(other.east), rotate(other.north), rotate(other.up))
    }

    /// The radius of the sphere that best fits the ellipsoid here: the
    /// geometric mean of the two principal radii of curvature.
    var gaussianRadius: Double {
        let φ = latitude * .pi / 180
        let w = 1 - Self.eccentricitySquared * sin(φ) * sin(φ)
        return Self.semiMajor * sqrt(1 - Self.eccentricitySquared) / w
    }

    /// The ground as a sphere, in this frame: what hides storms beyond the
    /// horizon.
    ///
    /// The sphere passes through the ground under the viewer rather than
    /// through sea level, which is the terrain under the viewer extended
    /// everywhere. Right on flat land; wrong in the Alps, where real terrain
    /// hides more than this does.
    func groundSphere(eyeHeight: Double = 1.6) -> (centre: SIMD3<Double>, radius: Double) {
        let radius = gaussianRadius
        let ground = max(0, altitude - eyeHeight)
        return (SIMD3(0, 0, -(radius + altitude)), radius + ground)
    }

    /// How far below the horizontal the horizon lies, in degrees, for an eye
    /// this high above the ground.
    static func horizonDip(eyeAboveGround: Double, radius: Double = 6_371_000) -> Double {
        let h = max(eyeAboveGround, 0)
        return acos(radius / (radius + h)) * 180 / .pi
    }
}

enum Geo {
    static let meanRadius = 6_371_008.8

    /// Great-circle distance in metres and initial bearing in degrees
    /// clockwise from true north.
    static func distanceBearing(fromLat lat1: Double, lon lon1: Double,
                                toLat lat2: Double, lon lon2: Double) -> (metres: Double, bearing: Double) {
        let φ1 = lat1 * .pi / 180, φ2 = lat2 * .pi / 180
        let Δφ = φ2 - φ1, Δλ = (lon2 - lon1) * .pi / 180
        let a = sin(Δφ / 2) * sin(Δφ / 2) + cos(φ1) * cos(φ2) * sin(Δλ / 2) * sin(Δλ / 2)
        let metres = 2 * meanRadius * atan2(sqrt(a), sqrt(1 - a))
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        return (metres, normalise(atan2(y, x) * 180 / .pi))
    }

    /// The point a distance along a bearing, on a sphere.
    static func destination(lat: Double, lon: Double, bearing: Double, metres: Double) -> (lat: Double, lon: Double) {
        let δ = metres / meanRadius, θ = bearing * .pi / 180
        let φ1 = lat * .pi / 180, λ1 = lon * .pi / 180
        let φ2 = asin(sin(φ1) * cos(δ) + cos(φ1) * sin(δ) * cos(θ))
        let λ2 = λ1 + atan2(sin(θ) * sin(δ) * cos(φ1), cos(δ) - sin(φ1) * sin(φ2))
        return (φ2 * 180 / .pi, (λ2 * 180 / .pi + 540).truncatingRemainder(dividingBy: 360) - 180)
    }

    /// Longitude and latitude of a spherical Web Mercator (EPSG:3857) point.
    ///
    /// The lightning and mesocyclone feeds carry these metres in fields named
    /// `lon` and `lat`, for historical reasons.
    static func lonLat(mercatorX x: Double, y: Double) -> (lon: Double, lat: Double) {
        let r = 6_378_137.0
        return (x / r * 180 / .pi, (2 * atan(exp(y / r)) - .pi / 2) * 180 / .pi)
    }

    /// Degrees folded into 0 ..< 360.
    static func normalise(_ degrees: Double) -> Double {
        let folded = degrees.truncatingRemainder(dividingBy: 360)
        return folded < 0 ? folded + 360 : folded
    }

    /// The signed difference a - b, folded into -180 ... 180.
    static func angleDifference(_ a: Double, _ b: Double) -> Double {
        let d = normalise(a - b)
        return d > 180 ? d - 360 : d
    }

    /// A bearing as one of sixteen compass points, in the given language.
    static func compassPoint(_ bearing: Double, german: Bool) -> String {
        let english = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        let deutsch = ["N", "NNO", "NO", "ONO", "O", "OSO", "SO", "SSO", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        let index = Int((normalise(bearing) / 22.5).rounded()) % 16
        return german ? deutsch[index] : english[index]
    }
}

/// The sun's position in the sky, from NOAA's solar calculator.
///
/// Good to about a hundredth of a degree for this century, which is far
/// better than a tap on a screen can use. Refraction is added near the
/// horizon, where it lifts the sun by up to half a degree.
enum SunPosition {
    /// Azimuth clockwise from true north and elevation above the horizon, in degrees.
    static func at(_ date: Date, latitude: Double, longitude: Double) -> (azimuth: Double, elevation: Double) {
        let julianDay = date.timeIntervalSince1970 / 86_400 + 2_440_587.5
        let t = (julianDay - 2_451_545) / 36_525

        let meanLongitude = Geo.normalise(280.466_46 + t * (36_000.769_83 + t * 0.000_303_2))
        let meanAnomaly = 357.529_11 + t * (35_999.050_29 - 0.000_153_7 * t)
        let eccentricity = 0.016_708_634 - t * (0.000_042_037 + 0.000_000_126_7 * t)
        let m = meanAnomaly * .pi / 180
        let centre = sin(m) * (1.914_602 - t * (0.004_817 + 0.000_014 * t))
            + sin(2 * m) * (0.019_993 - 0.000_101 * t) + sin(3 * m) * 0.000_289
        let trueLongitude = meanLongitude + centre
        let omega = 125.04 - 1_934.136 * t
        let apparentLongitude = trueLongitude - 0.005_69 - 0.004_78 * sin(omega * .pi / 180)
        let meanObliquity = 23 + (26 + (21.448 - t * (46.815 + t * (0.000_59 - t * 0.001_813))) / 60) / 60
        let obliquity = meanObliquity + 0.002_56 * cos(omega * .pi / 180)

        let ε = obliquity * .pi / 180, λ = apparentLongitude * .pi / 180
        let declination = asin(sin(ε) * sin(λ))

        let y = tan(ε / 2) * tan(ε / 2)
        let l0 = meanLongitude * .pi / 180
        let equationOfTime = 4 * (y * sin(2 * l0) - 2 * eccentricity * sin(m)
            + 4 * eccentricity * y * sin(m) * cos(2 * l0)
            - 0.5 * y * y * sin(4 * l0) - 1.25 * eccentricity * eccentricity * sin(2 * m)) * 180 / .pi

        let minutesUTC = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400) / 60
        let trueSolarTime = (minutesUTC + equationOfTime + 4 * longitude).truncatingRemainder(dividingBy: 1_440)
        var hourAngle = trueSolarTime / 4 - 180
        if hourAngle < -180 { hourAngle += 360 }

        let φ = latitude * .pi / 180, h = hourAngle * .pi / 180
        let cosZenith = min(1, max(-1, sin(φ) * sin(declination) + cos(φ) * cos(declination) * cos(h)))
        let zenith = acos(cosZenith)
        let elevation = 90 - zenith * 180 / .pi

        let azimuthRadians = atan2(sin(h), cos(h) * sin(φ) - tan(declination) * cos(φ))
        let azimuth = Geo.normalise(azimuthRadians * 180 / .pi + 180)

        return (azimuth, elevation + refraction(elevation))
    }

    /// Atmospheric refraction in degrees for an apparent elevation (NOAA's approximation).
    private static func refraction(_ elevation: Double) -> Double {
        guard elevation <= 85 else { return 0 }
        let te = tan(elevation * .pi / 180)
        let arcseconds: Double
        if elevation > 5 {
            arcseconds = 58.1 / te - 0.07 / pow(te, 3) + 0.000_086 / pow(te, 5)
        } else if elevation > -0.575 {
            arcseconds = 1_735 + elevation * (-518.2 + elevation * (103.4 + elevation * (-12.79 + elevation * 0.711)))
        } else {
            arcseconds = -20.772 / te
        }
        return arcseconds / 3_600
    }
}

/// The direction a device's back camera faces, from gravity and the magnetic
/// field measured in the device's own frame.
///
/// Worked out from the two vectors rather than read from `CLHeading` or a
/// `CMAttitude`: both of those describe the top edge of a phone lying flat,
/// and a phone held up to the sky has its top edge pointing at the zenith.
enum Compass {
    /// Magnetic azimuth of the device's -z axis (out of the back camera), in
    /// degrees, or nil when the camera points too close to straight up or down
    /// for a heading to mean anything.
    static func cameraAzimuth(gravity: SIMD3<Double>, magneticField: SIMD3<Double>) -> Double? {
        guard length(gravity) > 0.1, length(magneticField) > 1 else { return nil }
        let down = normalize(gravity)
        let horizontalNorth = magneticField - dot(magneticField, down) * down
        guard length(horizontalNorth) > 1e-6 else { return nil }
        let north = normalize(horizontalNorth)
        let east = cross(down, north)
        let forward = SIMD3<Double>(0, 0, -1)
        let horizontal = forward - dot(forward, down) * down
        guard length(horizontal) > 0.25 else { return nil }
        return Geo.normalise(atan2(dot(horizontal, east), dot(horizontal, north)) * 180 / .pi)
    }
}

/// Where a moving storm is now, from where it was measured and how it moves.
enum DeadReckoning {
    /// The point `minutes` along a heading at a speed, or the start when
    /// either is missing.
    static func advance(lat: Double, lon: Double, headingDeg: Double?, speedKmh: Double?,
                        minutes: Double) -> (lat: Double, lon: Double) {
        guard let headingDeg, let speedKmh, speedKmh > 0, minutes > 0 else { return (lat, lon) }
        return Geo.destination(lat: lat, lon: lon, bearing: headingDeg, metres: speedKmh * 1000 * minutes / 60)
    }
}
