import UIKit
import UserNotifications

@MainActor let SharedNotificationManager = NotificationManager()

@MainActor final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    private let defaults = UserDefaults(suiteName: "group.org.frcy.app.meteocool")
    private var pushToken: String?
    private(set) var authorized = false
    private(set) var syncFailed = false
    private var unregistering = false
    private var removalPending = false

    var enabled: Bool { defaults?.bool(forKey: "pushNotification") == true }
    private var registrationOrigin: URL? {
        guard NetworkHelper.simulatorTestAPI == nil,
              let value = defaults?.string(forKey: "registrationOrigin"),
              let url = URL(string: value),
              [MeteocoolEnvironment.production.apiBaseURL, MeteocoolEnvironment.staging.apiBaseURL].contains(url) else { return nil }
        return url
    }
    var canRegister: Bool {
        let location = SharedLocationUpdater.authorizationStatus
        let sameDeployment = registrationOrigin == nil || registrationOrigin == NetworkHelper.apiURL
        return enabled && authorized && sameDeployment && (location == .authorizedAlways || location == .authorizedWhenInUse)
    }

    func registrationWillBegin() {
        if NetworkHelper.simulatorTestAPI == nil {
            defaults?.set(NetworkHelper.apiURL.absoluteString, forKey: "registrationOrigin")
        }
    }

    override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let open = UNNotificationAction(identifier: "OpenNotification", title: NSLocalizedString("Open", comment: ""), options: .foreground)
        center.setNotificationCategories([UNNotificationCategory(identifier: "WeatherAlert", actions: [open], intentIdentifiers: [])])
    }

    func registerForPushNotifications(_ completion: @escaping (Bool, Error?) -> Void) {
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                authorized = granted
                defaults?.set(granted, forKey: "pushNotification")
                if granted {
                    registerWithAPNs()
                } else {
                    unregister()
                }
                changed()
                completion(granted, nil)
            } catch {
                authorized = false
                defaults?.set(false, forKey: "pushNotification")
                syncFailed = true
                unregister()
                changed()
                completion(false, error)
            }
        }
    }

    /// Called on launch and after returning from Settings; never prompts here.
    func refreshAuthorization() {
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            authorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            if enabled && authorized {
                registerWithAPNs()
                if let origin = registrationOrigin, origin != NetworkHelper.apiURL {
                    unregister()
                } else {
                    SharedLocationUpdater.refreshNotificationRegistration()
                }
            } else {
                unregister()
            }
            changed()
        }
    }

    func disable() {
        defaults?.set(false, forKey: "pushNotification")
        clearNotifications()
        SharedLocationUpdater.updateBackgroundMonitoring()
        unregister()
        changed()
    }

    private func registerWithAPNs() {
        #if DEBUG && targetEnvironment(simulator)
        if NetworkHelper.simulatorTestAPI != nil {
            pushToken = String(repeating: "a", count: 64)
            if canRegister { SharedLocationUpdater.refreshNotificationRegistration() }
            return
        }
        #endif
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Keep the old token only to remove an existing server registration. New
    /// registrations always use the fresh token delivered by APNs this launch.
    func unregister() {
        if unregistering {
            removalPending = true
            return
        }
        guard let token = pushToken ?? defaults?.string(forKey: "pushToken"),
              let request = NetworkHelper.createJSONPostRequest(dst: (registrationOrigin ?? NetworkHelper.apiURL).appendingPathComponent("unregister").absoluteString, dictionary: ["token": token]) else { return }
        unregistering = true
        Task {
            defer {
                unregistering = false
                if removalPending {
                    removalPending = false
                    unregister()
                }
            }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                // Deleting an already absent registration is also complete.
                let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let absent = (response as? HTTPURLResponse)?.statusCode == 200 && body?["message"] as? String == "not registered"
                syncFailed = NetworkHelper.checkResponse(data: data, response: response, error: nil) == nil && !absent
                if !syncFailed { defaults?.removeObject(forKey: "registrationOrigin") }
            } catch {
                syncFailed = true
            }
            changed()
            // A user may have switched back on while removal was in flight.
            if canRegister { SharedLocationUpdater.refreshNotificationRegistration() }
        }
    }

    func registrationFinished(success: Bool) {
        syncFailed = !success
        if success && canRegister { registrationWillBegin() }
        // If the switch changed during an in-flight POST, remove its result.
        if !canRegister { unregister() }
        changed()
    }

    func registrationFailed() {
        pushToken = nil
        syncFailed = true
        changed()
    }

    func clearNotifications() {
        Task { try? await UNUserNotificationCenter.current().setBadgeCount(0) }
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    func setToken(token: String) {
        pushToken = token
        defaults?.set(token, forKey: "pushToken")
        if canRegister {
            SharedLocationUpdater.refreshNotificationRegistration()
        } else {
            unregister()
        }
    }

    func getToken() -> String? { pushToken }

    private func changed() {
        NotificationCenter.default.post(name: NSNotification.Name("SettingsChanged"), object: nil)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        await MainActor.run { self.enabled ? [.banner, .sound, .list] : [] }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run {
            (UIApplication.shared.delegate as? AppDelegate)?.acknowledgeNotification(retry: true, from: "notification")
        }
    }
}
