import CoreLocation
import SwiftUI
import WidgetKit

/// The next hour (or two) around a dial: now at twelve o'clock, each
/// 5-minute step a segment in the radar's colour where it rains, and the
/// minutes until the rain in the middle. On the home screen and the lock
/// screen, where the inline and rectangular sizes say the same in words.
struct RainClockWidget: Widget {
    static let kind = "RainClock"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: RainClockConfiguration.self, provider: RainClockProvider()) { entry in
            RainClockView(entry: entry)
        }
        .configurationDisplayName("Rain Clock")
        .description("The next hour on a dial, coloured where it will rain.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct RainClockEntry: TimelineEntry {
    let entry: RainEntry
    let span: DialSpan

    var date: Date { entry.date }
    var relevance: TimelineEntryRelevance? { entry.relevance }
}

struct RainClockProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> RainClockEntry {
        RainClockEntry(entry: RainTimeline.sample(), span: .hour)
    }

    func snapshot(for configuration: RainClockConfiguration, in context: Context) async -> RainClockEntry {
        if context.isPreview { return placeholder(in: context) }
        return await load(configuration).first ?? placeholder(in: context)
    }

    func timeline(for configuration: RainClockConfiguration, in context: Context) async -> Timeline<RainClockEntry> {
        Timeline(entries: await load(configuration), policy: RainTimeline.policy())
    }

    private func load(_ configuration: RainClockConfiguration) async -> [RainClockEntry] {
        let places = await RainTimeline.load([configuration.place ?? .current], threshold: configuration.intensity.threshold)
        // A minute apart, so the minutes in the middle are right; the dial
        // itself turns every five.
        return RainTimeline.entries(places: places, map: nil, spacing: 60, count: 31)
            .map { RainClockEntry(entry: $0, span: configuration.span) }
    }
}

struct RainClockView: View {
    let entry: RainClockEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if let place = entry.entry.main {
                if let forecast = place.forecast {
                    content(place: place, forecast: forecast)
                } else if let problem = place.problem {
                    switch family {
                    case .accessoryInline:
                        Image(systemName: problem == .noLocation ? "location.slash" : "icloud.slash")
                    case .systemSmall:
                        VStack(alignment: .leading) {
                            PlaceLabel(place: place).foregroundStyle(.secondary)
                            ProblemView(problem: problem)
                        }
                    default:
                        ProblemView(problem: problem, compact: true)
                    }
                }
            }
        }
        .rainBackground()
        .widgetURL(entry.entry.main?.link())
    }

    @ViewBuilder private func content(place: PlaceRain, forecast: RainForecast) -> some View {
        let status = RainStatus(forecast: forecast)
        switch family {
        case .accessoryInline:
            Label { status.line } icon: { Image(systemName: status.symbol) }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: status.symbol)
                    status.line.lineLimit(1).minimumScaleFactor(0.7)
                }
                .font(.headline)
                .widgetAccentable()
                RainChart(forecast: forecast.window(past: 0, ahead: entry.span.steps), axis: false)
                    .frame(maxHeight: .infinity)
            }
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                RainDial(forecast: forecast, steps: entry.span.steps, now: entry.date, lineWidth: 5, gap: 0.6)
                    .padding(2)
                DialCentre(forecast: forecast, now: entry.date, location: place.location, compact: true)
            }
        default:
            ZStack {
                RainDial(forecast: forecast, steps: entry.span.steps, now: entry.date, lineWidth: 13, gap: 1.2)
                DialCentre(forecast: forecast, now: entry.date, location: place.location, compact: false)
                    .padding(22)
            }
            .overlay(alignment: .topLeading) {
                Image(systemName: place.isCurrent ? "location.fill" : "mappin")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .offset(x: -4, y: -4)
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(place.name))
        }
    }
}

/// The ring: one segment per step from now, clockwise from the top. Rain
/// below the threshold is drawn thin, rain that counts full width, in the
/// user's palette; in the lock screen's single colour, by brightness.
struct RainDial: View {
    let forecast: RainForecast
    let steps: Int
    let now: Date
    let lineWidth: CGFloat
    /// Degrees left empty between segments.
    let gap: Double

    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        Canvas { context, size in
            let radius = min(size.width, size.height) / 2 - lineWidth / 2
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let sweep = 360.0 / Double(steps)
            // The dial starts where the step now is in begins; the hand is a
            // little past twelve o'clock, by how far into that step now is.
            let first = forecast.observed
            let into = now.timeIntervalSince(forecast.date(at: first)) / TimeInterval(forecast.interval)
            let fullColour = renderingMode == .fullColor
            for offset in 0..<steps {
                let index = first + offset
                let dbz = forecast.value(at: index)
                let counts = dbz >= forecast.threshold
                let start = -90 + Double(offset) * sweep + gap / 2
                var arc = Path()
                arc.addArc(center: centre, radius: radius, startAngle: .degrees(start),
                           endAngle: .degrees(start + sweep - gap), clockwise: false)
                let colour: Color
                var width = lineWidth
                if dbz > 0, let rain = RadarColour.of(dbz: dbz) {
                    colour = fullColour ? rain : .primary.opacity(counts ? 1 : 0.55)
                    if !counts { width = lineWidth * 0.5 }
                } else {
                    colour = .primary.opacity(0.12)
                    width = lineWidth * 0.5
                }
                context.stroke(arc, with: .color(colour), style: StrokeStyle(lineWidth: width, lineCap: .butt))
            }
            // The hand: where now is on the dial.
            let angle = Angle.degrees(-90 + min(max(into, 0), 1) * sweep)
            let inner = radius - lineWidth / 2 - 2
            let outer = radius + lineWidth / 2 + 1
            var hand = Path()
            hand.move(to: CGPoint(x: centre.x + inner * cos(angle.radians), y: centre.y + inner * sin(angle.radians)))
            hand.addLine(to: CGPoint(x: centre.x + outer * cos(angle.radians), y: centre.y + outer * sin(angle.radians)))
            context.stroke(hand, with: .color(.primary), style: StrokeStyle(lineWidth: max(lineWidth / 4, 1.5), lineCap: .round))
            // A tick at each hour after now on a two-hour dial.
            if steps > 12 {
                let hour = Angle.degrees(-90 + 12 * sweep)
                let tick = CGPoint(x: centre.x + (radius - lineWidth) * cos(hour.radians),
                                   y: centre.y + (radius - lineWidth) * sin(hour.radians))
                context.fill(Path(ellipseIn: CGRect(x: tick.x - 1.5, y: tick.y - 1.5, width: 3, height: 3)),
                             with: .color(.secondary))
            }
        }
        .accessibilityHidden(true)
    }
}

/// The middle of the dial: the minutes until the rain, until it stops, or
/// that it stays dry, with the sun or the moon.
private struct DialCentre: View {
    let forecast: RainForecast
    let now: Date
    let location: CLLocation?
    let compact: Bool

    var body: some View {
        let status = RainStatus(forecast: forecast)
        VStack(spacing: compact ? 0 : 1) {
            switch forecast.phase {
            case .approaching(let arrival, _):
                if !compact { symbol(status) }
                minutes(until: arrival)
                Text(compact ? "widget_min" : "widget_until_rain")
                    .font(.system(size: compact ? 9 : 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            case .raining(let end):
                symbol(status)
                if let end {
                    if compact {
                        minutes(until: end)
                    } else {
                        Text(String(localized: "widget_ends \(end.formatted(date: .omitted, time: .shortened))"))
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .minimumScaleFactor(0.7)
                    }
                } else if !compact {
                    Text(status.intensity).font(.system(size: 13, weight: .semibold))
                }
            case .dry:
                Image(systemName: Daylight.isDay(at: location, date: now) ? "sun.max.fill" : "moon.stars.fill")
                    .font(.system(size: compact ? 18 : 30))
                    .symbolRenderingMode(.multicolor)
                    .widgetAccentable()
                if !compact {
                    Text("widget_dry").font(.system(size: 13, weight: .semibold))
                }
            }
        }
        .lineLimit(1)
        .multilineTextAlignment(.center)
    }

    private func symbol(_ status: RainStatus) -> some View {
        Image(systemName: status.symbol)
            .font(.system(size: compact ? 12 : 18))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.primary, status.colour)
            .widgetAccentable()
    }

    private func minutes(until date: Date) -> some View {
        let minutes = max(Int((date.timeIntervalSince(now) / 60).rounded(.up)), 0)
        return Text(minutes >= 100 ? String(format: "%d:%02d", minutes / 60, minutes % 60) : "\(minutes)")
            .font(.system(size: compact ? 20 : 38, weight: .bold, design: .rounded).monospacedDigit())
            .minimumScaleFactor(0.6)
            .contentTransition(.numericText(countsDown: true))
    }
}

/// Whether the sun is up, near enough for an icon: NOAA's simple solar
/// position, with no refraction or equation of time.
enum Daylight {
    static func isDay(at location: CLLocation?, date: Date) -> Bool {
        guard let coordinate = location?.coordinate else {
            let hour = Calendar.current.component(.hour, from: date)
            return (7..<19).contains(hour)
        }
        let day = Double(Calendar(identifier: .gregorian).ordinality(of: .day, in: .year, for: date) ?? 1)
        let declination = -23.44 * cos(2 * .pi / 365 * (day + 10)) * .pi / 180
        let utcHours = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 86400) / 3600
        let hourAngle = (utcHours + coordinate.longitude / 15 - 12) * 15 * .pi / 180
        let latitude = coordinate.latitude * .pi / 180
        let elevation = asin(sin(latitude) * sin(declination) + cos(latitude) * cos(declination) * cos(hourAngle))
        return elevation > -0.833 * .pi / 180
    }
}
