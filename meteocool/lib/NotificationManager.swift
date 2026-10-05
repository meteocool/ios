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
              let stored = URL(string: value) else { return nil }
        return MeteocoolEnvironment.apiBaseURL(forStored: stored)
    }
    var canRegister: Bool {
        let location = SharedLocationUpdater.authorizationStatus
        let sameDeployment = registrationOrigin == nil || registrationOrigin == NetworkHelper.apiURL
        return enabled && authorized && sameDeployment && (location == .authorizedAlways || location == .authorizedWhenInUse)
    }

    /// Records the API a registration is posted to, before it is sent.
    /// `origin` is the API the request was built for, which is not the
    /// current one when the deployment changed while it was queued.
    func registrationWillBegin(origin: URL) {
        if NetworkHelper.simulatorTestAPI == nil {
            defaults?.set(origin.absoluteString, forKey: "registrationOrigin")
        }
    }

    override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let open = UNNotificationAction(identifier: "OpenNotification", title: NSLocalizedString("Open", comment: ""), options: .foreground)
        center.setNotificationCategories([UNNotificationCategory(identifier: "WeatherAlert", actions: [open], intentIdentifiers: [])])
        // Switching deployments moves the registration: `refreshAuthorization`
        // removes it from the API it was made on, then registers with the new one.
        NotificationCenter.default.addObserver(self, selector: #selector(refreshAuthorization),
                                               name: MeteocoolEnvironment.didChange, object: nil)
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

    /// Rereads notification permission and registers or unregisters to match.
    /// Called on launch and after returning from Settings. Never shows a prompt.
    @objc func refreshAuthorization() {
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

    /// Removes the server registration. Falls back to the stored token if APNs
    /// has not delivered one this launch.
    /// The stored token is used only for removal. New registrations use the
    /// token APNs delivers in the current launch.
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
                // A "not registered" answer counts as a successful removal.
                let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let absent = (response as? HTTPURLResponse)?.statusCode == 200 && body?["message"] as? String == "not registered"
                syncFailed = NetworkHelper.checkResponse(data: data, response: response, error: nil) == nil && !absent
                // Leave the origin to a queued removal: a registration that
                // finished meanwhile set it again, possibly to an API the app
                // has since switched away from.
                if !syncFailed && !removalPending { defaults?.removeObject(forKey: "registrationOrigin") }
            } catch {
                syncFailed = true
            }
            changed()
            // Register again if the user turned alerts back on during the removal request.
            if canRegister { SharedLocationUpdater.refreshNotificationRegistration() }
        }
    }

    func registrationFinished(success: Bool, origin: URL) {
        syncFailed = !success
        // Recorded again because a removal that ran meanwhile cleared it, and
        // the server now holds this registration.
        if success { registrationWillBegin(origin: origin) }
        // Remove the new registration if alerts were turned off, or the
        // deployment changed, while the POST was running.
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

    // The completion-handler forms, not the async ones: UIKit's handler for
    // a tapped notification must be called on the main thread. The async
    // form had Swift call it on the cooperative pool, which crashed the app on
    // every tap (`_performBlockAfterCATransactionCommitSynchronizes:`), and a
    // main-actor async form does not compile because the UserNotifications
    // types are not Sendable. Each handler is called once, on the main actor.

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        nonisolated(unsafe) let completionHandler = completionHandler
        Task { @MainActor in completionHandler(self.foregroundPresentation()) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        nonisolated(unsafe) let completionHandler = completionHandler
        Task { @MainActor in
            (UIApplication.shared.delegate as? AppDelegate)?.acknowledgeNotification(retry: true, from: "notification")
            completionHandler()
        }
    }

    /// Shows nothing while the map is on screen: the user is already looking
    /// at the weather. The alert is still acknowledged, because the server
    /// sends the next one only after this one counts as seen.
    /// CarPlay alone does not count as the app being open: the driver still
    /// gets the alert.
    private func foregroundPresentation() -> UNNotificationPresentationOptions {
        guard enabled else { return [] }
        let mapOnScreen = UIApplication.shared.connectedScenes.contains {
            $0.session.role == .windowApplication && $0.activationState == .foregroundActive
        }
        guard mapOnScreen else { return [.banner, .sound, .list] }
        (UIApplication.shared.delegate as? AppDelegate)?.acknowledgeNotification(retry: true, from: "foreground")
        return []
    }
}
