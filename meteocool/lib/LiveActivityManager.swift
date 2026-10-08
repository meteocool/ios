import ActivityKit
import UIKit

@MainActor let SharedLiveActivities = LiveActivityManager()

/// The rain Live Activity: the radar image and the bar chart on the lock
/// screen for as long as it rains at the user's location.
///
/// The backend drives it, over APNs: the app sends it a push-to-start token
/// and each activity's update token (`POST /v3/mobile/live_activity`), and
/// the backend alone decides when to start, update, alert and end, by the
/// same rules as its rain alerts on every platform.
///
/// The image is the app's only part: an activity cannot download anything,
/// so it shows the last image the app saved (`RadarImageStore`), fetched
/// from the activity's own `radar` URL whenever the app runs.
@MainActor final class LiveActivityManager {
    private let defaults = UserDefaults(suiteName: "group.org.frcy.app.meteocool")
    private var started = false
    private var observed: Set<String> = []
    private var startToken: String?
    private var activityTokens: [String: String] = [:]
    private var synced: Data?
    private var syncing = false
    private var syncPending = false
    private var forcePending = false
    private var refreshing: Task<Void, Never>?
    private var lastRefresh: Date?

    /// How often the app refetches the radar image.
    static let refreshInterval: TimeInterval = 2 * 60

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
                // A swipe sends `activityToken: null`; the backend keeps it
                // away for the rest of the rain.
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
    ///
    /// `force` sends them anyway: after a registration, which may be a new
    /// record on the backend (after an unregister, say) that has none of them.
    /// Skipping that send left the backend without a start token, so it fell
    /// back to plain notifications until the app was relaunched.
    func sync(force: Bool = false) {
        guard SharedNotificationManager.enabled, let device = SharedNotificationManager.getToken() else { return }
        if syncing {
            syncPending = true
            forcePending = forcePending || force
            return
        }
        let on = enabled
        let body: [String: Any] = [
            "token": device,
            "enabled": on,
            "startToken": on ? startToken ?? NSNull() : NSNull(),
            "activityToken": activities.compactMap { activityTokens[$0.id] }.first ?? NSNull(),
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: body, options: .sortedKeys), force || json != synced,
              let request = NetworkHelper.createJSONPostRequest(
                dst: NetworkHelper.apiURL.appendingPathComponent("v3/mobile/live_activity").absoluteString, dictionary: body) else { return }
        syncing = true
        Task {
            defer {
                syncing = false
                if syncPending {
                    let force = forcePending
                    syncPending = false
                    forcePending = false
                    sync(force: force)
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

    // MARK: - Radar image

    /// Saves a new radar image for the running activity and redraws it.
    /// Runs at most every `refreshInterval` unless `force`d.
    @discardableResult
    func refresh(force: Bool = false) -> Task<Void, Never>? {
        guard enabled, refreshing == nil else { return refreshing }
        guard let activity = activities.first,
              let url = activity.content.state.radar.flatMap(URL.init(string:)) else { return nil }
        if !force, let lastRefresh, Date().timeIntervalSince(lastRefresh) < Self.refreshInterval { return nil }
        lastRefresh = Date()
        let id = activity.id
        let background = UIApplication.shared.beginBackgroundTask(withName: "Live Activity", expirationHandler: nil)
        let task = Task {
            if let saved = await Self.saveImage(from: url),
               let current = activities.first(where: { $0.id == id }) {
                var state = current.content.state
                state.radarSaved = Int(saved.timeIntervalSince1970)
                await Self.update(id, content: ActivityContent(state: state, staleDate: current.content.staleDate))
            }
            refreshing = nil
            UIApplication.shared.endBackgroundTask(background)
        }
        refreshing = task
        return task
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
