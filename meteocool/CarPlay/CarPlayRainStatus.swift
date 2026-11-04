import CarPlay
import CoreLocation
import Foundation

@MainActor enum CarPlayRainStatus {
    struct Settings: Equatable {
        let origin: URL
        let threshold: Double
    }

    static var settings: Settings {
        let defaults = UserDefaults(suiteName: "group.org.frcy.app.meteocool")
        let step = min(max(defaults?.object(forKey: "intensityValue") as? Int ?? 1, 0), RainForecast.thresholds.count - 1)
        return Settings(origin: NetworkHelper.apiURL, threshold: RainForecast.thresholds[step])
    }

    static var loading: [CPInformationItem] {
        [CPInformationItem(title: text("carplay_loading"), detail: nil)]
    }

    static var noLocation: [CPInformationItem] {
        [CPInformationItem(title: text("carplay_no_location"), detail: text("carplay_location_detail"))]
    }

    private static var unavailable: [CPInformationItem] {
        [CPInformationItem(title: text("carplay_unavailable"), detail: text("carplay_retry_detail"))]
    }

    static func load(at location: CLLocation, now: Date? = nil) async -> [CPInformationItem] {
        guard CLLocationCoordinate2DIsValid(location.coordinate), location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= 1000, abs(location.timestamp.timeIntervalSince(now ?? Date())) <= 60 else { return noLocation }
        let settings = Self.settings
        var components = URLComponents(url: settings.origin.appendingPathComponent("v3/radar/timeseries"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "lat", value: String(format: "%.4f", location.coordinate.latitude)),
            URLQueryItem(name: "lon", value: String(format: "%.4f", location.coordinate.longitude)),
            URLQueryItem(name: "threshold", value: String(format: "%g", settings.threshold)),
            URLQueryItem(name: "lang", value: AlertLanguage.current),
        ]
        guard let url = components?.url else { return unavailable }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        guard let (data, response) = try? await URLSession.meteocool.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return unavailable }
        let received = now ?? Date()
        guard abs(location.timestamp.timeIntervalSince(received)) <= 60 else { return noLocation }
        guard settings == Self.settings else { return unavailable }
        return items(data: data, threshold: settings.threshold, now: received)
    }

    static func items(data: Data, threshold: Double, now: Date) -> [CPInformationItem] {
        guard let forecast = RainForecast.fromTimeseries(data, threshold: threshold),
              forecast.observed > 0, forecast.observed < forecast.dbz.count else { return unavailable }
        let observed = forecast.date(at: forecast.nowIndex)
        guard observed <= now.addingTimeInterval(60),
              !ConnectionRules.outdated(newestObservation: Int(observed.timeIntervalSince1970), period: forecast.interval,
                                        now: Int(now.timeIntervalSince1970)),
              forecast.dbz[forecast.nowIndex...].allSatisfy({ $0?.isFinite == true }) else { return unavailable }
        let title: String
        let detail: String
        switch forecast.phase {
        case .raining(let end):
            title = text("carplay_raining")
            detail = end.map { format("carplay_until", time($0)) } ?? text("carplay_continues")
        case .approaching(let arrival, _):
            title = text("carplay_approaching")
            detail = format("carplay_starts", time(arrival))
        case .dry:
            title = text("carplay_dry")
            detail = format("carplay_through", time(forecast.date(at: forecast.dbz.count - 1)))
        }
        return [CPInformationItem(title: title, detail: detail),
                CPInformationItem(title: text("carplay_updated"), detail: time(observed))]
    }

    static func text(_ key: String) -> String {
        let english = Bundle.main.url(forResource: "en", withExtension: "lproj").flatMap(Bundle.init(url:))
        return Bundle.main.localizedString(forKey: key, value: english?.localizedString(forKey: key, value: nil, table: nil), table: nil)
    }
    private static func format(_ key: String, _ value: String) -> String { String(format: text(key), value) }
    private static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
}
