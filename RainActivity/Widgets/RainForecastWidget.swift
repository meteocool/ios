import SwiftUI
import WidgetKit

/// The Live Activity on the home screen: what the rain does next and the bar
/// chart under the web map, beside the radar map on the larger sizes.
struct RainForecastWidget: Widget {
    static let kind = "RainForecast"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: RainForecastConfiguration.self, provider: RainForecastProvider()) { entry in
            RainForecastView(entry: entry)
        }
        .configurationDisplayName("Rain Forecast")
        .description("When rain arrives and how heavy it gets, as in the map's chart.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct RainForecastEntry: TimelineEntry {
    let entry: RainEntry
    let range: ForecastRange
    let showMap: Bool

    var date: Date { entry.date }
    var relevance: TimelineEntryRelevance? { entry.relevance }
}

struct RainForecastProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> RainForecastEntry {
        RainForecastEntry(entry: RainTimeline.sample(), range: .nextTwoHours, showMap: true)
    }

    func snapshot(for configuration: RainForecastConfiguration, in context: Context) async -> RainForecastEntry {
        if context.isPreview { return placeholder(in: context) }
        return await load(configuration, in: context).first ?? placeholder(in: context)
    }

    func timeline(for configuration: RainForecastConfiguration, in context: Context) async -> Timeline<RainForecastEntry> {
        Timeline(entries: await load(configuration, in: context), policy: RainTimeline.policy())
    }

    private func load(_ configuration: RainForecastConfiguration, in context: Context) async -> [RainForecastEntry] {
        let places = await RainTimeline.load([configuration.place ?? .current], threshold: configuration.intensity.threshold)
        var map: MapSnapshot?
        if configuration.showMap, let size = RainForecastView.mapSize(for: context.family, in: context.displaySize) {
            map = await RainTimeline.map(for: places.first, zoom: MapZoom.regional.zoom,
                                         wide: context.family == .systemLarge, size: size)
        }
        return RainTimeline.entries(places: places, map: map)
            .map { RainForecastEntry(entry: $0, range: configuration.range, showMap: configuration.showMap) }
    }
}

struct RainForecastView: View {
    let entry: RainForecastEntry
    @Environment(\.widgetFamily) private var family

    /// The large widget's map: the top 40 % or so, cropped from the wide card.
    nonisolated static let largeMapHeight: CGFloat = 150

    /// The map's frame within a widget of `size`, nil where none is drawn.
    nonisolated static func mapSize(for family: WidgetFamily, in size: CGSize) -> CGSize? {
        switch family {
        // The square on the left, inside the margins.
        case .systemMedium: return CGSize(width: size.height - 32, height: size.height - 32)
        // The top, the full width.
        case .systemLarge: return CGSize(width: size.width - 32, height: largeMapHeight)
        default: return nil
        }
    }

    var body: some View {
        Group {
            if let place = entry.entry.main {
                if let problem = place.problem {
                    VStack(alignment: .leading) {
                        PlaceLabel(place: place).foregroundStyle(.secondary)
                        ProblemView(problem: problem, compact: family == .systemSmall)
                    }
                } else if let forecast = place.forecast {
                    content(place: place, forecast: forecast)
                }
            }
        }
        .rainBackground()
        .widgetURL(entry.entry.main?.link())
    }

    private var steps: (past: Int, ahead: Int) {
        // The small widget has room for about two dozen bars.
        family == .systemSmall ? (min(entry.range.steps.past, 6), min(entry.range.steps.ahead, 18)) : entry.range.steps
    }

    @ViewBuilder private func content(place: PlaceRain, forecast: RainForecast) -> some View {
        let chart = RainChart(forecast: forecast.window(past: steps.past, ahead: steps.ahead))
        switch family {
        case .systemSmall:
            VStack(alignment: .leading, spacing: 4) {
                PlaceLabel(place: place).foregroundStyle(.secondary)
                title(forecast, lines: 3)
                Spacer(minLength: 0)
                chart.frame(height: 44)
            }
        case .systemMedium:
            HStack(alignment: .top, spacing: 12) {
                if entry.showMap {
                    RadarMapImage(snapshot: entry.entry.map, isCurrent: place.isCurrent)
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        PlaceLabel(place: place).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        if let time = entry.entry.map?.rendered ?? place.fetched {
                            Text(time, style: .time).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    Headline(forecast: forecast, stale: false)
                    Spacer(minLength: 0)
                    chart.frame(height: 52)
                }
            }
        default:
            VStack(alignment: .leading, spacing: 10) {
                if entry.showMap {
                    RadarMapImage(snapshot: entry.entry.map, isCurrent: place.isCurrent)
                        .frame(maxWidth: .infinity)
                        .frame(height: Self.largeMapHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(alignment: .topLeading) { MapChip { PlaceLabel(place: place) }.padding(8) }
                } else {
                    PlaceLabel(place: place).foregroundStyle(.secondary)
                }
                Headline(forecast: forecast, stale: false)
                chart.frame(maxHeight: .infinity)
                Facts(forecast: forecast, ahead: steps.ahead, fetched: place.fetched)
            }
        }
    }

    private func title(_ forecast: RainForecast, lines: Int) -> some View {
        RainStatus(forecast: forecast).line
            .font(.headline)
            .lineLimit(lines)
            .minimumScaleFactor(0.8)
    }
}

/// Three numbers under the large chart: the heaviest rain, how long it rains,
/// and how old the forecast is, with the button to fetch it again.
private struct Facts: View {
    let forecast: RainForecast
    let ahead: Int
    let fetched: Date?

    var body: some View {
        let peak = forecast.window(past: 0, ahead: ahead).peak
        HStack(alignment: .firstTextBaseline) {
            fact("widget_peak", value: peak > 0 ? RainStatus.name(dbz: peak)
                 : String(localized: "widget_none"), colour: RadarColour.of(dbz: peak))
            Spacer()
            fact("widget_rain_minutes", value: String(localized: "widget_minutes \(forecast.rainMinutes(ahead: ahead))"))
            Spacer()
            RefreshButton(fetched: fetched)
        }
    }

    private func fact(_ title: LocalizedStringKey, value: String, colour: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                if let colour { Circle().fill(colour).frame(width: 7, height: 7) }
                Text(value).font(.caption.weight(.semibold))
            }
        }
    }
}
