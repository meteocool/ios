//
//  StormCut.swift
//  meteocool
//
//  The slice through an open storm (core's `cutRotationDeg`, `cutSweepDeg`
//  and `lib/cutSweep.ts`): one angle the panel's cutaway and dial turn,
//  links carry, and the 3D map cuts the open storm along.
//

import Foundation
import QuartzCore
import UIKit

/// The open storm's slice, shared by its panel and the 3D map.
@MainActor
final class StormCut: ObservableObject {
    /// Degrees off the storm's track (off north without one), folded.
    @Published private(set) var angle = 0.0
    /// How far the slice has swung on its own on top of `angle`.
    @Published private(set) var sweep = 0.0

    /// The slice as drawn: the reader's angle and the swing.
    var shown: Double { angle + sweep }
    var sweeping: Bool { timer != nil }

    /// Seventy degrees either side, one swing in 24 s, two swings, 20 steps
    /// a second (`AMPLITUDE_DEG`, `PERIOD_SECONDS`, `SWINGS`, `SWEEP_FPS`).
    static let amplitude = 70.0
    static let period = 24.0
    static let swings = 2.0
    static let fps = 20.0

    private var timer: Timer?

    func set(_ degrees: Double) {
        let folded = CutAngle.normalise(degrees)
        if folded != angle { angle = folded }
    }

    /// Swings the slice to either side of where it is, from the start of a
    /// swing, then lets it rest where it began. Not with reduced motion.
    func startSweep() {
        stopSweep(keep: false)
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let start = CACurrentMediaTime()
        timer = Timer.scheduledTimer(withTimeInterval: 1 / Self.fps, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.step(CACurrentMediaTime() - start) }
        }
    }

    private func step(_ seconds: Double) {
        guard timer != nil else { return }
        // Back where it started after whole swings, so nothing is kept.
        if seconds >= Self.swings * Self.period { return stopSweep(keep: true) }
        sweep = Self.amplitude * sin(seconds / Self.period * 2 * .pi)
    }

    /// Stops the swing. `keep` leaves the slice where the swing had taken
    /// it (the reader took hold of it there); otherwise it falls back.
    func stopSweep(keep: Bool) {
        timer?.invalidate()
        timer = nil
        guard sweep != 0 else { return }
        if keep { angle = CutAngle.normalise((angle + sweep).rounded()) }
        sweep = 0
    }
}
