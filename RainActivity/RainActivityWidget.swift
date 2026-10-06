import ActivityKit
import SwiftUI
import WidgetKit

/// The rain Live Activity: the radar image beside the bar chart on the lock
/// screen, and a small chart in the Dynamic Island.
struct RainActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RainActivityAttributes.self) { context in
            LockScreenView(forecast: context.state, stale: context.isStale)
                .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            let forecast = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    RadarThumbnail(side: 56)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Headline(forecast: forecast, stale: context.isStale)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    RainChart(forecast: forecast.trimmed(past: RainChart.pastSteps))
                        .frame(height: 52)
                        .padding(.horizontal, 4)
                }
            } compactLeading: {
                RainSymbol(forecast: forecast)
            } compactTrailing: {
                RainChart(forecast: forecast.trimmed(past: 0), steps: 12, axis: false)
                    .frame(width: 40, height: 20)
            } minimal: {
                RainSymbol(forecast: forecast)
            }
        }
    }
}

private struct LockScreenView: View {
    let forecast: RainForecast
    let stale: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RadarThumbnail(side: 84)
            VStack(alignment: .leading, spacing: 6) {
                Headline(forecast: forecast, stale: stale)
                RainChart(forecast: forecast.trimmed(past: RainChart.pastSteps))
                    .frame(height: 52)
            }
        }
        .padding(14)
    }
}

/// What the rain does next, in one or two lines. The times count themselves:
/// "in 12 minutes" ticks down between updates without the app.
private struct Headline: View {
    let forecast: RainForecast
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            title
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var intensity: String {
        let names = ["Drizzle", "Light rain", "Rain", "Intense Rain", "Hail"]
        return String(localized: String.LocalizationValue(names[RainForecast.intensity(dbz: forecast.peak)]))
    }

    private var title: Text {
        switch forecast.phase {
        case .approaching(let arrival, _):
            return Text(intensity) + Text(" ")
                + Text(.currentDate, format: .reference(to: arrival, allowedFields: [.hour, .minute]))
        case .raining(let end):
            guard let end else { return Text(String(localized: "rain_continues \(intensity)")) }
            return Text(String(localized: "rain_until \(intensity) \(end.formatted(date: .omitted, time: .shortened))"))
        case .dry:
            return Text(String(localized: "rain_over"))
        }
    }

    private var detail: String? {
        if stale { return String(localized: "rain_stale") }
        var parts: [String] = []
        if case .approaching(let arrival, let end) = forecast.phase {
            if let end {
                parts.append(String(localized: "rain_lasting \(max(Int(end.timeIntervalSince(arrival) / 60), 5))"))
            } else {
                parts.append(String(localized: "rain_open_ended"))
            }
        }
        if UserDefaults(suiteName: "group.org.frcy.app.meteocool")?.bool(forKey: "withDBZ") == true, forecast.peak > 0 {
            parts.append(String(localized: "rain_peak_dbz \(Int(forecast.peak.rounded()))"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The last radar image the app saved, centred on the user, with its time.
private struct RadarThumbnail: View {
    let side: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: side * 0.16, style: .continuous)
        ZStack(alignment: .bottomTrailing) {
            if let radar = RadarImageStore.load() {
                Image(uiImage: radar.image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: side, height: side)
                    .overlay {
                        // The image is centred on the location the forecast is for.
                        Circle()
                            .fill(.blue)
                            .stroke(.white, lineWidth: 2)
                            .frame(width: side * 0.11, height: side * 0.11)
                    }
                Text(radar.saved, style: .time)
                    .font(.system(size: max(side * 0.12, 9), weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(4)
            } else {
                shape.fill(.quaternary)
                    .frame(width: side, height: side)
                    .overlay {
                        Image(systemName: "cloud.rain.fill")
                            .font(.system(size: side * 0.36))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .accessibilityHidden(true)
    }
}

private struct RainSymbol: View {
    let forecast: RainForecast

    var body: some View {
        let palette = RainChart.palette
        let colour = RadarPalette.colour(dbz: max(forecast.peak, forecast.threshold), palette: palette)
        Image(systemName: forecast.peak >= RainForecast.thresholds[4] ? "cloud.hail.fill" : "cloud.rain.fill")
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, colour.map { Color(red: $0.red, green: $0.green, blue: $0.blue) } ?? .blue)
    }
}
