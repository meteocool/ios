import Foundation

// Checks AlertMute: when a day, a week and "until the rain is over" end, how
// a rain mute follows newer forecasts, and the stored mute running out.
// Compiled with Shared/AlertMute.swift and Shared/RainForecast.swift alone.

@inline(__always) func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition {
        FileHandle.standardError.write("AlertMuteCheck line \(line): \(message)\n".data(using: .utf8)!)
        exit(1)
    }
}

@main
enum AlertMuteCheck {
    static let start = 1_793_200_000

    /// Five-minute steps from `start`; the first three observed, so "now" is the third.
    static func forecast(_ dbz: [Double]) -> RainForecast {
        RainForecast(start: start, interval: 300, dbz: dbz, observed: 3, threshold: 20)
    }

    static func at(_ step: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(start + step * 300)) }

    static func main() {
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        // Saturday noon before the clocks go back on 25 October 2026.
        let saturday = berlin.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 12))!
        let day = AlertMute.timed(.day, now: saturday, calendar: berlin)
        check(day.until.timeIntervalSince(saturday) == 25 * 3600, "a day across the clock change ends at the same time tomorrow")
        check(berlin.component(.hour, from: day.until) == 12, "a day ends at noon again")
        let week = AlertMute.timed(.week, now: saturday, calendar: berlin)
        check(berlin.dateComponents([.day, .hour], from: saturday, to: week.until) == DateComponents(day: 7, hour: 0),
              "a week ends seven days later at the same time")
        check(day.isActive(at: saturday) && !day.isActive(at: day.until), "a mute ends at its end")

        // Raining now (step 2), dry from step 5: over at step 5.
        let raining = forecast([30, 30, 30, 30, 30, 0, 0, 0, 0, 0])
        let wet = AlertMute.rain(raining)
        check(wet?.length == .rain && wet?.until == at(5), "muted until the rain falling now stops")
        check(wet?.rainBegan == true && wet?.openEnded == false, "the rain is falling and its end is known")

        // Raining to the end of the forecast: until the forecast runs out, which may move.
        let endless = AlertMute.rain(forecast(Array(repeating: 30, count: 10)))
        check(endless?.until == at(10) && endless?.openEnded == true, "rain past the forecast mutes to its end")

        // Dry now, rain from step 4 to 5.
        let coming = forecast([0, 0, 0, 0, 25, 25, 0, 0, 0, 0])
        let next = AlertMute.rain(coming)
        check(next?.until == at(6) && next?.rainBegan == false, "the next rain is muted when none is falling")

        check(AlertMute.rain(forecast(Array(repeating: 0, count: 10))) == nil, "no rain, nothing to mute")
        check(AlertMute.rain(forecast([0, 0, 0, 0, 15, 15, 0, 0, 0, 0])) == nil, "rain under the threshold is not alerted, nor muted")

        // Following the rain.
        check(next?.following(coming) == next, "the same forecast changes nothing")
        check(next?.following(raining)?.rainBegan == true, "the muted rain has begun")
        check(next?.following(raining)?.until == at(5), "its end follows the forecast")
        check(wet?.following(coming) == nil, "rain coming after the muted rain fell is the next one: unmuted")
        check(wet?.following(forecast(Array(repeating: 0, count: 10))) == nil, "dry after the rain: unmuted")
        check(endless?.following(raining)?.until == at(5), "an open end moves to the rain's end once the forecast shows it")
        check(endless?.following(raining)?.openEnded == false, "and is no longer open")
        check(day.following(coming) == day && week.following(raining) == week, "day and week mutes ignore the rain")

        // Stored in the app group.
        let suite = "AlertMuteCheck-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        check(AlertMute.active(in: defaults) == nil, "nothing stored, nothing muted")
        AlertMute.save(day, to: defaults)
        check(AlertMute.active(in: defaults, now: saturday) == day, "a stored mute reads back")
        check(AlertMute.active(in: defaults, now: day.until) == nil, "a stored mute runs out")
        AlertMute.save(nil, to: defaults)
        check(defaults.data(forKey: AlertMute.key) == nil, "unmuting removes it")
        print("AlertMute checks passed")
    }
}
