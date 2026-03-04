import Foundation
import CoreMotion

/**
 * Takes air pressure measurements via CMAltimeter.
 * Gracefully falls back to -1 if the altimeter is unavailable
 * or if the user denies Motion & Fitness permission.
 */
@MainActor
class PressureManager {
    // Lazy to avoid triggering the Motion & Fitness permission at app launch.
    // Only accessed when getPressure() is actually called (i.e. on a location update).
    private lazy var available: Bool = CMAltimeter.isRelativeAltitudeAvailable()
    private lazy var altimeter = CMAltimeter()

    private var lastPressure: Float = 0
    private var lastTimestamp: Double = NSDate().timeIntervalSince1970

    // MARK: - Permission helpers (used by onboarding)

    /// Returns the current Motion & Fitness authorization status.
    /// CMAltimeter is gated by the same permission as CMMotionActivityManager.
    nonisolated static var motionAuthorizationStatus: CMAuthorizationStatus {
        CMMotionActivityManager.authorizationStatus()
    }

    /// Triggers the system Motion & Fitness permission dialog by briefly starting
    /// altimeter updates (there is no explicit "request" API for this permission).
    nonisolated static func requestMotionPermission(completion: @escaping @Sendable (Bool) -> Void) {
        guard CMAltimeter.isRelativeAltitudeAvailable() else {
            completion(false)
            return
        }
        let altimeter = CMAltimeter()
        altimeter.startRelativeAltitudeUpdates(to: .main) { _, _ in
            altimeter.stopRelativeAltitudeUpdates()
            DispatchQueue.main.async {
                completion(CMMotionActivityManager.authorizationStatus() == .authorized)
            }
        }
    }

    func getPressure(completion: @escaping (Float) -> Void) {
        guard available else {
            completion(-1)
            return
        }

        altimeter.startRelativeAltitudeUpdates(to: OperationQueue.main) { [weak self] altitudeData, error in
            guard let self else {
                // PressureManager was deallocated — still call completion so location gets posted
                completion(-1)
                return
            }
            Task { @MainActor in
                self.altimeter.stopRelativeAltitudeUpdates()

                guard let altitudeData, error == nil else {
                    // Permission denied or sensor error — fall back gracefully
                    NSLog("Altimeter unavailable: \(error?.localizedDescription ?? "unknown error")")
                    completion(self.lastPressure != 0 ? self.lastPressure : -1)
                    return
                }

                // Convert kPa to hPa
                let measurement = altitudeData.pressure.floatValue * 10
                self.lastPressure = measurement
                self.lastTimestamp = NSDate().timeIntervalSince1970
                completion(measurement)
            }
        }
    }
}
