import UIKit
import CoreLocation

// Isolate OS permissions/APNs and the optional sensor. The production location
// updater, queue, payload serialization and URLSession execution remain real.
@MainActor let viewController: UIViewController? = nil
@MainActor final class PressureManager {
    func getPressure(completion: @escaping (Float) -> Void) { completion(-1) }
}
@MainActor final class NotificationState {
    var canRegister = true
    func getToken() -> String? { String(repeating: "a", count: 64) }
    func unregister() {}
    func registrationWillBegin() {}
    func registrationFinished(success: Bool) { precondition(success) }
}
@MainActor let SharedNotificationManager = NotificationState()

final class LocationManagerSpy: CLLocationManager {
    var stops = 0
    override var authorizationStatus: CLAuthorizationStatus { .authorizedAlways }
    override func stopUpdatingLocation() { stops += 1 }
    override func startMonitoringSignificantLocationChanges() {}
    override func stopMonitoringSignificantLocationChanges() {}
}

// Delay the first transport completion until the second queued fix expires.
final class DelayedTransport: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var count = 0
    static var requests: Int { lock.withLock { count } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.count += 1 }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [self] in
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                                httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"success":true}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

@main struct LocationUpdaterCheck {
    @MainActor static func main() async throws {
        setenv("MC_TEST_API_URL", "http://127.0.0.1:18765/", 1)
        precondition(URLProtocol.registerClass(DelayedTransport.self))
        defer { URLProtocol.unregisterClass(DelayedTransport.self) }
        let manager = LocationManagerSpy()
        let updater = LocationUpdater(locationManager: manager)
        updater.carPlayConnected = true
        updater.stopAccurateLocationUpdates()
        precondition(manager.stops == 0, "Phone tracking off must preserve the CarPlay stream")
        updater.carPlayConnected = false
        updater.stopAccurateLocationUpdates()
        precondition(manager.stops == 1, "Stopping after CarPlay disconnect must still work")

        func fix(age: TimeInterval) -> CLLocation {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: 48.1373, longitude: 11.575),
                       altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10,
                       timestamp: Date(timeIntervalSinceNow: -age))
        }
        updater.postLocation(location: fix(age: 0), pressure: -1)
        updater.postLocation(location: fix(age: 299.8), pressure: -1)
        try await Task.sleep(for: .seconds(1.2))
        precondition(DelayedTransport.requests == 1, "A fix that expires in the queue must not reach transport")
        updater.postLocation(location: fix(age: 0), pressure: -1)
        try await Task.sleep(for: .seconds(0.8))
        precondition(DelayedTransport.requests == 2, "A fresh fix must still be sent after skipping stale work")
        print("CarPlay ownership and delayed location queue checks passed")
    }
}
