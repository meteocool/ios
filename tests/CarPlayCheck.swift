import CarPlay
import CoreLocation
import Foundation

// Only HTTP is substituted; the parser, requests and CarPlay items are real.
extension URLSession {
    static let meteocool: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CarPlayTransport.self]
        return URLSession(configuration: configuration)
    }()
}

final class CarPlayTransport: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var received: URL?
    nonisolated(unsafe) static var beforeReply: (@Sendable () -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (body, status, beforeReply) = Self.lock.withLock {
            Self.received = request.url
            return (Self.body, Self.status, Self.beforeReply)
        }
        beforeReply?()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct CarPlayCheck {
    static let now = Date(timeIntervalSince1970: 1_735_689_600)

    static func response(_ values: [Double?], observed: Int = 2, age: Int = 0) throws -> Data {
        var frames: [String: Any] = [:]
        for (i, value) in values.enumerated() {
            frames[String(1_735_689_000 - age + i * 300)] = [
                "dbz": value.map { $0 as Any } ?? NSNull(),
                "source": i < observed ? "observation" : "forecast",
            ]
        }
        return try JSONSerialization.data(withJSONObject: ["frames": frames])
    }

    @MainActor static func main() async throws {
        precondition(CarPlayRainStatus.text("carplay_refresh") == "Refresh", "Missing translations must fall back to English for controls too")
        let dry = try response([0, 0, 0, 0, 0, 0])
        let items = CarPlayRainStatus.items(data: dry, threshold: 20, now: now)
        precondition(items.first?.title == "No rain expected", "A complete, fresh dry forecast must show the dry status")
        precondition(items.first?.detail?.contains(now.addingTimeInterval(900).formatted(date: .omitted, time: .shortened)) == true,
                     "Dry status must state the end of its actual forecast coverage")
        let raining = CarPlayRainStatus.items(data: try response([20, 20, 20, 0, 0, 0]), threshold: 20, now: now)
        precondition(raining.first?.title == "Rain at your location", "Rain now must not be described as approaching or dry")
        let approaching = CarPlayRainStatus.items(data: try response([0, 0, 0, 20, 0, 0]), threshold: 20, now: now)
        precondition(approaching.first?.title == "Rain approaching", "Future rain must be distinguished from rain now")

        let unknown = [try response([nil, nil, nil, nil]), try response([0, 0, nil, 0]),
                       try response([0, 0, 0, 0], observed: 0), try response([0, 0, 0, 0], age: 2000),
                       try response([0, 0, 0, 0], age: -2000), Data("{}".utf8)]
        for data in unknown {
            precondition(CarPlayRainStatus.items(data: data, threshold: 20, now: now).first?.title == "Rain forecast unavailable",
                         "Missing, stale, future or malformed weather must never be reported as dry")
        }

        let location = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 48.14, longitude: 11.58), altitude: 0,
                                  horizontalAccuracy: 50, verticalAccuracy: -1, timestamp: now)
        CarPlayTransport.lock.withLock { CarPlayTransport.body = dry }
        let loaded = await CarPlayRainStatus.load(at: location, now: now)
        precondition(loaded.first?.title == "No rain expected", "The real HTTP loader must deliver the parsed forecast")
        let url = CarPlayTransport.lock.withLock { CarPlayTransport.received! }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(url.path == "/v3/radar/timeseries" && query.contains(URLQueryItem(name: "lat", value: "48.1400"))
                     && query.contains(URLQueryItem(name: "lon", value: "11.5800")), "The forecast must be requested at the car's location")

        CarPlayTransport.lock.withLock { CarPlayTransport.status = 503 }
        let failed = await CarPlayRainStatus.load(at: location, now: now)
        precondition(failed.first?.title == "Rain forecast unavailable", "HTTP errors must not reuse a successful forecast body")
        CarPlayTransport.lock.withLock { CarPlayTransport.received = nil }
        let staleLocation = await CarPlayRainStatus.load(at: location, now: now.addingTimeInterval(120))
        precondition(staleLocation.first?.title == "Waiting for your location", "A moving car must not use an old fix")
        precondition(CarPlayTransport.lock.withLock { CarPlayTransport.received == nil }, "An old fix must not trigger a forecast request")

        let defaults = UserDefaults(suiteName: "group.org.frcy.app.meteocool")!
        let original = defaults.object(forKey: "intensityValue")
        defer { defaults.set(original, forKey: "intensityValue") }
        defaults.set(1, forKey: "intensityValue")
        CarPlayTransport.lock.withLock {
            CarPlayTransport.status = 200
            CarPlayTransport.beforeReply = {
                UserDefaults(suiteName: "group.org.frcy.app.meteocool")?.set(4, forKey: "intensityValue")
            }
        }
        let changed = await CarPlayRainStatus.load(at: location, now: now)
        precondition(changed.first?.title == "Rain forecast unavailable", "A request using an old intensity setting must not publish its result")
        CarPlayTransport.lock.withLock { CarPlayTransport.beforeReply = nil }
        print("CarPlay rain status, coverage, freshness, location and HTTP checks passed")
    }
}
