import AppIntents

/// How much of the map a radar widget shows. The preview service renders a
/// 1024-pixel page at this zoom (snapped to half steps), so the names give
/// the width of the square image.
enum MapZoom: String, AppEnum {
    case local, regional, wide, country

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Map Area"
    static let caseDisplayRepresentations: [MapZoom: DisplayRepresentation] = [
        .local: DisplayRepresentation(title: "Local", subtitle: "About 40 km across"),
        .regional: DisplayRepresentation(title: "Regional", subtitle: "About 150 km across"),
        .wide: DisplayRepresentation(title: "Wide", subtitle: "About 400 km across"),
        .country: DisplayRepresentation(title: "Country", subtitle: "About 1,200 km across"),
    ]

    var zoom: Double {
        switch self {
        case .local: return 11
        case .regional: return 9.5
        case .wide: return 8
        case .country: return 6.5
        }
    }
}

/// Which part of the forecast a chart shows. `/v3/radar/timeseries` has two
/// hours of observations and two of forecast.
enum ForecastRange: String, AppEnum {
    case nextHour, nextTwoHours, aroundNow, everything

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Time Range"
    static let caseDisplayRepresentations: [ForecastRange: DisplayRepresentation] = [
        .nextHour: "Next hour",
        .nextTwoHours: "Next 2 hours",
        .aroundNow: "Last half hour and next 90 minutes",
        .everything: "Last 2 hours and next 2 hours",
    ]

    /// Steps before now and after it, at 5 minutes a step.
    var steps: (past: Int, ahead: Int) {
        switch self {
        case .nextHour: return (0, 12)
        case .nextTwoHours: return (0, 24)
        case .aroundNow: return (6, 18)
        case .everything: return (24, 24)
        }
    }
}

/// The rain a widget counts as rain: the app's Intensity Threshold, or one
/// of its values for this widget alone.
enum IntensityChoice: String, AppEnum {
    // `hail` is 41 dBZ, heavy rain. It keeps the name the step once had,
    // because widgets store their choice by it.
    case app, drizzle, light, rain, intense, hail

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Intensity"
    static let caseDisplayRepresentations: [IntensityChoice: DisplayRepresentation] = [
        .app: DisplayRepresentation(title: "As in the app", subtitle: "The Intensity Threshold setting"),
        .drizzle: "Drizzle",
        .light: "Light rain",
        .rain: "Rain",
        .intense: "Intense Rain",
        .hail: "Heavy Rain",
    ]

    /// In dBZ, as `RainForecast.thresholds`.
    var threshold: Double {
        switch self {
        case .app:
            let value = WidgetStore.defaults?.object(forKey: "intensityValue") as? Int ?? 1
            return RainForecast.thresholds[min(max(value, 0), RainForecast.thresholds.count - 1)]
        case .drizzle: return RainForecast.thresholds[0]
        case .light: return RainForecast.thresholds[1]
        case .rain: return RainForecast.thresholds[2]
        case .intense: return RainForecast.thresholds[3]
        case .hail: return RainForecast.thresholds[4]
        }
    }
}

/// How far ahead the rain clock's dial reaches.
enum DialSpan: String, AppEnum {
    case hour, twoHours

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Dial"
    static let caseDisplayRepresentations: [DialSpan: DisplayRepresentation] = [
        .hour: DisplayRepresentation(title: "One hour", subtitle: "One turn of the minute hand"),
        .twoHours: DisplayRepresentation(title: "Two hours", subtitle: "The whole forecast"),
    ]

    var steps: Int { self == .hour ? 12 : 24 }
}

/// What a radar map widget lays over the map.
enum MapOverlay: String, AppEnum {
    case none, headline, chart

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Forecast"
    static let caseDisplayRepresentations: [MapOverlay: DisplayRepresentation] = [
        .none: DisplayRepresentation(title: "Map only"),
        .headline: DisplayRepresentation(title: "Next rain", subtitle: "One line, such as \"Rain in 12 min\""),
        .chart: DisplayRepresentation(title: "Next rain and chart", subtitle: "The line plus bars for the next hour"),
    ]
}
