import Foundation

/// "Until the rain is over": see AlertMute.swift. Not in the notification
/// service extension, which only reads the mute.
extension AlertMute {
    /// Muted until the rain in `forecast` is over: the one falling now, or the
    /// next one coming. Nil when the forecast shows no rain to mute.
    static func rain(_ forecast: RainForecast) -> AlertMute? {
        // Where the forecast runs out.
        let last = forecast.date(at: forecast.dbz.count)
        switch forecast.phase {
        case .dry:
            return nil
        case .raining(let end):
            return AlertMute(length: .rain, until: end ?? last, rainBegan: true, openEnded: end == nil)
        case .approaching(_, let end):
            return AlertMute(length: .rain, until: end ?? last, openEnded: end == nil)
        }
    }

    /// The mute after a newer forecast: a rain mute's end moves with the
    /// rain's. Nil once the muted rain is over: it fell and has stopped, or
    /// the forecast no longer shows it. Day and week mutes do not change.
    func following(_ forecast: RainForecast) -> AlertMute? {
        guard length == .rain else { return self }
        switch forecast.phase {
        case .dry:
            return nil
        case .raining:
            return Self.rain(forecast)
        case .approaching:
            // Rain coming after the muted rain fell is the next one.
            return rainBegan ? nil : Self.rain(forecast)
        }
    }
}
