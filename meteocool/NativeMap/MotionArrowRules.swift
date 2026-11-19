//
//  MotionArrowRules.swift
//  meteocool
//
//  The rain's motion as an arrow: core's `lib/motionArrow.ts`.
//

import CoreGraphics
import Foundation

/// The rain's motion as an arrow, the shapes in screen points.
///
/// Each arrow the server sends stands for a block of the map and carries the
/// block's mean motion, km/h east and north (ng's ADR 0042). The arrow is
/// centred on the block's middle and points the way the rain goes. A faster
/// motion is a longer arrow, from `shortest` at `stillKmh` to `longest` at
/// `fastestKmh` and beyond; below `stillKmh` there is no arrow, since a few
/// km/h of jitter would point anywhere.
///
/// Speeds are kept to the nearest 5 km/h and directions to the nearest 5
/// degrees, so a map of a thousand arrows is drawn from a few dozen shapes.
/// x is to the right and y down, as the map draws.
///
/// No app dependencies here: `scripts/check.sh` compiles this file alone.
enum MotionArrowRules {
    struct Shape: Equatable, Sendable {
        /// km/h, to the nearest 5.
        let kmh: Int
        /// Where the rain goes, degrees clockwise from north, to the nearest 5.
        let towardDeg: Int
        /// From the tail to where the head begins.
        let shaft: (CGPoint, CGPoint)
        /// The head: its tip, then its two barbs.
        let head: (CGPoint, CGPoint, CGPoint)

        static func == (a: Shape, b: Shape) -> Bool {
            a.kmh == b.kmh && a.towardDeg == b.towardDeg && a.shaft == b.shaft && a.head == b.head
        }
    }

    /// How big an arrow is drawn, in points.
    struct Size: Sendable {
        let shortest: Double
        let longest: Double
        /// The head's length along the shaft, and its half width.
        let head: Double
        let halfWidth: Double
    }

    /// The tile set puts arrows about 56 points apart at the zoom of their
    /// tiles: the longest leaves a third of that between two (`ARROW_SIZE`).
    static let size = Size(shortest: 10, longest: 34, head: 6.5, halfWidth: 4)

    /// Slower than this is no arrow.
    static let stillKmh = 5.0
    /// As fast as this, or faster, is the longest arrow.
    static let fastestKmh = 100.0

    /// Speed in km/h and direction of travel, degrees clockwise from north,
    /// of a motion east and north (`motionOf`).
    static func motion(east: Double, north: Double) -> (kmh: Double, towardDeg: Double) {
        let toward = (atan2(east, north) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        return ((east * east + north * north).squareRoot(), toward)
    }

    /// The speed an arrow is drawn for: the nearest 5 km/h. JavaScript's
    /// `Math.round`: halves up.
    static func roundKmh(_ kmh: Double) -> Int {
        max(0, Int((kmh / 5 + 0.5).rounded(.down)) * 5)
    }

    /// The direction an arrow is drawn for: the nearest 5 degrees, 0 to 355.
    static func roundDeg(_ deg: Double) -> Int {
        let rounded = Int((deg / 5 + 0.5).rounded(.down)) * 5
        return ((rounded % 360) + 360) % 360
    }

    /// How long an arrow is for a speed, tail to tip.
    static func length(_ kmh: Double, size: Size = size) -> Double {
        let share = min(max((kmh - stillKmh) / (fastestKmh - stillKmh), 0), 1)
        return size.shortest + share * (size.longest - size.shortest)
    }

    /// The arrow for a motion east and north in km/h; nil when it is too slow
    /// to have a direction (`motionArrow`).
    static func arrow(east: Double, north: Double, size: Size = size) -> Shape? {
        let motion = motion(east: east, north: north)
        let kmh = roundKmh(motion.kmh)
        guard Double(kmh) >= stillKmh else { return nil }
        let towardDeg = roundDeg(motion.towardDeg)
        let theta = Double(towardDeg) * .pi / 180
        // Along the arrow, tail to tip, y down, and its right.
        let along = (sin(theta), -cos(theta))
        let right = (-along.1, along.0)
        let half = length(Double(kmh), size: size) / 2
        func at(_ distance: Double, _ aside: Double = 0) -> CGPoint {
            CGPoint(x: along.0 * distance + right.0 * aside, y: along.1 * distance + right.1 * aside)
        }
        let neck = half - size.head
        return Shape(kmh: kmh, towardDeg: towardDeg, shaft: (at(-half), at(neck)),
                     head: (at(half), at(neck, size.halfWidth), at(neck, -size.halfWidth)))
    }

    /// How much older than the arrows an observed frame may be before they
    /// are no longer its motion.
    static let staleAfter = 15 * 60

    /// Whether the arrows, which are the newest motion, are not the motion of
    /// the frame the timeline shows: an observed frame well before them. A
    /// forecast frame is not: the forecast is the rain moved along the newest
    /// motion (`arrowsStale`).
    static func stale(frame: Int?, arrows: Int?, onForecast: Bool) -> Bool {
        guard let frame, let arrows, !onForecast else { return false }
        return arrows - frame > staleAfter
    }
}
