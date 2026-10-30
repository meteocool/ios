//
//  AlertMute.swift
//  meteocool
//
//  Muted rain alerts, as chosen in Settings: for a day, for a week, or
//  until the rain is over. The backend holds the alerts back: the app sends
//  the mute's end as `pausedUntil` with every `post_location`, which ng
//  treats as quiet hours (no alert, no flag set, rain still due afterwards
//  is alerted then). The notification service extension cannot drop a push
//  without Apple's filtering entitlement, so an alert that still comes while
//  muted (the backend had not heard yet) arrives quietly instead.
//
//  "Until the rain is over" mutes the rain falling now, or else the next one
//  the forecast at the user's location shows, and ends where that rain ends,
//  by the same rules as the alerts (`RainForecast.phase`). The alerts come
//  back for the rain after it. The app follows the rain whenever it runs and
//  moves the end with the forecast; when the forecast runs out before the
//  rain does, the end is the forecast's last step. If the app does not run
//  again before then, the backend alerts again: a mute that lapses early
//  costs an alert, one that lingers could cost the next rain's.
//
//  Shared by the app and NotificationService; the rain rules are in
//  AlertMute+Rain.swift, which the extension does without. `scripts/check.sh`
//  compiles both with Shared/RainForecast.swift and `tests/AlertMuteCheck.swift`.
//

import Foundation

struct AlertMute: Codable, Equatable, Sendable {
    enum Length: String, Codable, CaseIterable, Sendable {
        case day, week, rain
    }

    let length: Length
    /// When the alerts come back: the backend's `pausedUntil`.
    var until: Date
    /// `.rain`: whether the muted rain has been seen falling. Once it has,
    /// a forecast with no rain falling means it is over.
    var rainBegan = false
    /// `.rain`: whether the rain goes on past the forecast, so `until` is
    /// only where the forecast ends.
    var openEnded = false

    /// Muted for a day or a week from `now`, by the calendar: a day across a
    /// clock change is still until the same time tomorrow.
    static func timed(_ length: Length, now: Date, calendar: Calendar = .current) -> AlertMute {
        let component: Calendar.Component = length == .week ? .weekOfYear : .day
        let until = calendar.date(byAdding: component, value: 1, to: now) ?? now.addingTimeInterval(length == .week ? 7 * 86400 : 86400)
        return AlertMute(length: length, until: until)
    }

    func isActive(at now: Date) -> Bool { now < until }

    // MARK: - Stored in the app group

    static let key = "alertMute"

    /// The mute in effect at `now`; nil when there is none or it has run out.
    static func active(in defaults: UserDefaults?, now: Date = Date()) -> AlertMute? {
        guard let data = defaults?.data(forKey: key),
              let mute = try? JSONDecoder().decode(AlertMute.self, from: data),
              mute.isActive(at: now) else { return nil }
        return mute
    }

    static func save(_ mute: AlertMute?, to defaults: UserDefaults?) {
        if let mute, let data = try? JSONEncoder().encode(mute) {
            defaults?.set(data, forKey: key)
        } else {
            defaults?.removeObject(forKey: key)
        }
    }
}
