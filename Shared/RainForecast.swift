import Foundation

/// The rain at the user's location, as the Live Activity shows it: one
/// reflectivity per time step, the bar chart under the web map in short.
///
/// This is the Live Activity's `ContentState`, so it is also what the backend
/// sends in `content-state` when it starts or updates the activity over APNs
/// Keep the field names stable: a push that no
/// longer decodes is dropped by iOS without a word. The payload is at most
/// 4 KB, and 49 steps take about 300 bytes.
///
/// No app dependencies here: `scripts/check.sh` compiles this file alone.
struct RainForecast: Codable, Hashable, Sendable {
    /// Unix seconds of `dbz[0]`.
    var start: Int
    /// Seconds between steps; 300 everywhere today.
    var interval: Int
    /// dBZ at the location per step, as `/v3/radar/timeseries` reports it.
    /// `nil` is a step with no data yet; 0 or less is dry.
    var dbz: [Double?]
    /// How many leading steps are observations. The rest are forecast, and
    /// "now" is the end of the last observed step.
    var observed: Int
    /// The dBZ the user asked to be alerted for (the Intensity Threshold
    /// setting). Rain starts at it and ends below `min(threshold, 14)`,
    /// as in the server's rain alerts.
    var threshold: Double
    /// The radar image to show, a PNG. The activity cannot download it itself:
    /// the app does whenever it runs, and the view shows the last one it saved.
    var radar: String?
    /// When the app last saved a radar image. Set only by the app; changing it
    /// is what makes iOS draw the activity again with the new image.
    var radarSaved: Int?

    /// Below this, rain that has started counts as over (as in the rain alerts).
    static let rainDBZ = 14.0
    /// Steps in a row below `rainDBZ` that end a spell.
    static let dryStepsToEnd = 2
    /// The Intensity Threshold setting's values, in dBZ (drizzle to hail).
    static let thresholds: [Double] = [14, 20, 26, 36, 41]

    var nowIndex: Int { max(min(observed, dbz.count) - 1, 0) }
    var now: Date { date(at: observed > 0 ? observed : 0) }

    func date(at index: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(start + index * interval))
    }

    /// The step's reflectivity, 0 when dry or unknown.
    func value(at index: Int) -> Double {
        guard dbz.indices.contains(index), let value = dbz[index], value.isFinite else { return 0 }
        return max(value, 0)
    }

    enum Phase: Equatable {
        /// Rain at or above the threshold arrives at `arrival`.
        case approaching(arrival: Date, end: Date?)
        /// It is raining now; `end` is nil when the forecast runs out first.
        case raining(end: Date?)
        /// Nothing ahead: the activity should end.
        case dry
    }

    var phase: Phase {
        let endBelow = min(threshold, Self.rainDBZ)
        let from = nowIndex
        guard from < dbz.count else { return .dry }
        let raining = value(at: from) >= endBelow && (value(at: from) >= threshold || spellBegan(before: from))
        let arrival = raining ? from : (from..<dbz.count).first { value(at: $0) >= threshold }
        guard let arrival else { return .dry }
        var dry = 0
        var end: Date?
        for index in arrival..<dbz.count {
            dry = value(at: index) < endBelow ? dry + 1 : 0
            if dry == Self.dryStepsToEnd {
                end = date(at: index - 1)
                break
            }
        }
        return raining ? .raining(end: end) : .approaching(arrival: date(at: arrival), end: end)
    }

    /// Whether an observed spell that reached the threshold is still going
    /// at `index`: light rain after heavy rain is still the same rain.
    private func spellBegan(before index: Int) -> Bool {
        var dry = 0
        for step in stride(from: index, through: 0, by: -1) {
            if value(at: step) >= threshold { return true }
            dry = value(at: step) < min(threshold, Self.rainDBZ) ? dry + 1 : 0
            if dry == Self.dryStepsToEnd { return false }
        }
        return false
    }

    /// The heaviest step from now on.
    var peak: Double {
        (nowIndex..<max(dbz.count, nowIndex)).map(value(at:)).max() ?? 0
    }

    /// Index into the Intensity Threshold setting's names: drizzle, light
    /// rain, rain, intense rain, hail.
    static func intensity(dbz: Double) -> Int {
        thresholds.lastIndex { dbz >= $0 } ?? 0
    }

    /// The forecast from `/v3/radar/timeseries`: `frames` keyed by unix
    /// seconds, each with `dbz` and `source` ("observation" or a forecast).
    static func fromTimeseries(_ data: Data, threshold: Double) -> RainForecast? {
        struct Response: Decodable {
            struct Frame: Decodable {
                let dbz: Double?
                let source: String?
            }
            let frames: [String: Frame?]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        let steps = response.frames.compactMap { key, frame in Int(key).map { ($0, frame) } }.sorted { $0.0 < $1.0 }
        guard steps.count >= 2 else { return nil }
        let interval = steps[1].0 - steps[0].0
        guard interval > 0, zip(steps, steps.dropFirst()).allSatisfy({ $1.0 - $0.0 == interval }) else { return nil }
        let observed = (steps.lastIndex { $0.1?.source == "observation" } ?? -1) + 1
        return RainForecast(start: steps[0].0, interval: interval,
                            dbz: steps.map { $0.1?.dbz.map { ($0 * 2).rounded() / 2 } },
                            observed: observed, threshold: threshold)
    }

    /// The same forecast without past steps older than `past` steps before now,
    /// the part of the chart the activity has room for.
    func trimmed(past: Int) -> RainForecast {
        let drop = max(observed - 1 - past, 0)
        guard drop > 0 else { return self }
        var trimmed = self
        trimmed.start += drop * interval
        trimmed.dbz = Array(dbz.dropFirst(drop))
        trimmed.observed -= drop
        return trimmed
    }
}

/// The web map's palettes, the same lookup as core's `dbz2color`.
enum RadarPalette {
    /// RGB, 0-1, of a reflectivity; nil below the palette's first entry.
    static func colour(dbz: Double, palette: String) -> (red: Double, green: Double, blue: Double)? {
        guard let table = ColormapTables.tables[palette] ?? ColormapTables.tables["classic"] else { return nil }
        let index = Int(((dbz + 32.5) * 2).rounded(.toNearestOrAwayFromZero))
        guard index >= table.leftPad, !table.rgba.isEmpty else { return nil }
        let packed = table.rgba[min(index - table.leftPad, table.rgba.count - 1)]
        return (Double(packed >> 24) / 255, Double((packed >> 16) & 0xFF) / 255, Double((packed >> 8) & 0xFF) / 255)
    }
}
