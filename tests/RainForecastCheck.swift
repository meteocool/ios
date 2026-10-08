import Foundation

/// Checks the Live Activity's reading of the bar chart: decoding
/// `/v3/radar/timeseries` and the backend's `content-state`, and when rain
/// starts and ends (the rain alerts' rule: from the threshold, until two steps in a row
/// below min(threshold, 14 dBZ)).
@main
struct RainForecastCheck {
    static func forecast(_ dbz: [Double?], observed: Int, threshold: Double = 20) -> RainForecast {
        RainForecast(start: 1_000_000_200, interval: 300, dbz: dbz, observed: observed, threshold: threshold)
    }

    static func main() {
        // Dry ahead.
        precondition(forecast([0, 0, 5, 0, 0, nil], observed: 2).phase == .dry)
        // Arrives two steps after now, lasts three steps.
        let approaching = forecast([0, 0, 10, 25, 30, 22, 8, 3, 0], observed: 2)
        precondition(approaching.phase == .approaching(arrival: approaching.date(at: 3), end: approaching.date(at: 6)),
                     "\(approaching.phase)")
        // Raining now above the threshold, without an end in the forecast.
        let raining = forecast([0, 30, 35, 28, 26], observed: 2)
        precondition(raining.phase == .raining(end: nil), "\(raining.phase)")
        // Light rain after heavy rain is still the same spell, and one dry
        // step in the middle does not end it.
        let tail = forecast([40, 16, 15, 3, 15, 2, 1, 0], observed: 3)
        precondition(tail.phase == .raining(end: tail.date(at: 5)), "\(tail.phase)")
        // The headline names the rain now; the downpour in an hour is its peak.
        let downpour = forecast([0, 28, 28, 30, 33, 45, 38, 20, 0, 0], observed: 2)
        precondition(downpour.headlineDBZ == 28 && downpour.spellPeak?.dbz == 45 && downpour.spellPeak?.at == downpour.date(at: 5))
        precondition(approaching.headlineDBZ == 25 && approaching.spellPeak?.dbz == 30)
        // Light rain that never reached the threshold is not rain to the user.
        precondition(forecast([16, 16, 16, 16], observed: 2).phase == .dry)
        // Trimming keeps the latest observation and moves the start.
        let trimmed = forecast(Array(repeating: 0, count: 49), observed: 25).trimmed(past: 6)
        precondition(trimmed.observed == 7 && trimmed.dbz.count == 31 && trimmed.start == 1_000_000_200 + 18 * 300)
        precondition(RainForecast.band(dbz: 3) == 0 && RainForecast.band(dbz: 27) == 2 && RainForecast.band(dbz: 41) == 4 && RainForecast.band(dbz: 60) == 6)
        precondition(RadarPalette.colour(dbz: 0, palette: "classic") != nil && RadarPalette.colour(dbz: -20, palette: "classic") == nil)

        // The API's shape: unix-second keys, nulls for unpublished steps,
        // dry steps at the scale floor.
        let timeseries = """
        {"server_time": 1000001000, "frames": {
          "1000000200": {"dbz": -32.5, "source": "observation", "tile_id": "x", "processed_time": 1, "filename": "a"},
          "1000000500": {"dbz": 21.26, "source": "observation", "tile_id": "x", "processed_time": 1, "filename": "a"},
          "1000000800": {"dbz": 33.0, "source": "nowcast_phys", "tile_id": "x", "processed_time": 1, "filename": "a"},
          "1000001100": null}}
        """
        guard let decoded = RainForecast.fromTimeseries(Data(timeseries.utf8), threshold: 20) else { preconditionFailure("timeseries") }
        precondition(decoded.start == 1_000_000_200 && decoded.interval == 300 && decoded.observed == 2)
        precondition(decoded.dbz == [-32.5, 21.5, 33, nil] && decoded.value(at: 0) == 0)
        precondition(decoded.phase == .raining(end: nil))
        precondition(RainForecast.fromTimeseries(Data("{\"frames\": {}}".utf8), threshold: 20) == nil)

        // What the backend sends as `content-state`: optional fields left out.
        let pushed = #"{"start": 1000000200, "interval": 300, "dbz": [0, null, 30.5], "observed": 1, "threshold": 26, "radar": "https://api-next.meteocool.com/v3/preview/og.png?latLonZ=48.1,11.6,9.5&aspectRatio=square&logo=false"}"#
        guard let state = try? JSONDecoder().decode(RainForecast.self, from: Data(pushed.utf8)) else { preconditionFailure("content-state") }
        precondition(state.dbz == [0, nil, 30.5] && state.radarSaved == nil && state.phase == .approaching(arrival: state.date(at: 2), end: nil))
        print("Live Activity forecast checks passed")
    }
}
