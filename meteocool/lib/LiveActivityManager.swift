import ActivityKit
import CoreLocation
import UIKit

@MainActor let SharedLiveActivities = LiveActivityManager()

/// The rain Live Activity: the radar image and the bar chart on the lock
/// screen for as long as it rains at the user's location.
///
/// Two things drive it, and either works without the other:
/// - **The backend**, over APNs. The app sends it a push-to-start token and
///   each activity's update token (`POST /v3/mobile/live_activity`); with
///   those it can start the activity when its alert would fire, update it
///   every run and end it when the rain is over, while the app is not running.
/// - **The app**, whenever it runs. In the foreground it starts the activity
///   when rain is near, and on every run (foreground, background location
///   fixes, background pushes) it updates and ends it from
///   `/v3/radar/timeseries`, and saves a new radar image for it.
///
/// The image is the app's part in both cases: an activity cannot download
/// anything, so it shows the last image the app saved (`RadarImageStore`).
@MainActor final class LiveActivityManager {
    private let defaults = UserDefaults(suiteName: "group.org.frcy.app.meteocool")
    private var started = false
    private var observed: Set<String> = []
    private var startToken: String?
    private var activityTokens: [String: String] = [:]
    private var synced: Data?
    private var syncing = false
    private var syncPending = false
    private var refreshing: Task<Void, Never>?
    private var lastRefresh: Date?

    /// How long a state counts as current. The backend updates every run,
    /// about every five minutes; three missed runs and the activity says so.
    static let staleAfter: TimeInterval = 15 * 60
    /// How often the app refetches the forecast and the radar image.
    static let refreshInterval: TimeInterval = 2 * 60
    /// How long the final "the rain is over" state stays on the lock screen.
    static let dismissAfter: TimeInterval = 15 * 60

    /// Set when the user swipes an activity away, cleared when the rain is
    /// over: the app does not start another one for the same rain.
    private var dismissed: Bool {
        get { defaults?.bool(forKey: "liveActivityDismissed") == true }
        set { defaults?.set(newValue, forKey: "liveActivityDismissed") }
    }

    /// The Live Activity setting, on unless the user turned it off.
    var preferred: Bool { defaults?.object(forKey: "liveActivity") as? Bool ?? true }

    /// Whether activities may appear: the setting, rain alerts, and the
    /// system's per-app Live Activities switch.
    var enabled: Bool {
        preferred && SharedNotificationManager.enabled && ActivityAuthorizationInfo().areActivitiesEnabled
    }

    private var activities: [Activity<RainActivityAttributes>] {
        Activity<RainActivityAttributes>.activities.filter { $0.activityState == .active || $0.activityState == .stale }
    }

    /// Starts watching tokens and activities, once per launch.
    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(self, selector: #selector(environmentChanged),
                                               name: MeteocoolEnvironment.didChange, object: nil)
        Task {
            for await token in Activity<RainActivityAttributes>.pushToStartTokenUpdates {
                startToken = Self.hex(token)
                sync()
            }
        }
        Task {
            for await activity in Activity<RainActivityAttributes>.activityUpdates {
                observe(activity)
            }
        }
        Task {
            for await _ in ActivityAuthorizationInfo().activityEnablementUpdates {
                settingChanged()
            }
        }
        Activity<RainActivityAttributes>.activities.forEach(observe)
    }

    /// Follows one activity's token and end. An activity the backend started
    /// arrives here too: iOS gives the app a moment in the background for
    /// its token, which is also the moment to save a radar image for it.
    private func observe(_ activity: Activity<RainActivityAttributes>) {
        guard observed.insert(activity.id).inserted else { return }
        let id = activity.id
        Task {
            for await token in activity.pushTokenUpdates {
                activityTokens[id] = Self.hex(token)
                sync()
            }
        }
        Task {
            for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
                // Dismissed without having ended: the user swiped it away.
                // It stays away until this rain is over.
                if state == .dismissed { dismissed = true }
                activityTokens[id] = nil
                observed.remove(id)
                sync()
                break
            }
        }
        refresh(force: true)
    }

    /// Called when the setting, rain alerts or the system switch change.
    func settingChanged() {
        if !enabled { endAll(immediately: true) }
        sync()
        refresh(force: true)
    }

    @objc private func environmentChanged() {
        // The activities show the old deployment's rain, and that deployment
        // forgets their tokens with the push registration.
        endAll(immediately: true)
        activityTokens.removeAll()
        synced = nil
        sync()
    }

    // MARK: - Backend

    /// Sends the tokens to the backend when they changed since the last
    /// successful send. Needs the device's APNs token, which names the
    /// registration; sent again when a registration finishes, because the
    /// backend answers 404 for a device it does not know yet.
    func sync() {
        guard SharedNotificationManager.enabled, let device = SharedNotificationManager.getToken() else { return }
        if syncing {
            syncPending = true
            return
        }
        let on = enabled
        let body: [String: Any] = [
            "token": device,
            "enabled": on,
            "startToken": on ? startToken ?? NSNull() : NSNull(),
            "activityToken": activities.compactMap { activityTokens[$0.id] }.first ?? NSNull(),
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: body, options: .sortedKeys), json != synced,
              let request = NetworkHelper.createJSONPostRequest(
                dst: NetworkHelper.apiURL.appendingPathComponent("v3/mobile/live_activity").absoluteString, dictionary: body) else { return }
        syncing = true
        Task {
            defer {
                syncing = false
                if syncPending {
                    syncPending = false
                    sync()
                }
            }
            guard let (_, response) = try? await URLSession.shared.data(for: request),
                  let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
                // Tokens are not secret, but they are not logged either.
                NSLog("Live Activity tokens not accepted")
                return
            }
            synced = json
        }
    }

    // MARK: - Local updates

    /// Brings the activity in line with the forecast at the user's location.
    ///
    /// Only the foreground can start an activity, so in the background this
    /// does nothing until one exists. Runs at most every `refreshInterval`
    /// unless `force`d.
    @discardableResult
    func refresh(location: CLLocation? = nil, force: Bool = false) -> Task<Void, Never>? {
        guard enabled else { return nil }
        let foreground = UIApplication.shared.applicationState == .active
        guard foreground || !activities.isEmpty, refreshing == nil else { return refreshing }
        if !force, let lastRefresh, Date().timeIntervalSince(lastRefresh) < Self.refreshInterval { return nil }
        let location = location ?? SharedLocationUpdater.getCurrentLocation()
        // Without a recent fix (a push-to-start can wake the app long after
        // the last one) the activity still gets a new image from its own URL.
        guard location != nil || activities.contains(where: { $0.content.state.radar != nil }) else { return nil }
        lastRefresh = Date()
        let background = UIApplication.shared.beginBackgroundTask(withName: "Live Activity", expirationHandler: nil)
        let task = Task {
            if let location {
                if let forecast = await fetchForecast(at: location) {
                    await apply(forecast, at: location, foreground: foreground)
                }
            } else if let activity = activities.first {
                var state = activity.content.state
                if let url = state.radar.flatMap(URL.init(string:)), let saved = await Self.saveImage(from: url) {
                    state.radarSaved = Int(saved.timeIntervalSince1970)
                    await Self.update(activity.id, content: ActivityContent(state: state, staleDate: activity.content.staleDate))
                }
            }
            refreshing = nil
            UIApplication.shared.endBackgroundTask(background)
        }
        refreshing = task
        return task
    }

    private func apply(_ forecast: RainForecast, at location: CLLocation, foreground: Bool) async {
        let current = activities
        var state = forecast
        state.radar = current.first?.content.state.radar ?? Self.previewURL(at: location).absoluteString
        state.radarSaved = current.first?.content.state.radarSaved
        if state.phase == .dry {
            dismissed = false
            for activity in current {
                await Self.end(activity.id, content: ActivityContent(state: state, staleDate: nil),
                               dismissalPolicy: .after(Date().addingTimeInterval(Self.dismissAfter)))
            }
            return
        }
        guard !current.isEmpty || (foreground && !dismissed && Self.isNear(state, ahead: aheadMinutes)) else { return }
        if let url = state.radar.flatMap(URL.init(string:)), let saved = await Self.saveImage(from: url) {
            state.radarSaved = Int(saved.timeIntervalSince1970)
        }
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(Self.staleAfter))
        if current.isEmpty {
            do {
                observe(try Activity.request(attributes: RainActivityAttributes(), content: content, pushType: .token))
            } catch {
                NSLog("Live Activity not started: \(error.localizedDescription)")
            }
        } else {
            for activity in current { await Self.update(activity.id, content: content) }
        }
    }

    /// Rain now, or arriving within the user's Notification Timeframe: when
    /// the backend's alert would fire.
    static func isNear(_ forecast: RainForecast, ahead: Int) -> Bool {
        switch forecast.phase {
        case .raining: return true
        case .approaching(let arrival, _): return arrival.timeIntervalSince(forecast.now) <= TimeInterval(ahead * 60)
        case .dry: return false
        }
    }

    private var aheadMinutes: Int {
        (min(max(defaults?.integer(forKey: "timeBeforeValue") ?? 2, 0), 8) + 1) * 5
    }

    private var threshold: Double {
        RainForecast.thresholds[min(max(defaults?.integer(forKey: "intensityValue") ?? 1, 0), 4)]
    }

    private func fetchForecast(at location: CLLocation) async -> RainForecast? {
        var components = URLComponents(url: NetworkHelper.apiURL.appendingPathComponent("v3/radar/timeseries"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "lat", value: String(format: "%.4f", location.coordinate.latitude)),
            URLQueryItem(name: "lon", value: String(format: "%.4f", location.coordinate.longitude)),
        ]
        guard let url = components?.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return RainForecast.fromTimeseries(data, threshold: threshold)
    }

    /// The same square preview the rain alerts attach, rendered by the API's
    /// preview service and centred on `location`.
    static func previewURL(at location: CLLocation) -> URL {
        var components = URLComponents(url: NetworkHelper.apiURL.appendingPathComponent("v3/preview/og.png"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "latLonZ", value: String(format: "%.3f,%.3f,9.5", location.coordinate.latitude, location.coordinate.longitude)),
            URLQueryItem(name: "aspectRatio", value: "square"),
            URLQueryItem(name: "logo", value: "false"),
        ]
        return components.url!
    }

    /// Downloads and saves the radar image, unless the saved one is recent.
    private static func saveImage(from url: URL) async -> Date? {
        if let saved = RadarImageStore.load()?.saved, Date().timeIntervalSince(saved) < refreshInterval { return nil }
        guard url.scheme == "https" || NetworkHelper.simulatorTestAPI != nil else { return nil }
        var request = URLRequest(url: url)
        // A cold render takes up to 20 s; a background run has about 30.
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return RadarImageStore.save(data)
    }

    func endAll(immediately: Bool) {
        for activity in activities {
            let id = activity.id
            Task { await Self.end(id, content: nil, dismissalPolicy: immediately ? .immediate : .default) }
        }
    }

    // `Activity` is not Sendable, so it is looked up again off the main
    // actor rather than handed to ActivityKit's nonisolated methods.

    private nonisolated static func update(_ id: String, content: ActivityContent<RainForecast>) async {
        await Activity<RainActivityAttributes>.activities.first { $0.id == id }?.update(content)
    }

    private nonisolated static func end(_ id: String, content: ActivityContent<RainForecast>?, dismissalPolicy: ActivityUIDismissalPolicy) async {
        await Activity<RainActivityAttributes>.activities.first { $0.id == id }?.end(content, dismissalPolicy: dismissalPolicy)
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
