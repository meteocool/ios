//
//  HeadingAlignment.swift
//  meteocool
//
//  Which way is north, as far as the overlay is concerned.
//

import CoreLocation
import CoreMotion
import Foundation

/// The correction between ARKit's idea of north and true north.
///
/// Everything else in the AR view is easy to get right: GPS puts the viewer
/// within metres, gravity gives pitch and roll to a fraction of a degree. The
/// heading is the hard part. ARKit's `gravityAndHeading` takes north from
/// the magnetometer once, at the start, and that is good to perhaps 5-15
/// degrees -- at 30 km, 10 degrees is 5 km sideways, which is exactly the
/// "this storm or the one next to it" error the view exists to remove.
///
/// `error` is how far ARKit's north is off, clockwise: a camera ARKit thinks
/// faces azimuth `a` really faces `a + error`. The overlay is drawn rotated
/// by `-error`, so a storm at true bearing `b` appears at ARKit bearing
/// `b - error`. It comes from, in increasing order of trust:
///
/// 1. the compass, low-passed against ARKit's own visual-inertial yaw, which
///    drifts slowly where the compass jumps;
/// 2. the reader dragging the overlay sideways until it sits on the real storm;
/// 3. the reader tapping the sun, whose position is known exactly;
/// 4. ARKit's geo tracking, where Apple has localisation imagery.
///
/// Once the reader has nudged or tapped the sun, the compass no longer
/// moves the overlay: it would only undo what they did.
@MainActor
final class HeadingAlignment {
    enum Source: Equatable {
        case compass
        case manual
        case sun
        case geoTracking
    }

    enum SunFixResult: Equatable {
        case aligned(correction: Double)
        case sunBelowHorizon
        /// The tap was too far from where the sun should be, in elevation,
        /// to be the sun: a lamp, a reflection, a bright cloud edge.
        case notTheSun(elevationOff: Double)
    }

    private(set) var error: Double = 0
    private(set) var source: Source = .compass

    /// How quickly the compass pulls the overlay round, as a time constant.
    private static let compassSeconds = 12.0
    /// A sun tap further than this off in elevation is not the sun.
    private static let sunElevationTolerance = 6.0

    private let motion = CMMotionManager()
    private let headings = CLLocationManager()
    private let headingDelegate = HeadingDelegate()
    private var declination: Double?
    private var compassAzimuth: Double?
    private var compassAt: Date?
    private var lastBlend: Date?

    func start() {
        // Magnetic declination, the difference between the two headings
        // Core Location reports for the same axis, turns a magnetic azimuth
        // into a true one.
        if CLLocationManager.headingAvailable() {
            headingDelegate.onHeading = { [weak self] heading in
                guard heading.trueHeading >= 0, heading.headingAccuracy >= 0 else { return }
                self?.declination = Geo.angleDifference(heading.trueHeading, heading.magneticHeading)
            }
            headings.delegate = headingDelegate
            headings.headingFilter = 1
            headings.startUpdatingHeading()
        }
        guard motion.isDeviceMotionAvailable,
              CMMotionManager.availableAttitudeReferenceFrames().contains(.xMagneticNorthZVertical) else { return }
        motion.deviceMotionUpdateInterval = 1 / 30
        // Delivered on the main queue, as asked, so the main-actor isolation
        // Swift infers for this closure holds when it runs.
        motion.startDeviceMotionUpdates(using: .xMagneticNorthZVertical, to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            MainActor.assumeIsolated { self?.receive(motion) }
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        headings.stopUpdatingHeading()
    }

    private func receive(_ motion: CMDeviceMotion) {
        // An uncalibrated field is the raw magnetometer, hard iron and all.
        guard motion.magneticField.accuracy != .uncalibrated, let declination else {
            compassAzimuth = nil
            return
        }
        let g = motion.gravity, f = motion.magneticField.field
        guard let magnetic = Compass.cameraAzimuth(gravity: SIMD3(g.x, g.y, g.z), magneticField: SIMD3(f.x, f.y, f.z)) else {
            compassAzimuth = nil
            return
        }
        compassAzimuth = Geo.normalise(magnetic + declination)
        compassAt = Date()
    }

    /// Blend the compass in, given where ARKit thinks the camera points.
    /// Called every frame; does nothing once the reader has aligned by hand.
    func update(frameAzimuth: Double, now: Date = Date()) {
        guard source == .compass, let compassAzimuth, let compassAt, now.timeIntervalSince(compassAt) < 1 else { return }
        let measured = Geo.angleDifference(compassAzimuth, frameAzimuth)
        if let lastBlend {
            let dt = min(max(now.timeIntervalSince(lastBlend), 0), 1)
            let k = 1 - exp(-dt / Self.compassSeconds)
            error = Geo.angleDifference(error + k * Geo.angleDifference(measured, error), 0)
        } else {
            // The first good reading since a reset is taken as it is.
            error = measured
        }
        lastBlend = now
    }

    /// The reader dragged the overlay by `degrees` of azimuth; positive moves
    /// it clockwise (to the right).
    func nudge(by degrees: Double) {
        guard source != .geoTracking else { return }
        error = Geo.angleDifference(error - degrees, 0)
        source = .manual
    }

    /// Align on the sun, given the direction the reader tapped in ARKit's
    /// frame (azimuth assuming its -z is north, and elevation).
    func sunFix(tappedAzimuth: Double, tappedElevation: Double, sun: (azimuth: Double, elevation: Double)) -> SunFixResult {
        guard sun.elevation > -0.5 else { return .sunBelowHorizon }
        let elevationOff = tappedElevation - sun.elevation
        guard abs(elevationOff) <= Self.sunElevationTolerance else { return .notTheSun(elevationOff: elevationOff) }
        let correction = Geo.angleDifference(sun.azimuth, tappedAzimuth)
        error = correction
        source = .sun
        return .aligned(correction: correction)
    }

    /// ARKit's geo tracking has localised: `trueNorthAzimuth` is the true
    /// bearing of its -z axis, measured from two geo-located world points.
    func geoTracked(trueNorthAzimuth: Double) {
        error = Geo.angleDifference(trueNorthAzimuth, 0)
        source = .geoTracking
    }

    /// Back to the compass.
    func reset() {
        source = .compass
        lastBlend = nil
    }

    /// For the preview, which has no compass and starts aligned.
    func resetToZero() {
        error = 0
        source = .compass
        lastBlend = nil
    }
}

/// Receives heading updates for `HeadingAlignment`. Core Location calls a
/// delegate on the queue its manager was created on, which is the main one
/// here, as in `LocationUpdater`.
@MainActor
private final class HeadingDelegate: NSObject, @preconcurrency CLLocationManagerDelegate {
    var onHeading: ((CLHeading) -> Void)?

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        onHeading?(newHeading)
    }

    func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool { false }
}
