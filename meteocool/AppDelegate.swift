import UIKit
import UserNotifications
import CoreMotion

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    let userDefaults = UserDefaults.init(suiteName: "group.org.frcy.app.meteocool")

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
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
        if (userDefaults?.value(forKey: "lightning") == nil){
            userDefaults?.setValue(true, forKey: "lightning")
        }
        if (userDefaults?.value(forKey: "mesocyclones") == nil){
            userDefaults?.setValue(true, forKey: "mesocyclones")
        }
        if (userDefaults?.value(forKey: "snow") == nil){
            userDefaults?.setValue(true, forKey: "snow")
        }
        if (userDefaults?.value(forKey: "radarColorMapping") == nil){
            userDefaults?.setValue("classic", forKey: "radarColorMapping")
        }
        if (userDefaults?.value(forKey: "baseLayer") == nil){
            userDefaults?.setValue("light", forKey: "baseLayer")
        }
        if (userDefaults?.value(forKey: "experimentalFeatures") == nil){
            userDefaults?.setValue(false, forKey: "experimentalFeatures")
        }

        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
        // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
        // Use this method to pause ongoing tasks, disable timers, and invalidate graphics rendering callbacks. Games should use this method to pause the game.
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
        // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // Called as part of the transition from the background to the active state; here you can undo many of the changes made on entering the background.
        SharedNotificationManager.clearNotifications()
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.

        // XXX call this only when there are >0 notifications on launch! saves 1 useless request.
        acknowledgeNotification(retry: true, from: "foreground")
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        if let clear_all = userInfo["clear_all"] as? Bool {
            if (clear_all) {
                SharedNotificationManager.clearNotifications()
                acknowledgeNotification(retry: true, from: "push")

                /*UserDefaults.init(suiteName: "group.org.frcy.app.meteocool")?.removeObject(forKey: "alert")
                UserDefaults.init(suiteName: "group.org.frcy.app.meteocool")?.removeObject(forKey: "message")*/
            }
        }
        completionHandler(.newData)
    }

    func acknowledgeNotification(retry: Bool, from: String) {
        guard let token = SharedNotificationManager.getToken() else {
            //NSLog("acknowledgeNotification: no push token")
            if (retry) {
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(4), execute: {
                    self.acknowledgeNotification(retry: false, from: from)
                })
            }
            return
        }

        let locationDict = ["token": token, "from": from] as [String: Any]

        guard let request = NetworkHelper.createJSONPostRequest(dst: "clear_notification", dictionary: locationDict) else {
            return
        }

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = NetworkHelper.checkResponse(data: data, response: response, error: error) else {
                return
            }

            if let json = ((try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]) as [String : Any]??) {
                if let errorMessage = json?["error"] as? String {
                    NSLog("ERROR: \(errorMessage)")
                }
            }
        }
        task.resume()
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { data -> String in
            return String(format: "%02.2hhx", data)
        }.joined()
        NSLog("Device Token: \(token)")
        SharedNotificationManager.setToken(token: token)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("Failed to register for remote notifications with error: \(error)")
    }
}
