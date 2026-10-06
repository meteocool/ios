import CoreLocation
import WidgetKit

@MainActor let SharedWidgets = WidgetRefresher()

/// Tells WidgetKit when the widgets show something out of date: the user's
/// location moved, or a setting they draw with changed (Mode, the Intensity
/// Threshold, the palette, the details switch). Settings are compared as
/// the app leaves the foreground, so one visit to Settings is one reload.
///
/// Reloads the app asks for while it is in the foreground cost the widgets
/// nothing; in the background they come out of the same daily budget as the
/// widgets' own, so a move reloads them at most every `minimumInterval`.
@MainActor final class WidgetRefresher {
    /// A move shorter than this keeps the widgets' rain: the forecast is
    /// for a radar pixel of about a kilometre.
    static let minimumDistance: CLLocationDistance = 1500
    static let minimumInterval: TimeInterval = 15 * 60

    private var reloadedAt: CLLocation?
    private var reloaded: Date?

    /// Called with every new location fix.
    func moved(to location: CLLocation) {
        if let reloadedAt, location.distance(from: reloadedAt) < Self.minimumDistance { return }
        if let reloaded, Date().timeIntervalSince(reloaded) < Self.minimumInterval, reloadedAt != nil { return }
        reloadedAt = location
        reload()
    }

    /// Called as the app leaves the foreground: reloads the widgets if a
    /// setting they read changed since they were last reloaded.
    func leavingForeground() {
        let settings = Self.settings
        guard settings != UserDefaults(suiteName: "group.org.frcy.app.meteocool")?.string(forKey: "widgetSettings") else { return }
        reload()
    }

    private func reload() {
        reloaded = Date()
        UserDefaults(suiteName: "group.org.frcy.app.meteocool")?.set(Self.settings, forKey: "widgetSettings")
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// The settings the widgets read, as one string to compare.
    private static var settings: String {
        let defaults = UserDefaults(suiteName: "group.org.frcy.app.meteocool")
        return ["environment", "intensityValue", "radarColorMapping", "withDBZ"]
            .map { "\(defaults?.object(forKey: $0) ?? "")" }.joined(separator: "|")
    }
}
