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

    /// A position past the ends, pulled back like a spring (`rubberBand`).
    static func rubberBand(_ p: Double, last: Double) -> Double {
        if p < 0 { return -overshoot * (1 - 1 / (1 + -p / overshoot)) }
        if p > last { return last + overshoot * (1 - 1 / (1 + (p - last) / overshoot)) }
        return p
    }

    /// Where a needle at rest belongs (`restingStep`): on now when close to
    /// it, else on the nearest whole step.
    static func restingStep(_ p: Double, last: Int, detent: Int?) -> Int {
        if let detent, abs(p - Double(detent)) <= detentSteps { return detent }
        return max(0, min(last, Int(p.rounded())))
    }

    /// One frame of a flick (`glideStep`): position and velocity after `dt`
    /// ms; velocity 0 once it has come to rest or hit an end or the detent.
    static func glideStep(position p: Double, velocity v: Double, dt: Double, last: Int, detent: Int?) -> (position: Double, velocity: Double) {
        var velocity = v * exp(-friction * dt)
        let position = p + velocity * dt
        if position <= 0 { return (0, 0) }
        if position >= Double(last) { return (Double(last), 0) }
        if let detent, abs(velocity) < detentCatch {
            let d = Double(detent)
            if (p - d) * (position - d) <= 0, p != d { return (d, 0) }
        }
        if abs(velocity) < atRest { velocity = 0 }
        return (position, velocity)
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
