//
//  StormEasing.swift
//  meteocool
//
//  How the storm marks and the systems' outlines change from one drawing to
//  the next: eased and faded rather than snapped. Core's
//  `lib/stormEasing.ts`, rule for rule; `StormMarks` drives it.
//
//  Every new answer (live, about every five minutes) and every step of the
//  player redraws the storms. Drawn at once, a storm's mark jumps to where it
//  is now, storms pop in and out, and a system's outline is swapped for
//  another shape. So a change is a short transition instead:
//
//  - the same storm (by id) slides from where it was drawn to where it is,
//    its path's newest point with it, unless it moved further than
//    `maxKm`, which is no longer a storm moving: it fades out there and in
//    here;
//  - a storm that appears fades in, one that goes fades out;
//  - a storm that changes how it is drawn (a quiet dot becoming a full mark,
//    a new colour, a badge) cross-fades, the old look out and the new in,
//    while both move;
//  - a system's outline with a new shape cross-fades, old out and new in.
//
//  Identity is the id and nothing else: a different storm at nearly the same
//  place is a different storm, and fades rather than slides.
//
//  A new answer or a new scan is eased; a step of the player only when it
//  comes more than `minGapMs` after the step before it. Playing the loop or
//  dragging the slider steps faster than that, and those steps apply at
//  once. An update during a transition takes over from what is drawn at that
//  moment: nothing is queued. Under Reduce Motion every change applies at
//  once.
//

import Foundation

// No app dependencies here: `scripts/check.sh` compiles this file alone.

/// The geometries that are drawn, in `[lon, lat]` (core's `Shape`).
enum EaseShape: Equatable, Sendable {
    case point(LonLat)
    case line([LonLat])
    case polygon([[LonLat]])
    case multiPolygon([[[LonLat]]])

    init(_ geometry: StormMark.Geometry) {
        switch geometry {
        case .point(let point): self = .point(point)
        case .line(let line): self = .line(line)
        case .polygon(let ring): self = .polygon([ring])
        }
    }

    /// Back to a mark's geometry: a polygon's outer ring.
    var markGeometry: StormMark.Geometry {
        switch self {
        case .point(let point): return .point(point)
        case .line(let line): return .line(line)
        case .polygon(let rings): return .polygon(rings.first ?? [])
        case .multiPolygon(let polygons): return .polygon(polygons.first?.first ?? [])
        }
    }
}

/// One thing to draw: a storm's mark or a system's outline (core's `Drawn`).
struct EaseDrawn<Value: Sendable>: Sendable {
    /// Its identity: eased only into the same key.
    var key: String
    /// Everything that decides how it looks; a change of look cross-fades.
    var look: String
    /// Slides from one position to the next (a position or a path);
    /// anything else cross-fades when its shape changes.
    var moves: Bool
    var shape: EaseShape
    /// What the caller draws it with.
    var value: Value
}

/// One thing in a transition, from `from` at `fromAlpha` to `to` at `toAlpha`.
struct Easing<Value: Sendable>: Sendable {
    /// The drawn one's key, or, for one fading out, a key of its own.
    var key: String
    var item: EaseDrawn<Value>
    var from: EaseShape
    var to: EaseShape
    var fromAlpha: Double
    var toAlpha: Double
    /// Fading out for good: gone when the transition ends, and not tapped meanwhile.
    var leaving: Bool

    /// Whether it changes as the transition runs.
    var animates: Bool { fromAlpha != toAlpha || from != to }
}

/// What is drawn at one moment of a transition.
struct EaseShowing<Value: Sendable>: Sendable {
    var key: String
    var item: EaseDrawn<Value>
    var shape: EaseShape
    var alpha: Double
    var leaving: Bool
}

enum StormEasing {
    /// How long a transition lasts, ms: a slide, a fade and a cross-fade alike.
    static let durationMs = 350.0
    /// How far apart two steps must be, ms, for the second to be eased: over
    /// the player's 450 ms a frame, so a playing loop and a dragged slider snap.
    static let minGapMs = 600.0
    /// How far a storm may move and still slide, km.
    static let maxKm = 25.0

    /// Whether a change of drawing is eased, or applied at once. `stepGap`
    /// is for a step of the player (ms since the one before it), nil for a
    /// change that is not a step (a new answer, a new scan), which always
    /// is. A first drawing appears at once.
    static func eases(reducedMotion: Bool, drawnBefore: Bool, stepGap: Double? = nil) -> Bool {
        !reducedMotion && drawnBefore && (stepGap.map { $0 >= minGapMs } ?? true)
    }

    /// Fast at first, settling at the end: an update taking over mid-way moves at once.
    static func easeOut(_ t: Double) -> Double {
        let clamped = min(max(t, 0), 1)
        return 1 - pow(1 - clamped, 3)
    }

    /// Distance between two points, km, flat-earth: these are a few tens of kilometres.
    static func kmBetween(_ a: LonLat, _ b: LonLat) -> Double {
        let c = cos((a.lat + b.lat) / 2 * .pi / 180)
        return hypot((a.lon - b.lon) * c, a.lat - b.lat) * 111.32
    }

    private static func lerp(_ a: LonLat, _ b: LonLat, _ t: Double) -> LonLat {
        LonLat(a.lon + (b.lon - a.lon) * t, a.lat + (b.lat - a.lat) * t)
    }

    /// The point a position or a path ends at: where its storm is.
    private static func endOf(_ shape: EaseShape) -> LonLat? {
        switch shape {
        case .point(let point): return point
        case .line(let line): return line.last
        default: return nil
        }
    }

    /// Whether `from` can slide into `to`: the same kind of mark, its end
    /// moved no further than `maxKm`.
    static func slides(_ from: EaseShape, _ to: EaseShape) -> Bool {
        switch (from, to) {
        case (.point, .point), (.line, .line): break
        default: return false
        }
        guard let a = endOf(from), let b = endOf(to) else { return false }
        return kmBetween(a, b) <= maxKm
    }

    /// The shape `t` of the way (eased already) from `from` to `to`. A point
    /// slides. A path is the new path with its newest point sliding from the
    /// old path's. Anything else is the new shape; it does not move, it fades.
    static func shapeAt(_ from: EaseShape, _ to: EaseShape, _ t: Double) -> EaseShape {
        if t >= 1 || from == to { return to }
        switch (from, to) {
        case (.point(let a), .point(let b)):
            return .point(lerp(a, b, t))
        case (.line(let a), .line(var b)) where !a.isEmpty && !b.isEmpty:
            b[b.count - 1] = lerp(a[a.count - 1], b[b.count - 1], t)
            return .line(b)
        default:
            return to
        }
    }

    /// A transition that ends at once: everything drawn as it is now, nothing leaving.
    static func settledOn<V>(_ next: [EaseDrawn<V>]) -> [Easing<V>] {
        next.map { Easing(key: $0.key, item: $0, from: $0.shape, to: $0.shape, fromAlpha: 1, toAlpha: 1, leaving: false) }
    }

    /// The transition from what is drawn now (`showing`, mid-transition or
    /// not) to `next`. `seq` makes the keys of what starts leaving here its
    /// own: a storm that cross-fades leaves under `key~seq` while its new
    /// look comes in under its key.
    static func plan<V>(_ showing: [EaseShowing<V>], _ next: [EaseDrawn<V>], seq: Int) -> [Easing<V>] {
        var current: [String: EaseShowing<V>] = [:]
        for shown in showing where !shown.leaving { current[shown.key] = shown }
        var easings: [Easing<V>] = []
        var kept = Set<String>()
        func leave(_ shown: EaseShowing<V>, _ to: EaseShape) -> Easing<V> {
            Easing(key: shown.leaving ? shown.key : "\(shown.key)~\(seq)", item: shown.item, from: shown.shape, to: to,
                   fromAlpha: shown.alpha, toAlpha: 0, leaving: true)
        }
        for item in next {
            func arrive(_ from: EaseShape, _ alpha: Double) -> Easing<V> {
                Easing(key: item.key, item: item, from: from, to: item.shape, fromAlpha: alpha, toAlpha: 1, leaving: false)
            }
            guard let was = current[item.key] else {
                easings.append(arrive(item.shape, 0))
                continue
            }
            kept.insert(item.key)
            let unmoved = was.shape == item.shape
            let slide = !unmoved && item.moves && was.item.moves && slides(was.shape, item.shape)
            if was.item.look == item.look {
                if unmoved || slide {
                    easings.append(arrive(was.shape, was.alpha))
                } else {
                    // Too far, or a shape that does not slide: out there, in here.
                    easings += [leave(was, was.shape), arrive(item.shape, 0)]
                }
                continue
            }
            // A new look: the old one fades out as the new one fades in, moving together if it slides.
            if unmoved || slide {
                easings += [leave(was, item.shape), arrive(was.shape, 0)]
            } else {
                easings += [leave(was, was.shape), arrive(item.shape, 0)]
            }
        }
        // Gone, and whatever was already leaving: fading out from where it is.
        for shown in showing {
            if !shown.leaving && kept.contains(shown.key) { continue }
            if shown.alpha <= 0 { continue }
            easings.append(leave(shown, shown.shape))
        }
        return easings
    }

    /// What a transition draws `t` of the way through (0 to 1, not yet
    /// eased); at 1, what is left once it ends.
    static func showingAt<V>(_ easings: [Easing<V>], _ t: Double) -> [EaseShowing<V>] {
        let e = easeOut(t)
        return easings.compactMap { easing in
            let alpha = easing.fromAlpha + (easing.toAlpha - easing.fromAlpha) * e
            if easing.leaving && (t >= 1 || alpha <= 0) { return nil }
            return EaseShowing(key: easing.key, item: easing.item, shape: shapeAt(easing.from, easing.to, e),
                               alpha: t >= 1 ? easing.toAlpha : alpha, leaving: easing.leaving)
        }
    }

    /// Whether anything in a transition changes as it runs: one that does not is drawn once.
    static func animates<V>(_ easings: [Easing<V>]) -> Bool {
        easings.contains(where: \.animates)
    }
}
