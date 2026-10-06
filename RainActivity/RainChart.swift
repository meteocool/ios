import SwiftUI

/// The bar chart under the web map (core's `Timeline.svelte`), drawn natively:
/// one bar per step in the radar palette, past steps shaded, forecast bars
/// lighter, a dashed line at now. The height is linear in dBZ with 45 dBZ
/// as the lowest full scale, as in core.
struct RainChart: View {
    let forecast: RainForecast
    /// Show at most this many steps from the start, all if nil.
    var steps: Int? = nil
    var axis = true

    /// Past steps the activity shows: half an hour.
    static let pastSteps = 6

    static var palette: String {
        UserDefaults(suiteName: "group.org.frcy.app.meteocool")?.string(forKey: "radarColorMapping") ?? "classic"
    }

    var body: some View {
        let count = min(steps ?? forecast.dbz.count, forecast.dbz.count)
        let palette = Self.palette
        let ceiling = max(45, (0..<count).map(forecast.value(at:)).max() ?? 0)
        let nowEdge = forecast.observed
        VStack(spacing: 2) {
            Canvas { context, size in
                guard count > 0 else { return }
                let slot = size.width / CGFloat(count)
                let past = CGRect(x: 0, y: 0, width: slot * CGFloat(nowEdge), height: size.height)
                // Without the axis (the Dynamic Island) only the bars are drawn.
                if axis { context.fill(Path(past), with: .color(.primary.opacity(0.06))) }
                for index in 0..<count {
                    let x = slot * CGFloat(index)
                    let tick = CGRect(x: x + slot / 2 - 0.75, y: size.height - 4, width: 1.5, height: 4)
                    if axis { context.fill(Path(tick), with: .color(.primary.opacity(index >= nowEdge ? 0.18 : 0.28))) }
                    let dbz = forecast.value(at: index)
                    guard dbz > 0, let rgb = RadarPalette.colour(dbz: dbz, palette: palette) else { continue }
                    let height = max(2, dbz / ceiling * (size.height - 2))
                    let bar = CGRect(x: x + 0.5, y: size.height - height, width: max(1, slot - 1.5), height: height)
                    context.fill(Path(roundedRect: bar, cornerRadius: min(1.5, slot / 4)),
                                 with: .color(Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
                                    .opacity(index < nowEdge ? 1 : 0.72)))
                }
                if axis && nowEdge > 0 && nowEdge < count {
                    var line = Path()
                    line.move(to: CGPoint(x: past.maxX, y: 0))
                    line.addLine(to: CGPoint(x: past.maxX, y: size.height))
                    context.stroke(line, with: .color(.primary.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                }
            }
            if axis {
                AxisLabels(forecast: forecast, count: count)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("rain_chart"))
    }
}

/// "Now" under the now line and a label every full hour after it.
private struct AxisLabels: View {
    let forecast: RainForecast
    let count: Int

    var body: some View {
        GeometryReader { geometry in
            let slot = geometry.size.width / CGFloat(max(count, 1))
            let perHour = 3600 / max(forecast.interval, 1)
            ForEach(Array(stride(from: forecast.observed, to: count + 1, by: max(perHour, 1)).enumerated()), id: \.offset) { offset, edge in
                let label = offset == 0 ? String(localized: "rain_now") : String(localized: "rain_hours \(offset)")
                Text(label)
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .position(x: min(max(slot * CGFloat(edge), 14), geometry.size.width - 14), y: 6)
            }
        }
        .frame(height: 12)
    }
}
