import CoreLocation
import SwiftUI
import WidgetKit

/// What the rain does next at a place, in the words the widgets share.
struct RainStatus {
    let forecast: RainForecast

    var intensity: String {
        let names = ["Drizzle", "Light rain", "Rain", "Intense Rain", "Hail"]
        return String(localized: String.LocalizationValue(names[RainForecast.intensity(dbz: forecast.peak)]))
    }

    /// "Rain in 12 min", "Rain until 14:20", "Dry until 14:55". The
    /// countdown counts itself between entries.
    var line: Text {
        switch forecast.phase {
        case .approaching(let arrival, _):
            return Text(intensity) + Text(" ")
                + Text(.currentDate, format: .reference(to: arrival, allowedFields: [.hour, .minute]))
        case .raining(let end):
            guard let end else { return Text(String(localized: "rain_continues \(intensity)")) }
            return Text(String(localized: "rain_until \(intensity) \(end.formatted(date: .omitted, time: .shortened))"))
        case .dry:
            return Text(String(localized: "widget_dry_until \(forecast.end.formatted(date: .omitted, time: .shortened))"))
        }
    }

    var symbol: String {
        switch forecast.phase {
        case .dry: return "checkmark.circle.fill"
        case .approaching, .raining:
            return forecast.peak >= RainForecast.thresholds[4] ? "cloud.hail.fill"
                : forecast.peak >= RainForecast.thresholds[3] ? "cloud.heavyrain.fill" : "cloud.rain.fill"
        }
    }

    /// The colour of the heaviest rain ahead, in the user's palette.
    var colour: Color {
        guard forecast.phase != .dry else { return .green }
        return RadarColour.of(dbz: max(forecast.peak, forecast.threshold)) ?? .blue
    }
}

enum RadarColour {
    static func of(dbz: Double) -> Color? {
        let palette = WidgetStore.defaults?.string(forKey: "radarColorMapping") ?? "classic"
        return RadarPalette.colour(dbz: dbz, palette: palette).map { Color(red: $0.red, green: $0.green, blue: $0.blue) }
    }
}

/// The place's name, with an arrow for the user's own location.
struct PlaceLabel: View {
    let place: PlaceRain
    var font: Font = .caption2.weight(.semibold)

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: place.isCurrent ? "location.fill" : "mappin.and.ellipse")
                .imageScale(.small)
            Text(place.name)
                .lineLimit(1)
        }
        .font(font)
    }
}

/// A label on the map: white on a dark capsule, readable on any radar.
struct MapChip<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.black.opacity(0.55), in: Capsule())
    }
}

/// The radar map filling its frame, with the place marked where it is: the
/// preview service centres the map on a grid point near it, not on it.
struct RadarMapImage: View {
    let snapshot: MapSnapshot?
    let isCurrent: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if let snapshot {
                    Image(uiImage: snapshot.image)
                        .resizable()
                        .widgetAccentedRenderingMode(.fullColor)
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                    marker
                        .position(position(in: geometry.size, snapshot: snapshot))
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "map")
                                .font(.system(size: min(geometry.size.width, geometry.size.height) * 0.2))
                                .foregroundStyle(.tertiary)
                        }
                }
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var marker: some View {
        if isCurrent {
            Circle()
                .fill(.blue)
                .stroke(.white, lineWidth: 2)
                .frame(width: 11, height: 11)
                .shadow(color: .black.opacity(0.3), radius: 2)
        } else {
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 16))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .red)
                .shadow(color: .black.opacity(0.3), radius: 2)
        }
    }

    /// The image fills the frame from its centre, so a point on the card
    /// moves from the centre by its offset on the card times the fill scale.
    private func position(in size: CGSize, snapshot: MapSnapshot) -> CGPoint {
        let card = snapshot.card.size
        let scale = max(size.width / card.width, size.height / card.height)
        let fraction = snapshot.card.position(of: snapshot.location)
        return CGPoint(x: size.width / 2 + (fraction.x - 0.5) * card.width * scale,
                       y: size.height / 2 + (fraction.y - 0.5) * card.height * scale)
    }
}

/// What a widget shows instead of rain it cannot know.
struct ProblemView: View {
    let problem: WidgetProblem
    var compact = false

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: problem == .noLocation ? "location.slash" : "icloud.slash")
                .font(compact ? .body : .title2)
                .foregroundStyle(.secondary)
            if !compact {
                Text(problem == .noLocation ? "widget_no_location" : "widget_no_data")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The refresh button and the time of the forecast it would replace.
struct RefreshButton: View {
    let fetched: Date?

    var body: some View {
        Button(intent: RefreshRainIntent()) {
            HStack(spacing: 3) {
                if let fetched {
                    Text(fetched, style: .time)
                }
                Image(systemName: "arrow.clockwise")
            }
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Refresh Rain"))
    }
}

extension View {
    /// The widget's background: the system's, which tinted and clear home
    /// screens replace with their own.
    func rainBackground() -> some View {
        containerBackground(for: .widget) { Color(.systemBackground) }
    }
}
