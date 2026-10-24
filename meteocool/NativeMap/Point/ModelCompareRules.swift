//
//  ModelCompareRules.swift
//  meteocool
//
//  The weather models compared, as core compares them: the registry, the
//  consensus, Open-Meteo's answers, the spread's maths and the dry-weather
//  strip's title (core's `lib/compare/*`, from Flowm/meteocompare).
//
//  No app dependencies here: `scripts/check.sh` compiles this file alone.
//

import Foundation

// MARK: - Models

/// The 21 models (core's `lib/compare/models.ts`). Order matters: it is the
/// `models=` order, and units are read from the first model's column.
enum CompareModels {
    enum Kind: Sendable { case global, regionalCam, regionalMid, ai, ensembleMean }

    struct Model: Sendable {
        let id: String
        let label: String
        let kind: Kind
        /// Beyond this lead time Open-Meteo may answer with a fallback, or nothing.
        let maxLeadHours: Int
    }

    static let all: [Model] = [
        Model(id: "ecmwf_ifs", label: "ECMWF IFS HRES", kind: .global, maxLeadHours: 240),
        Model(id: "gfs_seamless", label: "NOAA GFS", kind: .global, maxLeadHours: 384),
        Model(id: "gem_seamless", label: "EC GEM", kind: .regionalMid, maxLeadHours: 240),
        Model(id: "ukmo_seamless", label: "UKMO", kind: .regionalMid, maxLeadHours: 168),
        Model(id: "meteofrance_seamless", label: "Météo-France", kind: .regionalCam, maxLeadHours: 102),
        Model(id: "cma_grapes_global", label: "CMA GRAPES", kind: .global, maxLeadHours: 240),
        Model(id: "bom_access_global", label: "BOM ACCESS-G", kind: .global, maxLeadHours: 240),
        Model(id: "jma_seamless", label: "JMA", kind: .regionalMid, maxLeadHours: 264),
        Model(id: "kma_seamless", label: "KMA", kind: .regionalMid, maxLeadHours: 288),
        Model(id: "icon_global", label: "DWD ICON", kind: .global, maxLeadHours: 180),
        Model(id: "icon_eu", label: "DWD ICON-EU", kind: .regionalMid, maxLeadHours: 120),
        Model(id: "icon_d2", label: "DWD ICON-D2", kind: .regionalCam, maxLeadHours: 48),
        Model(id: "knmi_harmonie_arome_europe", label: "KNMI Harmonie", kind: .regionalCam, maxLeadHours: 60),
        Model(id: "dmi_harmonie_arome_europe", label: "DMI Harmonie", kind: .regionalCam, maxLeadHours: 60),
        Model(id: "metno_nordic", label: "MET Norway", kind: .regionalCam, maxLeadHours: 60),
        Model(id: "meteoswiss_icon_seamless", label: "MeteoSwiss ICON", kind: .regionalCam, maxLeadHours: 120),
        Model(id: "geosphere_arome_austria", label: "GeoSphere AROME", kind: .regionalCam, maxLeadHours: 60),
        Model(id: "ecmwf_aifs025_single", label: "ECMWF AIFS", kind: .ai, maxLeadHours: 360),
        Model(id: "gfs_graphcast025", label: "NOAA GraphCast", kind: .ai, maxLeadHours: 384),
        Model(id: "ncep_aigfs025", label: "NOAA AIGFS", kind: .ai, maxLeadHours: 384),
        Model(id: "ncep_hgefs025_ensemble_mean", label: "NOAA HGEFS mean", kind: .ensembleMean, maxLeadHours: 384),
    ]

    static let ids = all.map(\.id)

    static func model(_ id: String) -> Model? { all.first { $0.id == id } }

    static func label(_ id: String) -> String { model(id)?.label ?? id }

    /// Models sharing a lineage do not corroborate each other (meteocompare ADR 0006).
    static let family: [String: String] = [
        "icon_global": "icon", "icon_eu": "icon", "icon_d2": "icon", "meteoswiss_icon_seamless": "icon",
        "gfs_seamless": "gfs", "gfs_graphcast025": "gfs", "ncep_aigfs025": "gfs", "ncep_hgefs025_ensemble_mean": "gfs",
        "ecmwf_ifs": "ecmwf", "ecmwf_aifs025_single": "ecmwf",
        "knmi_harmonie_arome_europe": "harmonie", "dmi_harmonie_arome_europe": "harmonie", "metno_nordic": "harmonie",
    ]

    /// A family counts as 1 + 0.5 per extra member (core's `effectiveModelCount`).
    static func effectiveCount(_ ids: [String]) -> Double {
        var sizes: [String: Int] = [:]
        for id in ids { sizes[family[id] ?? id, default: 0] += 1 }
        return sizes.values.reduce(0) { $0 + 1 + Double($1 - 1) * 0.5 }
    }
}

// MARK: - Consensus

/// The daily variables compared (core's `DAILY_VARS`), in request order.
enum DailyVar: String, CaseIterable, Sendable {
    case weatherCode = "weather_code"
    case temperatureMax = "temperature_2m_max"
    case temperatureMin = "temperature_2m_min"
    case precipitationSum = "precipitation_sum"
    case precipitationProbability = "precipitation_probability_max"
    case windSpeedMax = "wind_speed_10m_max"
}

/// One model's value, in the registry's order.
struct ModelValue: Equatable, Sendable {
    let id: String
    let value: Double
}

/// Many models' opinions as one number and how far to trust it (core's
/// `lib/compare/consensus.ts`).
struct Consensus: Equatable, Sendable {
    var value: Double?
    var stdDev: Double
    var min: Double?
    var max: Double?
    /// 0–1: how much the models agree, discounted for shared lineage.
    var predictability: Double
    var contributors: [String]

    static let empty = Consensus(value: nil, stdDev: 0, min: nil, max: nil, predictability: 0, contributors: [])

    enum Tier: String, Sendable { case high, mid, low }

    /// meteocompare's raw-scale cutoffs (ADR 0008).
    static func tier(_ predictability: Double) -> Tier {
        predictability >= 0.7 ? .high : predictability >= 0.4 ? .mid : .low
    }

    /// The spread considered normal for a variable this far ahead.
    static func typicalSpread(_ variable: DailyVar, leadHours: Double) -> Double {
        switch variable {
        case .temperatureMax, .temperatureMin:
            if leadHours <= 24 { return 1 }
            if leadHours <= 72 { return 1 + (leadHours - 24) / 48 }
            if leadHours <= 168 { return 2 + (leadHours - 72) / 96 * 1.5 }
            return 3.5
        case .precipitationSum: return leadHours <= 48 ? 5 : 10
        case .precipitationProbability: return 25
        case .windSpeedMax: return leadHours <= 48 ? 4 : 7
        case .weatherCode: return 1
        }
    }

    /// The model's weight: convection-allowing models count more on rain.
    static func weight(_ id: String, _ variable: DailyVar) -> Double {
        guard let model = CompareModels.model(id) else { return 1 }
        var weight: Double
        switch model.kind {
        case .global, .regionalMid: weight = 1
        case .regionalCam: weight = 1.1
        case .ai: weight = 0.8
        case .ensembleMean: weight = 0.9
        }
        if (variable == .precipitationSum || variable == .precipitationProbability) && model.kind == .regionalCam {
            weight *= 1.3
        }
        return weight
    }

    private static func clamp01(_ value: Double) -> Double { Swift.min(1, Swift.max(0, value)) }

    /// Fewer than about three independent models is thin corroboration.
    private static func modelCountFactor(_ ids: [String]) -> Double {
        Swift.min(1, CompareModels.effectiveCount(ids) / 3)
    }

    /// One variable's per-model values for one day (core's `consensusOf`).
    static func of(_ values: [ModelValue], _ variable: DailyVar, leadHours: Double) -> Consensus {
        guard !values.isEmpty else { return .empty }
        let ids = values.map(\.id)
        let numbers = values.map(\.value)
        if variable == .weatherCode {
            // Categorical: the weighted mode, first-seen code winning a tie.
            var weights: [(code: Double, weight: Double)] = []
            var total = 0.0
            for value in values {
                let w = weight(value.id, variable)
                if let at = weights.firstIndex(where: { $0.code == value.value }) {
                    weights[at].weight += w
                } else {
                    weights.append((value.value, w))
                }
                total += w
            }
            var winner = values[0].value
            var best = 0.0
            for entry in weights where entry.weight > best {
                best = entry.weight
                winner = entry.code
            }
            return Consensus(value: winner, stdDev: 0, min: numbers.min(), max: numbers.max(),
                             predictability: clamp01(best / total * modelCountFactor(ids)), contributors: ids)
        }
        var weightSum = 0.0, weighted = 0.0
        for value in values {
            let w = weight(value.id, variable)
            weighted += value.value * w
            weightSum += w
        }
        let mean = weighted / weightSum
        var variance = 0.0
        for value in values { variance += weight(value.id, variable) * (value.value - mean) * (value.value - mean) }
        let stdDev = (variance / weightSum).squareRoot()
        let spreadScore = clamp01(1 - stdDev / typicalSpread(variable, leadHours: leadHours))
        return Consensus(value: mean, stdDev: stdDev, min: numbers.min(), max: numbers.max(),
                         predictability: clamp01(spreadScore * modelCountFactor(ids)), contributors: ids)
    }
}

/// WMO weather codes as Open-Meteo returns them, with core's pictograms
/// (`lib/compare/weatherCodes.ts`); the label is `compare.weather.<code>`.
enum WeatherCodes {
    static let icons: [Int: String] = [
        0: "☀️", 1: "🌤", 2: "⛅️", 3: "☁️", 45: "🌫", 48: "🌫", 51: "🌦", 53: "🌦", 55: "🌦", 56: "🌧", 57: "🌧",
        61: "🌦", 63: "🌧", 65: "🌧", 66: "🌧", 67: "🌧", 71: "🌨", 73: "🌨", 75: "❄️", 77: "🌨", 80: "🌦",
        81: "🌧", 82: "⛈", 85: "🌨", 86: "❄️", 95: "⛈", 96: "⛈", 99: "⛈",
    ]

    /// The known code nearest `value`, nil for an unknown or missing one
    /// (which core shows as "—" and "•").
    static func code(_ value: Double?) -> Int? {
        guard let value, value.isFinite else { return nil }
        let known = Int(value.rounded())
        return icons[known] == nil ? nil : known
    }

    static func icon(_ value: Double?) -> String { code(value).flatMap { icons[$0] } ?? "•" }
}

// MARK: - Open-Meteo

/// Open-Meteo's multi-model forecast endpoint (core's `lib/compare/openMeteo.ts`).
enum OpenMeteo {
    static let forecastURL = URL(string: "https://api.open-meteo.com/v1/forecast")!
    /// The hourly answers are shared for this long (the strip and the panel ask alike).
    static let hourlyTTL: TimeInterval = 10 * 60

    struct DailyForecast: Equatable, Sendable {
        /// ISO date, local to the point.
        let date: String
        let values: [DailyVar: [ModelValue]]
    }

    struct Forecast: Equatable, Sendable {
        let latitude: Double
        let longitude: Double
        let utcOffset: Int
        let days: [DailyForecast]
        /// Models with at least one value; the rest do not cover this point.
        let respondingModels: [String]
    }

    /// One hourly variable per model, over the forecast's hours.
    struct HourlySeries: Equatable, Sendable {
        /// The steps, as instants: Open-Meteo's local times placed with the
        /// point's own offset (core reads them in the device's zone).
        let times: [Date]
        /// Model id to its value per step, nil where it has none; models in
        /// the registry's order (`ids`).
        let ids: [String]
        let series: [String: [Double?]]
        let units: String
        let utcOffset: Int
    }

    struct Failure: Error, Equatable, Sendable {
        let message: String
    }

    private static func query(_ latitude: Double, _ longitude: Double) -> [URLQueryItem] {
        [URLQueryItem(name: "latitude", value: String(latitude)), URLQueryItem(name: "longitude", value: String(longitude))]
    }

    static func dailyURL(latitude: Double, longitude: Double, models: [String] = CompareModels.ids, days: Int = 7) -> URL {
        var components = URLComponents(url: forecastURL, resolvingAgainstBaseURL: false)!
        components.queryItems = query(latitude, longitude) + [
            URLQueryItem(name: "daily", value: DailyVar.allCases.map(\.rawValue).joined(separator: ",")),
            URLQueryItem(name: "models", value: models.joined(separator: ",")),
            URLQueryItem(name: "forecast_days", value: String(days)),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "wind_speed_unit", value: "kmh"),
            URLQueryItem(name: "precipitation_unit", value: "mm"),
            URLQueryItem(name: "temperature_unit", value: "celsius"),
        ]
        return components.url!
    }

    static func hourlyURL(latitude: Double, longitude: Double, variable: String, models: [String] = CompareModels.ids,
                          days: Int = 7) -> URL {
        var components = URLComponents(url: forecastURL, resolvingAgainstBaseURL: false)!
        components.queryItems = query(latitude, longitude) + [
            URLQueryItem(name: "hourly", value: variable),
            URLQueryItem(name: "models", value: models.joined(separator: ",")),
            URLQueryItem(name: "forecast_days", value: String(days)),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "precipitation_unit", value: "mm"),
            URLQueryItem(name: "temperature_unit", value: "celsius"),
        ]
        return components.url!
    }

    /// The hourly cache's key (core's): about 100 m, the variable, the days, the models.
    static func hourlyKey(latitude: Double, longitude: Double, variable: String, models: [String] = CompareModels.ids,
                          days: Int = 7) -> String {
        [String(format: "%.3f", latitude), String(format: "%.3f", longitude), variable, String(days),
         models.joined(separator: ",")].joined(separator: "|")
    }

    /// A failed answer as core words it: "open-meteo 429: …".
    static func failure(status: Int, body: Data?) -> Failure {
        let text = body.flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Failure(message: "open-meteo \(status): \(text.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: status) : text)")
    }

    private static func numbers(_ raw: Any?) -> [Double?]? {
        guard let array = raw as? [Any] else { return nil }
        return array.map { item in
            guard let number = item as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let value = number.doubleValue
            return value.isFinite ? value : nil
        }
    }

    /// `2026-10-20T00:00` at the point, `offset` seconds east of UTC.
    static func instant(_ local: String, utcOffset offset: Int) -> Date? {
        let parts = local.split(separator: "T")
        guard let datePart = parts.first else { return nil }
        let ymd = datePart.split(separator: "-").compactMap { Int($0) }
        guard ymd.count == 3 else { return nil }
        var hour = 0, minute = 0
        if parts.count > 1 {
            let hm = parts[1].split(separator: ":").compactMap { Int($0) }
            guard hm.count >= 2 else { return nil }
            (hour, minute) = (hm[0], hm[1])
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let utc = calendar.date(from: DateComponents(year: ymd[0], month: ymd[1], day: ymd[2], hour: hour, minute: minute))
        else { return nil }
        return utc.addingTimeInterval(TimeInterval(-offset))
    }

    /// The daily answer as days of per-model values (core's `shape`).
    static func forecast(_ data: Data, models: [String] = CompareModels.ids) -> Forecast? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let daily = object["daily"] as? [String: Any],
              let dates = daily["time"] as? [String] else { return nil }
        var responding = Set<String>()
        var columns: [String: [Double?]] = [:]
        for variable in DailyVar.allCases {
            for id in models { columns["\(variable.rawValue)_\(id)"] = numbers(daily["\(variable.rawValue)_\(id)"]) }
        }
        let days = dates.enumerated().map { index, date in
            var values: [DailyVar: [ModelValue]] = [:]
            for variable in DailyVar.allCases {
                values[variable] = models.compactMap { id in
                    guard let column = columns["\(variable.rawValue)_\(id)"], index < column.count,
                          let value = column[index] else { return nil }
                    responding.insert(id)
                    return ModelValue(id: id, value: value)
                }
            }
            return DailyForecast(date: date, values: values)
        }
        return Forecast(latitude: (object["latitude"] as? NSNumber)?.doubleValue ?? 0,
                        longitude: (object["longitude"] as? NSNumber)?.doubleValue ?? 0,
                        utcOffset: (object["utc_offset_seconds"] as? NSNumber)?.intValue ?? 0,
                        days: days, respondingModels: models.filter(responding.contains))
    }

    /// The hourly answer (core's `fetchHourlySeriesUncached`): a model only
    /// with at least one value, so one that does not cover the point does
    /// not flatten the band to zero.
    static func hourly(_ data: Data, variable: String, models: [String] = CompareModels.ids) -> HourlySeries? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hourly = object["hourly"] as? [String: Any],
              let rawTimes = hourly["time"] as? [String] else { return nil }
        let offset = (object["utc_offset_seconds"] as? NSNumber)?.intValue ?? 0
        let times = rawTimes.compactMap { instant($0, utcOffset: offset) }
        guard times.count == rawTimes.count else { return nil }
        var ids: [String] = []
        var series: [String: [Double?]] = [:]
        for id in models {
            guard let column = numbers(hourly["\(variable)_\(id)"]), column.contains(where: { $0 != nil }) else { continue }
            ids.append(id)
            series[id] = column
        }
        let units = (object["hourly_units"] as? [String: Any])?["\(variable)_\(models.first ?? "")"] as? String ?? "°C"
        return HourlySeries(times: times, ids: ids, series: series, units: units, utcOffset: offset)
    }

    /// How far ahead a day is: noon at the point, from now, in hours, at
    /// least 0 (core's `leadHours`, which takes the device's noon).
    static func leadHours(date: String, utcOffset: Int, now: Date) -> Double {
        guard let noon = instant(date + "T12:00", utcOffset: utcOffset) else { return 0 }
        return max(0, noon.timeIntervalSince(now) / 3600)
    }
}

// MARK: - Outlook

/// The spread's arithmetic (core's `lib/compare/outlook.ts`).
enum Outlook {
    /// Median hourly rainfall from here is "rain coming" (core's `RAIN_LIKELY_MM`).
    static let rainLikelyMM = 0.2

    static func quantile(_ sorted: [Double], _ q: Double) -> Double {
        if sorted.count == 1 { return sorted[0] }
        let position = Double(sorted.count - 1) * q
        let base = Int(position.rounded(.down))
        let rest = position - Double(base)
        guard base + 1 < sorted.count else { return sorted[base] }
        return sorted[base] + rest * (sorted[base + 1] - sorted[base])
    }

    struct Envelope: Equatable, Sendable {
        var min: [Double?] = []
        var max: [Double?] = []
        var mid: [Double?] = []
        var count: [Int] = []
    }

    /// Min, median and max across the models that answered, per step from `from`.
    static func envelope(_ series: OpenMeteo.HourlySeries, from: Int, steps: Int) -> Envelope {
        var envelope = Envelope()
        guard steps > 0 else { return envelope }
        for i in from ..< from + steps {
            let values = series.ids.compactMap { id -> Double? in
                guard let column = series.series[id], i >= 0, i < column.count else { return nil }
                return column[i]
            }.sorted()
            envelope.count.append(values.count)
            if values.isEmpty {
                envelope.min.append(nil)
                envelope.max.append(nil)
                envelope.mid.append(nil)
            } else {
                envelope.min.append(values[0])
                envelope.max.append(values[values.count - 1])
                envelope.mid.append(quantile(values, 0.5))
            }
        }
        return envelope
    }

    /// The step holding `now`: the last one at or before it, 0 if none.
    static func stepAt(_ times: [Date], _ now: Date) -> Int {
        var at = 0
        for (i, time) in times.enumerated() {
            if time > now { break }
            at = i
        }
        return at
    }

    /// Hours from `from` until the median first reaches `rainLikelyMM`,
    /// looking `hours` ahead; nil for a window it never does.
    static func rainIn(_ series: OpenMeteo.HourlySeries, from: Int, hours: Int) -> Int? {
        let steps = max(0, min(hours, series.times.count - from))
        return envelope(series, from: from, steps: steps).mid.firstIndex { ($0 ?? -.infinity) >= rainLikelyMM }
    }

    /// Calendar days from `now` to `at` in `calendar`'s zone: 0 today, 1 tomorrow.
    static func daysAhead(_ at: Date, _ now: Date, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: at)).day ?? 0
    }

    /// The dry-weather strip's title (core's `DryOutlook.svelte:57-85`).
    enum Title: Equatable, Sendable {
        /// Before the models answer.
        case asking
        /// "No Rain in Sight · Next 7 Days".
        case dryWeek
        case hours(Int)
        case tomorrow
        case days(Int)
        /// 0 = Sunday … 6 = Saturday.
        case weekday(Int)

        var key: String {
            switch self {
            case .asking: return "dry_outlook_label"
            case .dryWeek: return "dry_outlook_title_week"
            case .hours: return "dry_outlook_title_hours"
            case .tomorrow: return "dry_outlook_title_tomorrow"
            case .days: return "dry_outlook_title_days"
            case .weekday: return "dry_outlook_title_weekday"
            }
        }

        var arguments: [String: String] {
            switch self {
            case .hours(let hours): return ["hours": String(hours)]
            case .days(let days): return ["days": String(days)]
            case .weekday(let day): return ["day": String(day)]
            default: return [:]
            }
        }
    }

    /// What the strip shows from `series` at `now`: where the plot starts,
    /// how many hours it spans (a day when rain is less than a day off,
    /// else the week), and its title.
    static func strip(_ series: OpenMeteo.HourlySeries?, now: Date, calendar: Calendar = .current)
        -> (from: Int, hours: Int, title: Title) {
        guard let series else { return (0, 168, .asking) }
        let from = stepAt(series.times, now)
        guard let wetIn = rainIn(series, from: from, hours: 168) else { return (from, 168, .dryWeek) }
        if wetIn < 24 { return (from, 24, .hours(wetIn)) }
        let at = from + wetIn < series.times.count ? series.times[from + wetIn] : now.addingTimeInterval(Double(wetIn) * 3600)
        let days = daysAhead(at, now, calendar: calendar)
        if days <= 1 { return (from, 168, .tomorrow) }
        if days >= 7 { return (from, 168, .days(days)) }
        return (from, 168, .weekday(calendar.component(.weekday, from: at) - 1))
    }
}

// MARK: - Spread chart axes

/// Where the spread chart labels its axes (core's `lib/compare/spreadChart.ts`).
enum SpreadAxis {
    enum Mark: Equatable, Sendable {
        /// The short weekday, at a midnight over a week.
        case weekday
        /// The hour, every six over a day.
        case hour
    }

    /// The labelled steps: midnights over more than 48 steps, else every
    /// sixth hour; in the point's own zone.
    static func xMarks(_ times: [Date], steps: Int, timeZone: TimeZone) -> [(index: Int, mark: Mark)] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return times.enumerated().compactMap { index, time in
            let hour = calendar.component(.hour, from: time)
            if steps > 48 { return hour == 0 ? (index, .weekday) : nil }
            return hour % 6 == 0 ? (index, .hour) : nil
        }
    }

    /// Chart.js's `niceNum`: 1, 2, 5 or 10 times a power of ten, at least `range`.
    static func niceNum(_ range: Double) -> Double {
        guard range > 0 else { return 0 }
        let power = pow(10, (log10(range)).rounded(.down))
        let fraction = range / power
        let nice: Double = fraction <= 1 ? 1 : fraction <= 2 ? 2 : fraction <= 5 ? 5 : 10
        return nice * power
    }

    /// The value axis's ticks: rainfall from 0 with a soft ceiling of 6 mm
    /// in fixed steps (3 mm on the strip, 2 mm on the panel) while the
    /// models stay under it; otherwise Chart.js's nice steps, at most three
    /// on the strip (`compact`) and five on the panel.
    static func yTicks(low: Double, high: Double, compact: Bool, fromZero: Bool, suggestedMax: Double?) -> [Double] {
        let maxTicks = compact ? 3 : 5
        var rmin = fromZero ? 0 : low
        var rmax = high
        if let suggestedMax { rmax = max(rmax, suggestedMax) }
        if rmax <= rmin { rmax = rmin + 1; if !fromZero { rmin -= 1 } }
        var spacing: Double
        if let suggestedMax, high <= suggestedMax {
            spacing = suggestedMax / (compact ? 2 : 3)
        } else {
            let spaces = Double(max(1, maxTicks - 1))
            spacing = niceNum((rmax - rmin) / spaces)
            let count = (rmax / spacing).rounded(.up) - (rmin / spacing).rounded(.down)
            if count > spaces { spacing = niceNum(count * spacing / spaces) }
        }
        let start = (rmin / spacing).rounded(.down) * spacing
        let end = (rmax / spacing).rounded(.up) * spacing
        var ticks: [Double] = []
        var value = start
        while value <= end + spacing * 1e-9 {
            ticks.append((value / spacing).rounded() * spacing)
            value += spacing
        }
        return ticks
    }
}
