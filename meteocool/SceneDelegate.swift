//
//  SceneDelegate.swift
//  meteocool
//

import UIKit

/// Adopts the scene-based life cycle, which the iOS 27 SDK requires.
/// An app built against that SDK that relies on the `UIApplicationDelegate`
/// window callbacks does not launch.
///
/// The window comes from `Main.storyboard` (`UISceneStoryboardFile`).
/// This class forwards the foreground/active hooks that were on `AppDelegate`.
/// UIKit stops calling the `AppDelegate` versions once scenes are adopted.
class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    /// Destroys any additional phone window scene. Only CarPlay gets a second
    /// scene.
    ///
    /// CarPlay forces `UIApplicationSupportsMultipleScenes`. On iPadOS this
    /// also lets the user open a second copy of the phone UI.
    /// The map supports only one instance: `ViewController` stores itself in
    /// the global `viewController`, which settings and gestures use.
    /// A second window would overwrite that global without any error, and
    /// the first window would stop receiving settings and gestures.
    /// Keep this check until the global is removed.
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        let otherWindowScenes = UIApplication.shared.connectedScenes.contains {
            $0 !== scene && $0.session.role == .windowApplication
        }
        if otherWindowScenes {
            UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
        }
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        SharedNotificationManager.clearNotifications()
        SharedNotificationManager.refreshAuthorization()
    }

    func sceneWillResignActive(_ scene: UIScene) {
        viewController?.willResignActive()
        SharedLocationUpdater.willResignActive()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        WebCache.trimIfNeeded()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        SharedLocationUpdater.willEnterForeground()
        viewController?.willEnterForeground()
        viewController?.didBecomeActive()
        // XXX call this only when there are >0 notifications on launch! saves 1 useless request.
        (UIApplication.shared.delegate as? AppDelegate)?.acknowledgeNotification(retry: true, from: "foreground")
    }
}
