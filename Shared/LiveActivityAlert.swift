//
//  LiveActivityAlert.swift
//  meteocool
//
//  With Live Activities on, ng starts one in place of the rain notification,
//  with the alert on it, so neither the notification service extension nor
//  the delivered notifications see that alert. This adds it to the past
//  alerts, once per activity, from whichever process sees the activity
//  first: the widget extension as it draws it, which happens for every
//  activity, or the app, which iOS does not always wake for one.
//
//  Shared by the app and RainActivity.
//

import Foundation

enum LiveActivityAlert {
    /// The activities already in the list, so a redraw or a cleared list
    /// does not add them again.
    static let recordedKey = "liveActivityAlertsRecorded"

    /// Adds the activity's alert unless it is there already. Its own words
    /// are not readable here; the activity's headline says the rain as the
    /// alert does. Returns whether it added one.
    @discardableResult
    static func record(_ state: RainForecast, activityID: String, received: Date = Date(),
                       defaults: UserDefaults? = UserDefaults(suiteName: AlertHistory.groupID),
                       file: URL = AlertHistory.file) -> Bool {
        var recorded = defaults?.stringArray(forKey: recordedKey) ?? []
        guard !recorded.contains(activityID) else { return false }
        let words = state.alertText(at: received)
            ?? (NSLocalizedString("live_activity_alert", value: "Rain on the way", comment: "past alert from a Live Activity"), "")
        AlertHistory.add([ReceivedAlert(title: words.title, body: words.body, received: received,
                                        request: ReceivedAlert.liveActivity(activityID))], now: received, to: file)
        recorded.append(activityID)
        defaults?.set(Array(recorded.suffix(50)), forKey: recordedKey)
        return true
    }
}
