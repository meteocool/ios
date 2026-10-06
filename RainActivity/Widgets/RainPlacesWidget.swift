import SwiftUI
import WidgetKit

/// The rain at several places at once: home, work, the parents', the
/// campsite. A row each, with what the rain does next and a small chart.
struct RainPlacesWidget: Widget {
    static let kind = "RainPlaces"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: RainPlacesConfiguration.self, provider: RainPlacesProvider()) { entry in
            RainPlacesView(entry: entry)
        }
        .configurationDisplayName("Places")
        .description("The rain at up to six places, side by side.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct RainPlacesEntry: TimelineEntry {
    let entry: RainEntry
    let range: ForecastRange

    var date: Date { entry.date }
    var relevance: TimelineEntryRelevance? {
        // The place with the most pressing rain decides.
        entry.places.compactMap { RainTimeline.relevance(of: $0.forecast) }.max { $0.score < $1.score }
    }
}

struct RainPlacesProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> RainPlacesEntry {
        RainPlacesEntry(entry: RainTimeline.sample(places: context.family == .systemLarge ? 6 : 3), range: .nextHour)
    }

    func snapshot(for configuration: RainPlacesConfiguration, in context: Context) async -> RainPlacesEntry {
        if context.isPreview { return placeholder(in: context) }
        return await load(configuration, in: context).first ?? placeholder(in: context)
    }

    func timeline(for configuration: RainPlacesConfiguration, in context: Context) async -> Timeline<RainPlacesEntry> {
        Timeline(entries: await load(configuration, in: context), policy: RainTimeline.policy())
    }

    private func load(_ configuration: RainPlacesConfiguration, in context: Context) async -> [RainPlacesEntry] {
        let limit = context.family == .systemLarge ? 6 : 3
        let chosen = configuration.places?.isEmpty == false ? configuration.places! : [.current]
        let places = await RainTimeline.load(Array(chosen.prefix(limit)), threshold: configuration.intensity.threshold)
        // Entries end when the first place's forecast does; every place's
        // forecast is fetched at the same time, so they all end together.
        return RainTimeline.entries(places: places, map: nil)
            .map { RainPlacesEntry(entry: $0, range: configuration.range) }
    }
}

struct RainPlacesView: View {
    let entry: RainPlacesEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let places = entry.entry.places
        VStack(alignment: .leading, spacing: 0) {
            if family == .systemLarge {
                HStack {
                    Text("widget_places_title").font(.headline)
                    Spacer()
                    RefreshButton(fetched: places.compactMap(\.fetched).min())
                }
                .padding(.bottom, 8)
            }
            ForEach(Array(places.enumerated()), id: \.element.id) { index, place in
                if index > 0 { Divider().padding(.vertical, family == .systemLarge ? 6 : 4) }
                Group {
                    if let link = place.link() {
                        Link(destination: link) { PlaceRow(place: place, range: entry.range) }
                    } else {
                        PlaceRow(place: place, range: entry.range)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            if family == .systemLarge && places.count < 6 { Spacer(minLength: 0) }
        }
        .rainBackground()
    }
}

private struct PlaceRow: View {
    let place: PlaceRain
    let range: ForecastRange

    var body: some View {
        HStack(spacing: 10) {
            if let forecast = place.forecast {
                let status = RainStatus(forecast: forecast)
                Image(systemName: status.symbol)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.primary, status.colour)
                    .font(.title3)
                    .frame(width: 26)
                    .widgetAccentable()
                VStack(alignment: .leading, spacing: 1) {
                    PlaceLabel(place: place, font: .subheadline.weight(.semibold))
                    status.line
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                RainChart(forecast: forecast.window(past: range.steps.past, ahead: range.steps.ahead), axis: false)
                    .frame(width: 96)
                    .frame(maxHeight: 30)
            } else {
                Image(systemName: place.problem == .noLocation ? "location.slash" : "icloud.slash")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    PlaceLabel(place: place, font: .subheadline.weight(.semibold))
                    Text(place.problem == .noLocation ? "widget_no_location_short" : "widget_no_data")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
    }
}
