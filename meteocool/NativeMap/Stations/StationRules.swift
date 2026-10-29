//
//  StationRules.swift
//  meteocool
//
//  What DWD's weather stations over the radar map decide, apart from drawing
//  them (core's `lib/stations.ts`, `lib/windBarb.ts`, `lib/stationHistory.ts`):
//  which parameter a choice asks for, which time to ask about, what a value
//  reads as, which stations are left when they crowd, a wind barb's shape,
//  and what a station's history shows.
//
//  No app dependencies here: `scripts/check.sh` compiles this file alone.
//

import Foundation

/// One station as `/stations/observations` answers it: where it is, who it
/// is, and the numbers it reported.
struct ObservedStation: Equatable, Sendable {
    let id: String
    let lat: Double
    let lon: Double
    let name: String
    let state: String
    let elevationM: Double
    let observedAt: String
    /// Every number it reported, by the service's own name (`temperature_c`, …).
    let values: [String: Double]

    /// A JSON number, not a boolean: an `NSNumber` holding 0 or 1 passes for
    /// `Bool`, and 0 mm or 0° are readings.
    static func number(_ value: Any) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    /// The stations of an answer; nil for anything that is not one.
    static func decode(_ data: Data) -> [ObservedStation]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = json["features"] as? [[String: Any]] else { return nil }
        return features.compactMap { feature in
            guard let geometry = feature["geometry"] as? [String: Any],
                  let coordinates = geometry["coordinates"] as? [Double], coordinates.count >= 2,
                  let properties = feature["properties"] as? [String: Any],
                  let station = properties["station"] as? String ?? feature["id"] as? String,
                  let observedAt = properties["observed_at"] as? String else { return nil }
            var values: [String: Double] = [:]
            for (key, value) in properties {
                if let number = ObservedStation.number(value) { values[key] = number }
            }
            values["elevation_m"] = nil
            return ObservedStation(id: station, lat: coordinates[1], lon: coordinates[0], name: properties["name"] as? String ?? station,
                                   state: properties["state"] as? String ?? "", elevationM: properties["elevation_m"] as? Double ?? 0,
                                   observedAt: observedAt, values: values)
        }
    }
}

/// The one parameter the map shows at a time.
enum StationChoice: String, CaseIterable, Sendable {
    case wind, gusts, temperature, precipitation, humidity, pressure
}

enum StationRules {
    static let defaultChoice = StationChoice.wind
    /// How often the stations are asked for again: DWD publishes every ten minutes.
    static let refreshSeconds: TimeInterval = 5 * 60
    /// How old a value may be and still be drawn: DWD publishes 20 to 60
    /// minutes after its ten minutes end, a series at a time.
    static let maxAgeMinutes = 90
    /// How long the timeline rests on a frame before the stations for it are asked for.
    static let scrubDebounce: TimeInterval = 0.4

    /// What a choice asks for, and nothing else.
    static func parameters(_ choice: StationChoice) -> [String] {
        switch choice {
        case .wind: return ["wind_speed_m_s", "wind_direction_deg"]
        case .gusts: return ["gust_m_s", "gust_direction_deg"]
        case .temperature: return ["temperature_c"]
        case .precipitation: return ["precipitation_mm"]
        case .humidity: return ["humidity_pct"]
        case .pressure: return ["pressure_msl_hpa"]
        }
    }

    /// A stored choice, or the default for anything that is not one.
    static func parseChoice(_ value: String?) -> StationChoice {
        value.flatMap(StationChoice.init(rawValue:)) ?? defaultChoice
    }

    /// Whether a choice is drawn as wind barbs rather than a number.
    static func isWind(_ choice: StationChoice) -> Bool { choice == .wind || choice == .gusts }

    /// Greyed: the timeline is on a forecast frame, which no station has
    /// measured. Zero is a timeline with no grid yet.
    static func stale(shown: Int, newest: Int) -> Bool {
        shown > 0 && newest > 0 && shown > newest
    }

    /// The time to ask about, or nil for the newest: an observed frame in
    /// the past is the stations from then; live and forecast, the newest.
    static func at(shown: Int, newest: Int) -> Int? {
        if shown <= 0 || newest <= 0 || shown >= newest { return nil }
        return shown
    }

    /// A station's wind for a barb, in knots and the direction it comes
    /// from, or nil when it reported none.
    static func wind(_ choice: StationChoice, _ station: ObservedStation) -> (knots: Double, fromDeg: Double)? {
        let speed = station.values[choice == .gusts ? "gust_m_s" : "wind_speed_m_s"]
        let from = station.values[choice == .gusts ? "gust_direction_deg" : "wind_direction_deg"]
        guard let speed, let from else { return nil }
        return (WindBarb.toKnots(speed), from)
    }

    /// The number a station shows for a choice drawn as one, or nil.
    static func value(_ choice: StationChoice, _ station: ObservedStation) -> Double? {
        isWind(choice) ? nil : station.values[parameters(choice)[0]]
    }

    /// A number with `digits` decimals as the reader's language writes it,
    /// never grouped (1013,0 hPa, not 1.013,0); -0.04 is 0.0.
    static func formatNumber(_ value: Double, digits: Int, language: String = "en") -> String {
        let scale = pow(10, Double(digits))
        var rounded = (value * scale + 0.5).rounded(.down) / scale
        if rounded == 0 { rounded = 0 }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: language)
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSNumber(value: rounded)) ?? String(rounded)
    }

    /// A value as the map writes it: whole percent for humidity, one decimal for the rest.
    static func formatValue(_ choice: StationChoice, _ value: Double, language: String = "en") -> String {
        formatNumber(value, digits: choice == .humidity ? 0 : 1, language: language)
    }

    /// The colour a temperature is written in, by band, as RGB hex.
    static func temperatureColour(_ celsius: Double) -> UInt32 {
        if celsius < -10 { return 0xC4B5FD }
        if celsius < 0 { return 0x7DD3FC }
        if celsius < 10 { return 0x86EFAC }
        if celsius < 20 { return 0xFDE047 }
        if celsius < 30 { return 0xFDBA74 }
        return 0xFCA5A5
    }

    /// The reflectivity ten minutes' rain would show, so a gauge is coloured
    /// in the radar's palette (Marshall-Palmer); nil for none and a trace.
    static func precipitationDbz(_ millimetres: Double) -> Double? {
        guard millimetres >= 0.05 else { return nil }
        let rate = millimetres * 6
        return 10 * log10(200 * pow(rate, 1.6))
    }

    /// How big a screen cell holds one station, in points: none from zoom 8 in.
    static func thinningCell(_ zoom: Double) -> Double { zoom >= 8 ? 0 : 44 }

    /// A station where it lands, in world points at the zoom, and how much
    /// it matters among its neighbours (a gauge with rain over a dry one).
    struct Placed: Equatable {
        let id: String
        let x: Double
        let y: Double
        let rank: Double
    }

    /// The stations left when thinned to one per `cell` points: the highest
    /// ranked in each cell, among equals the one nearest its middle.
    static func thinToGrid(_ stations: [Placed], cell: Double) -> Set<String> {
        guard cell > 0 else { return Set(stations.map(\.id)) }
        var best: [String: (station: Placed, offset: Double)] = [:]
        for station in stations {
            let column = (station.x / cell).rounded(.down), row = (station.y / cell).rounded(.down)
            let offset = hypot(station.x - (column + 0.5) * cell, station.y - (row + 0.5) * cell)
            let key = "\(Int(column)):\(Int(row))"
            if let held = best[key], !(station.rank > held.station.rank || (station.rank == held.station.rank && offset < held.offset)) { continue }
            best[key] = (station, offset)
        }
        return Set(best.values.map(\.station.id))
    }
}

/// A wind barb, the meteorological way, as shapes in points (core's
/// `windBarb.ts`): the station at the origin, y down; the shaft towards where
/// the wind comes from, feathers at its far end on its right (the Northern
/// Hemisphere's side). A pennant is 50 kt, a full feather 10, a half 5, after
/// rounding to the nearest 5 kt; below 2.5 kt it is calm, an open circle.
enum WindBarb {
    typealias Point = (x: Double, y: Double)

    enum Shape {
        case calm(radius: Double)
        case barb(knots: Double, shaft: (Point, Point), feathers: [(Point, Point)], pennants: [(Point, Point, Point)])
    }

    static let knotsPerMs = 1.943844
    static let shaft = 26.0, feather = 12.0, step = 4.5, pennant = 6.0, calm = 5.0
    /// How far a feather's tip leans towards the shaft's end, as a share of its length.
    static let lean = 0.45

    static func toKnots(_ metresPerSecond: Double) -> Double { metresPerSecond * knotsPerMs }

    /// The speed a barb is drawn for: the nearest 5 kt.
    static func roundKnots(_ knots: Double) -> Double { max(0, ((knots / 5) + 0.5).rounded(.down) * 5) }

    static func shape(knots: Double, fromDeg: Double) -> Shape {
        let rounded = roundKnots(knots)
        if rounded < 2.5 { return .calm(radius: calm) }
        let pennants = Int(rounded / 50)
        let fulls = Int(rounded.truncatingRemainder(dividingBy: 50) / 10)
        let half = rounded.truncatingRemainder(dividingBy: 10) >= 5
        let theta = fromDeg * .pi / 180
        let along: Point = (sin(theta), -cos(theta))
        let right: Point = (-along.y, along.x)
        // Where each mark starts, in from the far end; a lone half one step in.
        var cursor = pennants == 0 && fulls == 0 ? step : 0
        var pennantAt: [Double] = []
        for _ in 0 ..< pennants { pennantAt.append(cursor); cursor += pennant }
        if pennants > 0 && (fulls > 0 || half) { cursor += step / 2 }
        var featherAt: [(from: Double, length: Double)] = []
        for _ in 0 ..< fulls { featherAt.append((cursor, feather)); cursor += step }
        if half { featherAt.append((cursor, feather / 2)); cursor += step }
        let length = max(shaft, cursor + step * 2)
        func on(_ inFromEnd: Double) -> Point { (along.x * (length - inFromEnd), along.y * (length - inFromEnd)) }
        func out(_ from: Point, _ sideways: Double, _ outwards: Double) -> Point {
            (from.x + right.x * sideways + along.x * outwards, from.y + right.y * sideways + along.y * outwards)
        }
        return .barb(knots: rounded, shaft: ((0, 0), on(0)),
                     feathers: featherAt.map { (on($0.from), out(on($0.from), $0.length, $0.length * lean)) },
                     pennants: pennantAt.map { (on($0), on($0 + pennant), out(on($0), feather, 0)) })
    }
}

// MARK: - History

/// One ten-minute row of a station's history.
struct ObservationRow: Equatable, Sendable {
    let t: Double
    let values: [String: Double]

    /// `/stations/{station}/observations`' rows, oldest first.
    static func decode(_ data: Data) -> [ObservationRow]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let rows = (json as? [[String: Any]]) ?? ((json as? [String: Any])?["observations"] as? [[String: Any]])
            ?? ((json as? [String: Any])?["rows"] as? [[String: Any]])
        guard let rows else { return nil }
        return rows.compactMap { row in
            guard let at = row["observed_at"] as? String, let t = StationHistory.seconds(at) else { return nil }
            var values: [String: Double] = [:]
            for (key, value) in row { if let number = ObservedStation.number(value) { values[key] = number } }
            return ObservationRow(t: t * 1000, values: values)
        }
        .sorted { $0.t < $1.t }
    }
}

/// What a station measured over the last day, three or seven (core's
/// `stationHistory.ts`): small multiples over one clock.
enum StationHistory {
    enum Window: String, CaseIterable, Sendable {
        case day, threeDays = "three_days", week
        var hours: Double { self == .day ? 24 : self == .threeDays ? 72 : 168 }
    }

    /// A row further from the one before than this has a gap before it.
    static let maxGapMs = 40 * 60_000.0

    struct Point: Equatable { let t: Double; let v: Double? }

    enum Style: String { case main, context, bars, dots }

    struct Series: Equatable {
        let key: String
        let style: Style
        let points: [Point]
    }

    struct Stat: Equatable {
        let key: String
        let value: Double
    }

    struct Panel: Equatable {
        let key: String
        let unit: String
        let digits: Int
        let series: [Series]
        let stats: [Stat]
        /// A range the scale is fixed to, with its ticks.
        var fixed: (min: Double, max: Double, ticks: [Double])?
        /// The bottom kept at zero and the top at least this.
        var floor: Double?

        static func == (a: Panel, b: Panel) -> Bool {
            a.key == b.key && a.series == b.series && a.stats == b.stats && a.floor == b.floor
                && a.fixed?.min == b.fixed?.min && a.fixed?.max == b.fixed?.max && a.fixed?.ticks == b.fixed?.ticks
        }
    }

    static func windowStart(_ window: Window, now: Double) -> Double { now - window.hours * 3_600_000 }

    static func seconds(_ iso: String) -> Double? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: iso) { return date.timeIntervalSince1970 }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: iso)?.timeIntervalSince1970
    }

    private static func points(_ rows: [ObservationRow], _ key: String) -> [Point] { rows.map { Point(t: $0.t, v: $0.values[key]) } }
    private static func values(_ points: [Point]) -> [Double] { points.compactMap(\.v) }
    private static func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(values.count) }
    private static func stat(_ key: String, _ value: Double?) -> [Stat] { value.map { [Stat(key: key, value: $0)] } ?? [] }

    /// The panels a station's rows fill, in the order they are stacked.
    static func panels(_ rows: [ObservationRow]) -> [Panel] {
        guard !rows.isEmpty else { return [] }
        var panels: [Panel] = []
        let temperature = points(rows, "temperature_c")
        let temperatures = values(temperature)
        if !temperatures.isEmpty {
            let maxes = values(points(rows, "temperature_max_c")), mins = values(points(rows, "temperature_min_c"))
            panels.append(Panel(key: "temperature", unit: "°C", digits: 1, series: [
                Series(key: "dew_point", style: .context, points: points(rows, "dew_point_c")),
                Series(key: "temperature", style: .main, points: temperature),
            ], stats: stat("max", (maxes.isEmpty ? temperatures : maxes).max()) + stat("min", (mins.isEmpty ? temperatures : mins).min())
                + stat("mean", mean(temperatures))))
        }
        let rain = points(rows, "precipitation_mm")
        if !values(rain).isEmpty {
            panels.append(Panel(key: "precipitation", unit: "mm", digits: 1, series: [Series(key: "precipitation", style: .bars, points: rain)],
                                stats: stat("total", values(rain).reduce(0, +)), floor: 0.5))
        }
        let sunshine = points(rows, "sunshine_minutes")
        if !values(sunshine).isEmpty {
            panels.append(Panel(key: "sunshine", unit: "min", digits: 0, series: [Series(key: "sunshine", style: .bars, points: sunshine)],
                                stats: stat("total", values(sunshine).reduce(0, +) / 60), fixed: (0, 10, [0, 5, 10])))
        }
        let humidity = points(rows, "humidity_pct")
        let humidities = values(humidity)
        if !humidities.isEmpty {
            panels.append(Panel(key: "humidity", unit: "%", digits: 0, series: [Series(key: "humidity", style: .main, points: humidity)],
                                stats: stat("max", humidities.max()) + stat("min", humidities.min()), fixed: (0, 100, [0, 50, 100])))
        }
        let pressure = points(rows, "pressure_msl_hpa")
        let pressures = values(pressure)
        if !pressures.isEmpty {
            panels.append(Panel(key: "pressure", unit: "hPa", digits: 1, series: [Series(key: "pressure", style: .main, points: pressure)],
                                stats: stat("max", pressures.max()) + stat("min", pressures.min())
                                    + stat("change", pressures.count > 1 ? pressures[pressures.count - 1] - pressures[0] : nil)))
        }
        let wind = points(rows, "wind_speed_m_s"), gusts = points(rows, "gust_m_s")
        if !values(wind).isEmpty || !values(gusts).isEmpty {
            panels.append(Panel(key: "wind", unit: "m/s", digits: 1, series: [
                Series(key: "gusts", style: .context, points: gusts),
                Series(key: "wind", style: .main, points: wind),
            ], stats: stat("gust", values(gusts).max()) + stat("mean", values(wind).isEmpty ? nil : mean(values(wind))), floor: 2))
        }
        let direction = points(rows, "wind_direction_deg")
        if !values(direction).isEmpty {
            panels.append(Panel(key: "direction", unit: "°", digits: 0, series: [Series(key: "direction", style: .dots, points: direction)],
                                stats: [], fixed: (0, 360, [0, 90, 180, 270, 360])))
        }
        return panels
    }

    /// A series split where rows are missing, so no line crosses values
    /// nobody measured.
    static func runs(_ points: [Point]) -> [[Point]] {
        var runs: [[Point]] = []
        var current: [Point] = []
        var last: Double?
        for point in points {
            guard point.v != nil else { if !current.isEmpty { runs.append(current); current = [] }; last = nil; continue }
            if let last, point.t - last > maxGapMs, !current.isEmpty { runs.append(current); current = [] }
            current.append(point)
            last = point.t
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// The compass point a direction tick is written as.
    static let directionTicks: [Double: String] = [0: "N", 90: "E", 180: "S", 270: "W", 360: "N"]
}
