import Foundation

/// Whether the rain alerts reach a point, as the server decides it.
///
/// ng alerts a phone by the run of the domain the map draws where it is
/// (`meteocool_radar.domain_at`): a network's, else DWD's within its grid.
/// Off every domain it skips the phone as outside the grid, and
/// `GET /v3/mobile/forecast` answers `"domain": null` there. The route wants
/// a push token with a registration, so it is asked once a registration has
/// gone through.
enum NotificationCoverage {
    /// The route, under the API's root (`NetworkHelper.apiURL`).
    static let path = "v3/mobile/forecast"
    /// The push token travels in a header, never in the URL, which proxies log.
    static let tokenHeader = "X-Push-Token"

    static func request(api: URL, token: String, latitude: Double, longitude: Double) -> URLRequest? {
        var components = URLComponents(url: api.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "lat", value: String(format: "%.4f", latitude)),
            URLQueryItem(name: "lon", value: String(format: "%.4f", longitude)),
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(token, forHTTPHeaderField: tokenHeader)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Whether the point is outside every domain: true for `"domain": null`,
    /// false for a domain, nil for an answer that does not say.
    static func outside(_ data: Data) -> Bool? {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let domain = body["domain"] else { return nil }
        if domain is NSNull { return true }
        return domain is String ? false : nil
    }
}
