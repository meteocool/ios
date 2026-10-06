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
    ///
    /// A link that launched the app arrives here too, before the map exists;
    /// the controller holds it until the page is up.
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        let otherWindowScenes = UIApplication.shared.connectedScenes.contains {
            $0 !== scene && $0.session.role == .windowApplication
        }
        if otherWindowScenes {
            // A link opened in a new window goes to the map already on screen.
            options.userActivities.forEach { open($0, in: viewController) }
            options.urlContexts.forEach { open($0.url, in: viewController) }
            UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
            return
        }
        options.userActivities.forEach { open($0, in: window?.rootViewController as? ViewController) }
        options.urlContexts.forEach { open($0.url, in: window?.rootViewController as? ViewController) }
    }

    /// A tapped widget: its URL is a link to the map at the widget's place,
    /// handed over as a URL rather than a universal link.
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        URLContexts.forEach { open($0.url, in: window?.rootViewController as? ViewController) }
    }

    /// A link opened while the app was running or suspended.
    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        open(userActivity, in: window?.rootViewController as? ViewController)
    }

    /// Opens a shared map link (a universal link on app.meteocool.com) in
    /// the map. Anything else, on another host or page, is ignored.
    private func open(_ activity: NSUserActivity, in map: ViewController?) {
        guard activity.activityType == NSUserActivityTypeBrowsingWeb, let url = activity.webpageURL else { return }
        open(url, in: map)
    }

    private func open(_ url: URL, in map: ViewController?) {
        guard let search = MapLink.search(opening: url) else { return }
        map?.openLink(search: search)
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        SharedNotificationManager.clearNotifications()
        SharedNotificationManager.refreshAuthorization()
    }

    func sceneWillResignActive(_ scene: UIScene) {
        SharedWidgets.leavingForeground()
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
        SharedLiveActivities.refresh(force: true)
        // XXX call this only when there are >0 notifications on launch! saves 1 useless request.
        (UIApplication.shared.delegate as? AppDelegate)?.acknowledgeNotification(retry: true, from: "foreground")
    }
}
