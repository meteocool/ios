//
//  SceneDelegate.swift
//  meteocool
//

import UIKit

/// The scene-based life cycle, which the iOS 26 SDK requires: an app built
/// against it that still relies on the old `UIApplicationDelegate` window
/// callbacks refuses to launch at all.
///
/// The window itself still comes from `Main.storyboard` (`UISceneStoryboardFile`),
/// so this only has to forward the foreground/active hooks that used to live on
/// `AppDelegate` and stop being called once scenes are adopted.
class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    /// CarPlay forces `UIApplicationSupportsMultipleScenes`, which on iPadOS
    /// also lets the user drag out a second copy of the phone UI. The map is
    /// effectively a singleton — `ViewController` publishes itself into the
    /// global `viewController`, which settings and gestures then talk to — so
    /// a second window would quietly take over the first one's wiring. Until
    /// that is untangled, only the car gets a second scene.
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        let otherWindowScenes = UIApplication.shared.connectedScenes.contains {
            $0 !== scene && $0 is UIWindowScene
        }
        if otherWindowScenes {
            UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
        }
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        SharedNotificationManager.clearNotifications()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        // XXX call this only when there are >0 notifications on launch! saves 1 useless request.
        (UIApplication.shared.delegate as? AppDelegate)?.acknowledgeNotification(retry: true, from: "foreground")
    }
}
