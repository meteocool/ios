import CoreMotion
import Foundation

@MainActor final class PressureManager {
    private let altimeter = CMAltimeter()
    private var completions: [(Float) -> Void] = []
    private var timeout: Task<Void, Never>?

    func getPressure(completion: @escaping (Float) -> Void) {
        // Pressure is optional telemetry. Never delay rain-alert registration
        // for a motion prompt or a sensor that cannot provide a reading.
        guard CMAltimeter.isRelativeAltitudeAvailable(), CMAltimeter.authorizationStatus() == .authorized else {
            completion(-1)
            return
        }
        completions.append(completion)
        guard completions.count == 1 else { return }
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.finish(-1)
        }
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] reading, _ in
            let pressure = reading.map { $0.pressure.floatValue * 10 } ?? -1
            Task { @MainActor in self?.finish(pressure) }
        }
    }

    private func finish(_ pressure: Float) {
        altimeter.stopRelativeAltitudeUpdates()
        timeout?.cancel()
        timeout = nil
        let waiting = completions
        completions.removeAll()
        waiting.forEach { $0(pressure) }
    }
}
