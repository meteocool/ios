import Foundation

// Checks AlertHistory: merging alerts as they come in twice, updates that
// replace their thread, the two-week window and the limit, the days and the
// unseen count. Compiled with Shared/AlertHistory.swift alone.

@inline(__always) func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition {
        FileHandle.standardError.write("AlertHistoryCheck line \(line): \(message)\n".data(using: .utf8)!)
        exit(1)
    }
}

@main
enum AlertHistoryCheck {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_793_200_000)
        let first = ReceivedAlert(title: "Rain in 15 min!", body: "Light rain for about 30 min.", received: now.addingTimeInterval(-3600),
                                  request: "r1", thread: "location")
        let again = ReceivedAlert(title: "Rain in 15 min!", body: "Light rain for about 30 min.", received: now.addingTimeInterval(-3590),
                                  request: "delivered-1", thread: "location")
        check(first.isSame(as: again), "the same alert seen by the extension and among the delivered ones")
        check(!first.isSame(as: ReceivedAlert(title: "Rain in 15 min!", body: "Light rain for about 30 min.",
                                               received: now, request: "r9")), "the same words an hour later are a new alert")

        var alerts = AlertHistory.merged([], adding: [first], now: now)
        alerts = AlertHistory.merged(alerts, adding: [again], now: now)
        check(alerts.count == 1, "a second sighting adds nothing")

        let update = ReceivedAlert(title: "Rain in 10 min", body: "Light rain for about 30 min.", received: now.addingTimeInterval(-3300),
                                   request: "r2", thread: "location", replaces: true)
        alerts = AlertHistory.merged(alerts, adding: [update], now: now)
        check(alerts.count == 1 && alerts[0].title == "Rain in 10 min", "an update takes its thread's place")

        let cabin = ReceivedAlert(title: "Rain at Cabin", body: "", received: now.addingTimeInterval(-600), place: "cabin", request: "r3", thread: "cabin")
        let old = ReceivedAlert(title: "Old", body: "", received: now.addingTimeInterval(-15 * 24 * 3600), request: "r0")
        alerts = AlertHistory.merged(alerts, adding: [cabin, old], now: now)
        check(alerts.map(\.request) == ["r3", "r2"], "newest first, two weeks kept: \(alerts.map(\.request))")

        let many = (0 ..< 250).map { i in
            ReceivedAlert(title: "Alert \(i)", body: "", received: now.addingTimeInterval(Double(-i * 60)), request: "m\(i)")
        }
        check(AlertHistory.merged([], adding: many, now: now).count == AlertHistory.limit, "at most 200 are kept")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let days = AlertHistory.days(alerts + [ReceivedAlert(title: "Yesterday", body: "", received: now.addingTimeInterval(-30 * 3600), request: "y")],
                                     calendar: calendar)
        check(days.count == 2 && days[0].alerts.count == 2 && days[1].alerts[0].request == "y", "grouped by day, newest first")

        check(AlertHistory.unseen(alerts, since: nil) == 2, "never looked: every alert is new")
        check(AlertHistory.unseen(alerts, since: now.addingTimeInterval(-1800)) == 1, "one since the last look")

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("alerts-\(UUID().uuidString).json")
        AlertHistory.add([first], now: now, to: file)
        AlertHistory.add([again, cabin], now: now, to: file)
        check(AlertHistory.load(from: file).map(\.request) == ["r3", "r1"], "the file round-trips")
        AlertHistory.clear(file)
        check(AlertHistory.load(from: file).isEmpty, "cleared")
        print("AlertHistoryCheck passed")
    }
}
