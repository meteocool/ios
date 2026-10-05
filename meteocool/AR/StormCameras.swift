//
//  StormCameras.swift
//  meteocool
//
//  Where the AR view's camera comes from: ARKit on a phone, or a drag-to-look
//  preview where there is no ARKit.
//

import ARKit
import CoreLocation
import UIKit
import simd

/// The AR session, in the world frame the scene draws in.
///
/// `gravityAndHeading` puts ARKit's x east, y up and z south, with north
/// taken from the compass at the start; `HeadingAlignment` corrects that
/// north afterwards. Where Apple has localisation imagery, geo tracking
/// replaces the compass with a visual fix.
@MainActor
final class ARKitCamera: NSObject {
    enum Tracking: Equatable {
        case starting
        case normal
        case limited(String)
        case failed(String)
        case cameraDenied
    }

    let session = ARSession()
    private(set) var tracking: Tracking = .starting
    private(set) var usesGeoTracking = false
    private(set) var geoLocalized = false
    var onTrackingChange: ((Tracking) -> Void)?

    static var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }

    override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = .main
    }

    /// Start world tracking, so the camera image is up before the viewer's
    /// position is known.
    func run() {
        start(geo: false)
    }

    /// Switch to geo tracking if ARKit says it works here. Opportunistic: it
    /// exists in a list of cities, none of them under the radar today, and
    /// asking costs nothing. Switching resets tracking, so the caller places
    /// the world again when this says it switched.
    ///
    /// ARKit answers on a queue of its own. The closures are `@Sendable` so
    /// Swift does not take them for main-actor code: inferred main-actor
    /// isolation is checked when the closure runs, and the check traps on any
    /// other queue (which is how this crashed on a phone the first time).
    func upgradeToGeoTracking(at coordinate: CLLocationCoordinate2D, switched: @escaping @MainActor @Sendable () -> Void) {
        guard ARGeoTrackingConfiguration.isSupported, !usesGeoTracking else { return }
        ARGeoTrackingConfiguration.checkAvailability(at: coordinate) { @Sendable available, _ in
            guard available else { return }
            Task { @MainActor [weak self] in
                self?.start(geo: true)
                switched()
            }
        }
    }

    private func start(geo: Bool) {
        if geo {
            session.run(ARGeoTrackingConfiguration(), options: [.resetTracking, .removeExistingAnchors])
        } else {
            let configuration = ARWorldTrackingConfiguration()
            configuration.worldAlignment = .gravityAndHeading
            session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        }
        usesGeoTracking = geo
        geoLocalized = false
    }

    func pause() { session.pause() }

    /// Re-centre the world on the camera, keeping its axes: after the
    /// viewer has moved far enough that their GPS position and the world's
    /// origin no longer agree.
    func recentre() {
        guard let transform = session.currentFrame?.camera.transform else { return }
        var translation = matrix_identity_float4x4
        translation.columns.3 = SIMD4(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z, 1)
        session.setWorldOrigin(relativeTransform: translation)
    }

    /// This frame's pose and image, for an interface in `orientation` drawn at `viewport` points.
    func current(viewport: CGSize, orientation: UIInterfaceOrientation) -> (CameraPose, ARFrame)? {
        guard let frame = session.currentFrame, viewport.width > 0, viewport.height > 0 else { return nil }
        let camera = frame.camera
        let view = camera.viewMatrix(for: orientation)
        let projection = camera.projectionMatrix(for: orientation, viewportSize: viewport, zNear: 1, zFar: 400_000)
        let p = camera.transform.columns.3
        return (CameraPose(view: view, projection: projection, position: SIMD3(p.x, p.y, p.z), viewport: viewport), frame)
    }

    /// The true bearing of the world's -z axis, from two points ARKit has
    /// geo-located; nil until geo tracking has localised.
    func geoNorth() async -> Double? {
        guard usesGeoTracking, geoLocalized else { return nil }
        async let origin = geoLocation(SIMD3(0, 0, 0))
        async let ahead = geoLocation(SIMD3(0, 0, -200))
        guard let a = await origin, let b = await ahead else { return nil }
        return Geo.distanceBearing(fromLat: a.latitude, lon: a.longitude, toLat: b.latitude, lon: b.longitude).bearing
    }

    private func geoLocation(_ point: SIMD3<Float>) async -> CLLocationCoordinate2D? {
        await withCheckedContinuation { continuation in
            // On ARKit's queue, like `checkAvailability`'s answer.
            session.getGeoLocation(forPoint: point) { @Sendable coordinate, _, error in
                continuation.resume(returning: error == nil ? coordinate : nil)
            }
        }
    }

    private func update(_ tracking: Tracking) {
        guard tracking != self.tracking else { return }
        self.tracking = tracking
        onTrackingChange?(tracking)
    }
}

extension ARKitCamera: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let state = camera.trackingState
        MainActor.assumeIsolated {
            switch state {
            case .normal:
                update(.normal)
            case .notAvailable:
                update(.starting)
            case .limited(let reason):
                switch reason {
                case .excessiveMotion: update(.limited(NSLocalizedString("ar_tracking_motion", comment: "")))
                case .insufficientFeatures: update(.limited(NSLocalizedString("ar_tracking_features", comment: "")))
                default: update(.limited(NSLocalizedString("ar_tracking_starting", comment: "")))
                }
            @unknown default:
                update(.starting)
            }
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let code = (error as? ARError)?.code
        let message = error.localizedDescription
        MainActor.assumeIsolated {
            if code == .cameraUnauthorized {
                update(.cameraDenied)
            } else {
                update(.failed(message))
            }
        }
    }

    nonisolated func session(_ session: ARSession, didChange geoTrackingStatus: ARGeoTrackingStatus) {
        let localized = geoTrackingStatus.state == .localized
        MainActor.assumeIsolated { geoLocalized = localized }
    }
}

/// A camera for where there is no ARKit: the simulator, and the UI tests.
///
/// Stands at the world's origin and looks where it is dragged. The same
/// scene and renderer draw over a sky instead of a camera image.
@MainActor
final class PreviewCamera {
    /// True azimuth the camera faces, degrees clockwise from north.
    var yaw: Double = 0
    /// Degrees above the horizontal.
    var pitch: Double = 8
    /// Vertical field of view, degrees.
    var fieldOfView: Double = 55

    func look(byYaw dYaw: Double, pitch dPitch: Double) {
        yaw = Geo.normalise(yaw + dYaw)
        pitch = min(max(pitch + dPitch, -30), 85)
    }

    func zoom(by factor: Double) {
        fieldOfView = min(max(fieldOfView / factor, 15), 90)
    }

    /// The preview's world has no heading error: its -z is true north.
    func pose(viewport: CGSize) -> CameraPose {
        let yawRadians = yaw * .pi / 180, pitchRadians = pitch * .pi / 180
        let rotateY = simd_float4x4(simd_quatf(angle: Float(-yawRadians), axis: SIMD3(0, 1, 0)))
        let rotateX = simd_float4x4(simd_quatf(angle: Float(pitchRadians), axis: SIMD3(1, 0, 0)))
        let cameraToWorld = rotateY * rotateX
        let view = cameraToWorld.transpose
        let aspect = Float(viewport.width / max(viewport.height, 1))
        let projection = Self.perspective(fovY: Float(fieldOfView * .pi / 180), aspect: aspect, near: 1, far: 400_000)
        return CameraPose(view: view, projection: projection, position: .zero, viewport: viewport)
    }

    /// Right-handed, looking down -z, depth 0...1 as Metal has it.
    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let ys = 1 / tan(fovY / 2), xs = ys / aspect, zs = far / (near - far)
        return simd_float4x4(columns: (
            SIMD4(xs, 0, 0, 0),
            SIMD4(0, ys, 0, 0),
            SIMD4(0, 0, zs, -1),
            SIMD4(0, 0, zs * near, 0)))
    }
}
