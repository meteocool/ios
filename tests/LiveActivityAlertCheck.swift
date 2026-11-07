import Foundation

// Checks LiveActivityAlert: one past alert per activity, whether the widget
// extension or the app sees it first, and none again once the list is cleared.

@main
enum LiveActivityAlertCheck {
    static func main() {
        let suite = "LiveActivityAlertCheck-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("alerts-\(UUID().uuidString).json")
        defer { AlertHistory.clear(file) }
        let came = Date(timeIntervalSince1970: 1_000_000_200)
        var state = RainForecast(start: 1_000_000_200, interval: 300, dbz: [0, 30], observed: 1, threshold: 20)
        state.headline = .init(title: "Heavy rain {in:arrival}", detail: nil, times: ["arrival": 1_000_000_200 + 15 * 60])

        precondition(LiveActivityAlert.record(state, activityID: "A1", received: came, defaults: defaults, file: file))
        precondition(!LiveActivityAlert.record(state, activityID: "A1", received: came.addingTimeInterval(60), defaults: defaults, file: file),
                     "a redraw or the app seeing it later adds nothing")
        let alerts = AlertHistory.load(from: file)
        precondition(alerts.count == 1 && alerts[0].title.hasPrefix("Heavy rain in 15") && alerts[0].received == came, "\(alerts)")

        AlertHistory.clear(file)
        precondition(!LiveActivityAlert.record(state, activityID: "A1", received: came, defaults: defaults, file: file)
                     && AlertHistory.load(from: file).isEmpty, "a cleared list stays clear")
        precondition(LiveActivityAlert.record(RainForecast(start: 1_000_000_200, interval: 300, dbz: [0], observed: 1, threshold: 20),
                                              activityID: "A2", received: came, defaults: defaults, file: file)
                     && AlertHistory.load(from: file).first?.title == "Rain on the way", "no headline: the plain words")
        print("LiveActivityAlertCheck passed")
    }
}
