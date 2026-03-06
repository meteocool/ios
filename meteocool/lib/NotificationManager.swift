import UIKit
import UserNotifications

@MainActor let SharedNotificationManager = NotificationManager()

@MainActor
class NotificationManager: NSObject {
    private var pushToken: String?
    private let settings: SettingsStore

    init(settings: SettingsStore = .shared) {
        self.settings = settings
        super.init()
        if settings.notificationsEnabled {
            self.registerForPushNotifications({_,_ in return})
        }
    }

    func registerForPushNotifications(_ completion: @escaping @Sendable (_ success: Bool, _ error: Error?) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) {
            (granted, _) in
            NSLog("Permission granted: \(granted)")
            // XXX just forward granted to the other completionhandler?
            guard granted else {
                print("Falsifying completion handler")
                Task { @MainActor in
                    self.settings.notificationsEnabled = false
                }
                completion(false, nil)
                return
            }
            completion(true, nil)
            Task { @MainActor in
                self.settings.notificationsEnabled = true
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
        let openAction = UNNotificationAction(identifier: "OpenNotification", title: NSLocalizedString("Open", comment: ""), options: UNNotificationActionOptions.foreground)
        let deafultCategory = UNNotificationCategory(identifier: "WeatherAlert", actions: [openAction], intentIdentifiers: [], options: [])
        center.setNotificationCategories(Set([deafultCategory]))
    }

    @MainActor
    func register() async throws {
        let center = UNUserNotificationCenter.current()
        let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        if granted {
            settings.notificationsEnabled = true
            UIApplication.shared.registerForRemoteNotifications()
        } else {
            settings.notificationsEnabled = false
        }
    }

    func unregisterFromBackend() {
        guard let token = getToken() else {
            NSLog("Would unregister, but no token")
            return
        }
        guard let request = NetworkHelper.createJSONPostRequest(dst: "unregister", dictionary: ["token": token]) else {
            NSLog("Would unregister, but request creation failed")
            return
        }
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = NetworkHelper.checkResponse(data: data, response: response, error: error) else {
                return
            }
            if let json = ((try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]) as [String: Any]??),
               let errorMessage = json?["error"] as? String {
                NSLog("ERROR: \(errorMessage)")
            }
        }.resume()
    }

    func clearNotifications() {
        UNUserNotificationCenter.current().setBadgeCount(0) { _ in }
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    // caching implementation of getter/setter for the APNS push token. Apple says not to
    // cache the token, but for some reason the AppDelegate sometimes doesn't get the token
    // delivered upon re-registering...
    func setToken(token: String) {
        self.pushToken = token
        UserDefaults(suiteName: SettingsStore.Keys.suite)?.setValue(token, forKey: "pushToken")
    }

    func getToken() -> String? {
        if self.pushToken == nil {
            self.pushToken = UserDefaults(suiteName: SettingsStore.Keys.suite)?.value(forKey: "pushToken") as? String
        }
        return self.pushToken
    }
    /// Check actual OS notification authorization status
    func checkAuthorizationStatus() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        default:
            return false
        }
    }
}
