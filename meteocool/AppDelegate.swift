import UIKit
import UserNotifications

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    let userDefaults = UserDefaults.init(suiteName: "group.org.frcy.app.meteocool")

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--ui-test-reset") {
            userDefaults?.removePersistentDomain(forName: "group.org.frcy.app.meteocool")
        }
        #endif
        // Override point for customization after application launch.

        //Settings
        if (userDefaults?.value(forKey: "pushNotification") == nil){
            userDefaults?.setValue(false, forKey: "pushNotification")
        }
        if (userDefaults?.value(forKey: "intensityValue") == nil){
            userDefaults?.setValue(1, forKey: "intensityValue")
            // 0 -> drizzle
            // 1 -> light
            // 2 -> rain
            // 3 -> intense
            // 4 -> hail
        }
        if (userDefaults?.value(forKey: "timeBeforeValue") == nil){
            userDefaults?.setValue(2, forKey: "timeBeforeValue")
            //Value +1 *5 for minutes
        }
        if (userDefaults?.value(forKey: "withDBZ") == nil){
            userDefaults?.setValue(false, forKey: "withDBZ")
        }
        if (userDefaults?.value(forKey: "mapRotation") == nil){
            userDefaults?.setValue(false, forKey: "mapRotation")
        }
        if (userDefaults?.value(forKey: "autoZoom") == nil){
            userDefaults?.setValue(false, forKey: "autoZoom")
        }
        if (userDefaults?.value(forKey: "radarColorMapping") == nil){
            userDefaults?.setValue("classic", forKey: "radarColorMapping")
        }
        if (userDefaults?.value(forKey: "baseLayer") == nil){
            userDefaults?.setValue("light", forKey: "baseLayer")
        }
        // Satellite was withdrawn from the web map, so a stored "satellite"
        // now selects nothing in the picker and draws the default anyway.
        if (userDefaults?.string(forKey: "baseLayer") == "satellite"){
            userDefaults?.setValue("light", forKey: "baseLayer")
        }
        if (userDefaults?.value(forKey: "experimentalFeatures") == nil){
            userDefaults?.setValue(false, forKey: "experimentalFeatures")
        }

        if let userDefaults {
            userDefaults.set(min(max(userDefaults.integer(forKey: "intensityValue"), 0), 4), forKey: "intensityValue")
            userDefaults.set(min(max(userDefaults.integer(forKey: "timeBeforeValue"), 0), 8), forKey: "timeBeforeValue")
        }
        SharedNotificationManager.refreshAuthorization()
        return true
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        guard userInfo["clear_all"] as? Bool == true else {
            completionHandler(.noData)
            return
        }
        SharedNotificationManager.clearNotifications()
        acknowledgeNotification(retry: true, from: "push") { success in
            completionHandler(success ? .newData : .failed)
        }
    }

    func acknowledgeNotification(retry: Bool, from: String, completion: @escaping (Bool) -> Void = { _ in }) {
        guard let token = SharedNotificationManager.getToken() else {
            if (retry) {
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(4), execute: {
                    self.acknowledgeNotification(retry: false, from: from, completion: completion)
                })
            } else {
                completion(false)
            }
            return
        }

        let locationDict = ["token": token, "from": from] as [String: Any]

        guard let request = NetworkHelper.createJSONPostRequest(dst: "clear_notification", dictionary: locationDict) else {
            completion(false)
            return
        }

        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                completion(NetworkHelper.checkResponse(data: data, response: response, error: nil) != nil)
            } catch {
                completion(false)
            }
        }
    }
}

extension AppDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { data -> String in
            return String(format: "%02.2hhx", data)
        }.joined()
        SharedNotificationManager.setToken(token: token)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        SharedNotificationManager.registrationFailed()
        NSLog("APNs registration failed")
    }
}
