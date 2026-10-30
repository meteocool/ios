import UIKit
import CoreLocation

@MainActor let SharedAlertMute = AlertMuteManager()

/// Mutes the rain alerts from Settings, and keeps "until the rain is over"
/// in step with the forecast while the app runs. The rules, and why the
/// backend enforces the mute, are in Shared/AlertMute.swift.
@MainActor final class AlertMuteManager {
    private let defaults = UserDefaults(suiteName: AlertHistory.groupID)
    private var lastFollowed: Date?
    private var following = false

    /// How often a rain mute asks the forecast whether its rain is over.
    static let followInterval: TimeInterval = 10 * 60

    enum Outcome {
        case muted
        /// "Until the rain is over" with no rain in the forecast.
        case noRain
        /// No location or no forecast to find the rain in.
        case noForecast
    }

    init() {
        NotificationCenter.default.addObserver(self, selector: #selector(follow),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    /// The mute in effect, nil when the alerts are on.
    var current: AlertMute? { AlertMute.active(in: defaults) }

    /// `pausedUntil` for `post_location`: the mute's end in unix seconds, or
    /// null, which lifts a mute the backend still holds.
    var pausedUntil: Any {
        current.map { Int($0.until.timeIntervalSince1970.rounded(.up)) } ?? NSNull()
    }

    func mute(_ length: AlertMute.Length) async -> Outcome {
        guard length == .rain else {
            set(.timed(length, now: Date()))
            return .muted
        }
        guard let forecast = await forecast() else { return .noForecast }
        guard let mute = AlertMute.rain(forecast) else { return .noRain }
        set(mute)
        return .muted
    }

    func unmute() { set(nil) }

    /// Moves a rain mute's end with the rain, or lifts it once the rain is
    /// over. At most every `followInterval`.
    @objc func follow() {
        guard !following, let mute = current, mute.length == .rain else { return }
        if let lastFollowed, Date().timeIntervalSince(lastFollowed) < Self.followInterval { return }
        following = true
        let background = UIApplication.shared.beginBackgroundTask(withName: "Alert mute", expirationHandler: nil)
        Task {
            if let forecast = await forecast() {
                lastFollowed = Date()
                // Unless the user changed the mute meanwhile.
                let next = mute.following(forecast)
                if current == mute, next != mute { set(next) }
            }
            following = false
            UIApplication.shared.endBackgroundTask(background)
        }
    }

    private func set(_ mute: AlertMute?) {
        AlertMute.save(mute, to: defaults)
        lastFollowed = Date()
        SharedLocationUpdater.refreshNotificationRegistration()
        NotificationCenter.default.post(name: NSNotification.Name("SettingsChanged"), object: nil)
    }

    /// The forecast where the alerts are for, with the user's Intensity
    /// Threshold as the rain that counts, as the alerts have it.
    private func forecast() async -> RainForecast? {
        let coordinate = SharedLocationUpdater.getCurrentLocation()?.coordinate ?? storedCoordinate
        guard let coordinate else { return nil }
        let step = min(max(defaults?.integer(forKey: "intensityValue") ?? 1, 0), RainForecast.thresholds.count - 1)
        let threshold = RainForecast.thresholds[step]
        var components = URLComponents(url: NetworkHelper.apiURL.appendingPathComponent("v3/radar/timeseries"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "lat", value: String(format: "%.4f", coordinate.latitude)),
            URLQueryItem(name: "lon", value: String(format: "%.4f", coordinate.longitude)),
            URLQueryItem(name: "threshold", value: String(format: "%g", threshold)),
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        guard let (data, response) = try? await URLSession.meteocool.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return RainForecast.fromTimeseries(data, threshold: threshold)
    }

    /// The last location the app saw, for when there is no fresh one.
    private var storedCoordinate: CLLocationCoordinate2D? {
        guard let defaults, defaults.object(forKey: "lat") != nil, defaults.object(forKey: "lon") != nil else { return nil }
        return CLLocationCoordinate2D(latitude: defaults.double(forKey: "lat"), longitude: defaults.double(forKey: "lon"))
    }
}
