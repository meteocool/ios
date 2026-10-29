//
//  TimelinePhysics.swift
//  meteocool
//
//  How core's timeline strip moves under a finger (`lib/timeline.ts`).
//

import Foundation

/// The strip's drag, flick and settle, in steps (fractional indices), as
/// core's `Timeline.svelte` computes them.
///
/// No app dependencies here: `scripts/check.sh` compiles this file alone.
enum TimelinePhysics {
    /// Velocity decay per millisecond of a flick (`FRICTION`).
    static let friction = 0.006
    /// How far past either end a drag may pull, in steps (`OVERSHOOT`).
    static let overshoot = 1.5
    /// A glide slower than this is over (`AT_REST`), steps per ms.
    static let atRest = 0.0005
    /// Within this many steps of now, a settling needle lands on now (`DETENT_STEPS`).
    static let detentSteps = 0.9
    /// A glide slower than this that crosses now is caught there (`DETENT_CATCH`).
    static let detentCatch = 0.012
    /// A finger moving less than this is a tap (`SWIPE_SLOP`), points.
    static let slop = 6.0
    /// A release counts as a flick only this soon after the last move, ms.
    static let flickWindow = 80.0
    /// The settle's length, ms.
    static let settleDuration = 180.0

    /// Where the needle may rest (core's `Reach`): from `first` to `last`, by
    /// index, less the steps in `gaps` between them. Without a radar open,
    /// every step to the last published; with one, its steps with a sweep.
    struct Reach: Equatable {
        var first: Int
        var last: Int
        var gaps: Set<Int> = []

        static func all(_ last: Int) -> Reach { Reach(first: 0, last: last) }
    }

    /// The strip's reach (`reachOf`): its steps up to `last`, and with a
    /// radar open (`only`, step times) its steps with a sweep.
    static func reach(steps: [Int], last: Int, only: Set<Int>?) -> Reach {
        guard let only else { return .all(last) }
        let reachable = steps.indices.map { $0 <= last && only.contains(steps[$0]) }
        guard let first = reachable.firstIndex(of: true), let end = reachable.lastIndex(of: true) else { return .all(last) }
        return Reach(first: first, last: end, gaps: Set((first ... end).filter { !reachable[$0] }))
    }

    /// The runs of steps outside `only`, as index ranges (`sweepGaps`): what
    /// the strip hatches while a radar is open.
    static func gaps(steps: [Int], only: Set<Int>?) -> [ClosedRange<Int>] {
        guard let only else { return [] }
        var runs: [ClosedRange<Int>] = []
        for (i, step) in steps.enumerated() where !only.contains(step) {
            if let run = runs.last, run.upperBound == i - 1 { runs[runs.count - 1] = run.lowerBound ... i } else { runs.append(i ... i) }
        }
        return runs
    }

    /// A position past the ends of the reach, pulled back like a spring (`rubberBand`).
    static func rubberBand(_ p: Double, reach: Reach) -> Double {
        let first = Double(reach.first), last = Double(reach.last)
        if p < first { return first - overshoot * (1 - 1 / (1 + (first - p) / overshoot)) }
        if p > last { return last + overshoot * (1 - 1 / (1 + (p - last) / overshoot)) }
        return p
    }

    static func rubberBand(_ p: Double, last: Double) -> Double {
        rubberBand(p, reach: .all(Int(last)))
    }

    /// Where a needle at rest belongs (`restingStep`): on now when close to
    /// it, else on the nearest whole step in reach, over a gap to its nearer side.
    static func restingStep(_ p: Double, reach: Reach, detent: Int?) -> Int {
        if let detent, abs(p - Double(detent)) <= detentSteps, !reach.gaps.contains(detent) { return detent }
        let step = max(reach.first, min(reach.last, Int(p.rounded())))
        guard reach.gaps.contains(step) else { return step }
        var below = step, above = step
        while reach.gaps.contains(below) { below -= 1 }
        while reach.gaps.contains(above) { above += 1 }
        return p - Double(below) <= Double(above) - p ? below : above
    }

    static func restingStep(_ p: Double, last: Int, detent: Int?) -> Int {
        restingStep(p, reach: .all(last), detent: detent)
    }

    /// The step `by` steps on from `index`, in reach, over any gap the way it went (`stepOver`).
    static func stepOver(_ index: Int, by: Int, reach: Reach) -> Int {
        var target = max(reach.first, min(reach.last, index + by))
        let way = by < 0 ? -1 : 1
        while reach.gaps.contains(target) { target += way }
        return target
    }

    /// One frame of a flick (`glideStep`): position and velocity after `dt`
    /// ms; velocity 0 once it has come to rest or hit an end or the detent.
    static func glideStep(position p: Double, velocity v: Double, dt: Double, reach: Reach, detent: Int?) -> (position: Double, velocity: Double) {
        var velocity = v * exp(-friction * dt)
        let position = p + velocity * dt
        if position <= Double(reach.first) { return (Double(reach.first), 0) }
        if position >= Double(reach.last) { return (Double(reach.last), 0) }
        if let detent, abs(velocity) < detentCatch {
            let d = Double(detent)
            if (p - d) * (position - d) <= 0, p != d { return (d, 0) }
        }
        if abs(velocity) < atRest { velocity = 0 }
        return (position, velocity)
    }

    static func glideStep(position p: Double, velocity v: Double, dt: Double, last: Int, detent: Int?) -> (position: Double, velocity: Double) {
        glideStep(position: p, velocity: v, dt: dt, reach: .all(last), detent: detent)
    }

    /// The settle's easing (ease-out cubic), `k` in 0…1.
    static func ease(_ k: Double) -> Double {
        1 - pow(1 - max(0, min(1, k)), 3)
    }

    /// The axis labels (`axisTicks`): both ends, and every `every` minutes
    /// from the clock's step in between, away from the ends.
    static func axisTicks(steps: [Int], gridNow: Int, every: Int = 60) -> [(at: Double, step: Int)] {
        guard steps.count > 1 else { return [] }
        let n = Double(steps.count)
        var ticks: [(Double, Int)] = [(0, steps[0])]
        for i in 1 ..< steps.count - 1 {
            let minutes = Int((Double(steps[i] - gridNow) / 60).rounded())
            let at = (Double(i) + 0.5) / n
            if minutes % every == 0, at >= 0.09, at <= 0.91 { ticks.append((at, steps[i])) }
        }
        ticks.append((1, steps[steps.count - 1]))
        return ticks
    }

    /// A ruler tick's height: 13 on the half hours, 7 elsewhere.
    static func isMajor(_ step: Int, gridNow: Int) -> Bool {
        Int((Double(step - gridNow) / 60).rounded()) % 30 == 0
    }
}
