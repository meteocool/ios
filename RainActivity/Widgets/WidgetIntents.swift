import AppIntents
import WidgetKit

struct RadarMapConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Radar Map"
    static let description = IntentDescription("The rain radar around a place, with what the rain does next.")

    @Parameter(title: "Location")
    var place: WidgetPlace?

    @Parameter(title: "Map Area", default: .regional)
    var area: MapZoom

    @Parameter(title: "Forecast", default: .headline)
    var overlay: MapOverlay

    @Parameter(title: "Intensity", default: .app)
    var intensity: IntensityChoice

    static var parameterSummary: some ParameterSummary {
        When(\.$overlay, .equalTo, .none) {
            Summary {
                \.$place
                \.$area
                \.$overlay
            }
        } otherwise: {
            Summary {
                \.$place
                \.$area
                \.$overlay
                \.$intensity
            }
        }
    }
}

struct RainForecastConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Rain Forecast"
    static let description = IntentDescription("The rain chart from the map, for one place.")

    @Parameter(title: "Location")
    var place: WidgetPlace?

    @Parameter(title: "Time Range", default: .nextTwoHours)
    var range: ForecastRange

    @Parameter(title: "Intensity", default: .app)
    var intensity: IntensityChoice

    @Parameter(title: "Show Radar Map", description: "On the medium and large widget.", default: true)
    var showMap: Bool
}

struct RainClockConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Rain Clock"
    static let description = IntentDescription("The next hour or two around a dial, coloured where it rains.")

    @Parameter(title: "Location")
    var place: WidgetPlace?

    @Parameter(title: "Dial", default: .hour)
    var span: DialSpan

    @Parameter(title: "Intensity", default: .app)
    var intensity: IntensityChoice
}

struct RainPlacesConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Places"
    static let description = IntentDescription("The rain at several places at once.")

    @Parameter(title: "Places", size: [.systemMedium: 3, .systemLarge: 6])
    var places: [WidgetPlace]?

    @Parameter(title: "Time Range", default: .nextHour)
    var range: ForecastRange

    @Parameter(title: "Intensity", default: .app)
    var intensity: IntensityChoice
}

/// The refresh button on the larger widgets. WidgetKit reloads a widget's
/// timeline after its button's intent; this makes that reload ask the API
/// again rather than reuse what it fetched a moment ago.
struct RefreshRainIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh Rain"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        WidgetStore.defaults?.set(Date().timeIntervalSince1970, forKey: "widgetRefreshRequested")
        return .result()
    }
}
