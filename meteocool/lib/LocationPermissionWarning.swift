import CoreLocation
import UIKit
import UserNotifications

/// Tells the user when rain alerts no longer follow them.
///
/// iOS reminds people now and then that an app uses their location in the
/// background and offers "Change to Only While Using". The app is not told,
/// and with While Using its location only moves while it is open: alerts keep
/// going to wherever it was last opened. The app sees it the next time it
/// runs, on opening or woken by the backend's silent `location_check` push
/// (worker-radar sends one to iPhones quiet for a day), and says so once per
/// downgrade: an alert in the app, or a notification when woken.
@MainActor enum LocationPermissionWarning {
    private static let defaults = UserDefaults(suiteName: "group.org.frcy.app.meteocool")
    private static let warnedKey = "locationPermissionWarned"
    private static let notificationID = "location-permission"

    /// Alerts on, but location only while the app is open.
    static var applies: Bool {
        SharedNotificationManager.enabled && SharedLocationUpdater.authorizationStatus == .authorizedWhenInUse
    }

    /// Once per downgrade: back to Always, the next one is told again.
    private static func shouldWarn() -> Bool {
        guard applies else {
            if SharedLocationUpdater.authorizationStatus == .authorizedAlways {
                defaults?.set(false, forKey: warnedKey)
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationID])
            }
            return false
        }
        return defaults?.bool(forKey: warnedKey) != true
    }

    /// On opening: an alert, with the way to Settings.
    static func showIfNeeded(from viewController: UIViewController?) {
        guard let viewController, viewController.presentedViewController == nil, shouldWarn() else { return }
        defaults?.set(true, forKey: warnedKey)
        let alert = UIAlertController(title: NSLocalizedString("location_permission_downgraded_title", comment: ""),
                                      message: NSLocalizedString("location_permission_downgraded_body", comment: ""),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("Change in Settings", comment: ""), style: .default) { _ in
            UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
        })
        alert.addAction(UIAlertAction(title: NSLocalizedString("Dismiss", comment: ""), style: .cancel))
        viewController.present(alert, animated: true)
    }

    /// Woken in the background: a notification of the app's own.
    static func notifyIfNeeded() async {
        guard shouldWarn() else { return }
        defaults?.set(true, forKey: warnedKey)
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("location_permission_downgraded_title", comment: "")
        content.body = NSLocalizedString("location_permission_downgraded_body", comment: "")
        content.sound = .default
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: notificationID, content: content, trigger: nil))
    }

    /// What the location update tells the backend (`location_permission`).
    static var reported: String {
        switch SharedLocationUpdater.authorizationStatus {
        case .authorizedAlways: return "always"
        case .authorizedWhenInUse: return "whenInUse"
        default: return "denied"
        }
    }
}
