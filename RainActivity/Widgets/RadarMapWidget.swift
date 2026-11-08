import SwiftUI
import WidgetKit

/// The radar map around a place, as the rain alerts show it, with what the
/// rain does next laid over it.
struct RadarMapWidget: Widget {
    static let kind = "RadarMap"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: RadarMapConfiguration.self, provider: RadarMapProvider()) { entry in
            RadarMapView(entry: entry.entry, overlay: entry.overlay)
        }
        .configurationDisplayName("Radar Map")
        .description("The rain radar around you or any place. Add up to four locations below the map on extra-large widgets.")
        .supportedFamilies(RadarMapLayout.families)
        .contentMarginsDisabled()
    }
}

struct RadarMapEntry: TimelineEntry {
    let entry: RainEntry
    let overlay: MapOverlay

    var date: Date { entry.date }
    var relevance: TimelineEntryRelevance? {
        guard overlay != .none || entry.places.count > 1 else { return nil }
        return entry.places.compactMap { RainTimeline.relevance(of: $0.forecast) }.max { $0.score < $1.score }
    }
}

struct RadarMapProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> RadarMapEntry {
        RadarMapEntry(entry: RainTimeline.sample(), overlay: .headline)
    }

    func snapshot(for configuration: RadarMapConfiguration, in context: Context) async -> RadarMapEntry {
        if context.isPreview { return placeholder(in: context) }
        return await load(configuration, in: context).first ?? placeholder(in: context)
    }

    func timeline(for configuration: RadarMapConfiguration, in context: Context) async -> Timeline<RadarMapEntry> {
        Timeline(entries: await load(configuration, in: context), policy: RainTimeline.policy())
    }

    private func load(_ configuration: RadarMapConfiguration, in context: Context) async -> [RadarMapEntry] {
        let environment = MeteocoolEnvironment.stored(in: WidgetStore.defaults)
        let additional = RadarMapLayout.locations(configuration.places ?? [], family: context.family)
        let places = await RainTimeline.load([configuration.place ?? .current] + additional,
                                             threshold: configuration.intensity.threshold, environment: environment)
        // The medium and extra large widgets are about twice as wide as
        // they are tall, as is the service's wide card.
        let wide = context.family == .systemMedium || context.family == .systemExtraLarge
        let map = await RainTimeline.map(for: places.first, zoom: configuration.area.zoom, wide: wide, size: context.displaySize)
        return RainTimeline.entries(places: places, map: map, environment: environment)
            .map { RadarMapEntry(entry: $0, overlay: configuration.overlay) }
    }
}

struct RadarMapView: View {
    let entry: RainEntry
    let overlay: MapOverlay
    @Environment(\.widgetFamily) private var family

    var body: some View {
        RadarMapContent(entry: entry, overlay: overlay, family: family)
    }
}

struct RadarMapContent: View {
    let entry: RainEntry
    let overlay: MapOverlay
    let family: WidgetFamily
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let places = RadarMapLayout.locations(Array(entry.places.dropFirst()), family: family)
        VStack(spacing: 0) {
            map.layoutPriority(-1)

            if !places.isEmpty {
                locations(places)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .rainBackground()
        .widgetURL(entry.main?.link(zoom: entry.map?.card.zoom ?? 10))
    }

    @ViewBuilder private func locations(_ places: [PlaceRain]) -> some View {
        if family == .systemExtraLarge {
            Grid(horizontalSpacing: 12, verticalSpacing: 0) {
                GridRow { ForEach(Array(places.prefix(2))) { location($0) } }
                if places.count > 2 {
                    GridRow { ForEach(Array(places.dropFirst(2))) { location($0) } }
                }
            }
        } else {
            VStack(spacing: 0) { ForEach(places) { location($0) } }
        }
    }

    @ViewBuilder private func location(_ place: PlaceRain) -> some View {
        Group {
            if let link = place.link() {
                Link(destination: link) { PlaceRow(place: place, range: .nextHour) }
                    .buttonStyle(.plain)
            } else {
                PlaceRow(place: place, range: .nextHour)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private var map: some View {
        let place = entry.main
        ZStack {
            RadarMapImage(snapshot: entry.map, isCurrent: place?.isCurrent ?? true)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    if let place { MapChip { PlaceLabel(place: place) } }
                    Spacer(minLength: 4)
                    if let rendered = entry.map?.rendered(for: colorScheme), family != .systemSmall || overlay == .none {
                        MapChip { Text(rendered, style: .time) }
                    }
                }
                Spacer(minLength: 0)
                if let problem = place?.problem, problem == .noLocation || entry.map == nil || overlay != .none {
                    MapPanel { ProblemView(problem: problem).fixedSize(horizontal: false, vertical: true) }
                } else if overlay != .none, let forecast = place?.forecast {
                    MapPanel { panel(forecast) }
                }
            }
            .padding(family == .systemSmall ? 8 : 10)
        }
    }

    @ViewBuilder private func panel(_ forecast: RainForecast) -> some View {
        let status = RainStatus(forecast: forecast)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: status.symbol)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, status.colour)
                status.line
                    .font(family == .systemSmall ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                    .lineLimit(family == .systemSmall ? 2 : 1)
                    .minimumScaleFactor(0.8)
            }
            if overlay == .chart {
                RainChart(forecast: forecast.window(past: 0, ahead: family == .systemSmall ? 12 : 24))
                    .frame(height: family == .systemSmall ? 26 : family == .systemMedium ? 30 : 44)
            }
        }
    }
}

/// The dark panel at the bottom of a map, for the rain's line and chart.
private struct MapPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
