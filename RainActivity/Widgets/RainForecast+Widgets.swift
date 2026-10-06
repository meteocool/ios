import Foundation

/// What the widgets read from a forecast beyond what the Live Activity does.
///
/// No app dependencies here: `scripts/check.sh` compiles this file with
/// `Shared/RainForecast.swift` alone.
extension RainForecast {
    /// The same forecast with now at `date`: steps that have begun since it
    /// was fetched count as past. Never before the forecast's own now.
    func advanced(to date: Date) -> RainForecast {
        guard interval > 0 else { return self }
        let index = Int(floor((date.timeIntervalSince1970 - TimeInterval(start)) / TimeInterval(interval)))
        var moved = self
        moved.observed = min(max(observed, index), dbz.count)
        return moved
    }

    /// The last step before now and at most `past` more before it, as
    /// `trimmed(past:)` keeps them, and at most `ahead` steps from now on.
    func window(past: Int, ahead: Int) -> RainForecast {
        var window = trimmed(past: past)
        window.dbz = Array(window.dbz.prefix(window.observed + ahead))
        return window
    }

    /// When the forecast runs out.
    var end: Date { date(at: dbz.count) }

    /// Minutes of rain at or above the threshold in the next `steps` steps.
    func rainMinutes(ahead steps: Int) -> Int {
        let range = observed..<min(observed + steps, dbz.count)
        return range.filter { value(at: $0) >= threshold }.count * interval / 60
    }

    /// A made-up shower arriving in 20 minutes, for the widget gallery.
    static func sample(now: Date = Date(), threshold: Double = RainForecast.thresholds[1]) -> RainForecast {
        let interval = 300
        let start = Int(now.timeIntervalSince1970) / interval * interval - 24 * interval
        let shower: [Double?] = [0, 0, 0, 0, 12, 22, 29, 34, 38, 33, 27, 24, 30, 26, 18, 10, 0, 0, 0, 0, 0, 0, 0, 0]
        let past: [Double?] = Array(repeating: 0, count: 14) + [8, 16, 21, 15, 6] + Array(repeating: 0, count: 5)
        return RainForecast(start: start, interval: interval, dbz: past + shower, observed: 24, threshold: threshold)
    }
}
