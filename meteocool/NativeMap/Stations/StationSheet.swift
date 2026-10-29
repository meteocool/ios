//
//  StationSheet.swift
//  meteocool
//
//  A weather station tapped on the map (core's `StationDetails.svelte` and
//  `StationHistory.svelte`): its name, state, height and when it measured;
//  what it measured over the last day, three or seven, as small multiples
//  over one clock; and the values of its newest answer.
//

import Charts
import SwiftUI

struct StationSheet: View {
    let station: ObservedStation
    let endpoints: NativeMapEndpoints
    let fetch: (URL, @escaping @MainActor (Data?, Int?) -> Void) -> Void
    let close: () -> Void

    @State private var window = StationHistory.Window.day
    @State private var rows: [ObservationRow]?
    @State private var failed = false

    /// The rows the sheet can show, in the control's order; each only when the station has it.
    private static let latest: [(key: String, label: String, read: (Double) -> String)] = [
        ("wind_speed_m_s", "stations.parameter.wind", speed),
        ("wind_direction_deg", "stations.parameter.wind_direction", { "\(Int($0.rounded()))°" }),
        ("gust_m_s", "stations.parameter.gusts", speed),
        ("gust_direction_deg", "stations.parameter.gust_direction", { "\(Int($0.rounded()))°" }),
        ("temperature_c", "stations.parameter.temperature", { StationRules.formatValue(.temperature, $0, language: CoreStrings.language) + " °C" }),
        ("precipitation_mm", "stations.parameter.precipitation", { StationRules.formatValue(.precipitation, $0, language: CoreStrings.language) + " mm" }),
        ("humidity_pct", "stations.parameter.humidity", { StationRules.formatValue(.humidity, $0, language: CoreStrings.language) + " %" }),
        ("pressure_msl_hpa", "stations.parameter.pressure", { StationRules.formatValue(.pressure, $0, language: CoreStrings.language) + " hPa" }),
    ]

    /// m/s as measured, and the knots a barb is drawn in.
    nonisolated private static func speed(_ value: Double) -> String {
        StationRules.formatValue(.wind, value, language: CoreStrings.language) + " m/s · \(Int(WindBarb.toKnots(value).rounded())) kt"
    }

    private var place: String {
        let time = StationHistory.seconds(station.observedAt).map {
            Date(timeIntervalSince1970: $0).formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute())
        } ?? ""
        return CoreStrings.t("stations.sheet.place", ["state": station.state, "height": Int(station.elevationM.rounded()), "time": time])
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker(CoreStrings.t("stations.history.window.group"), selection: $window) {
                        ForEach(StationHistory.Window.allCases, id: \.self) { window in
                            Text(CoreStrings.t("stations.history.window.\(window.rawValue)")).tag(window)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("nativeMap.station.window")
                    history
                } header: {
                    Text(CoreStrings.t("stations.history.title"))
                }
                Section(CoreStrings.t("stations.sheet.latest")) {
                    let shown = Self.latest.filter { station.values[$0.key] != nil }
                    if shown.isEmpty {
                        Text(CoreStrings.t("stations.sheet.none")).foregroundStyle(.secondary)
                    }
                    ForEach(shown, id: \.key) { row in
                        LabeledContent(CoreStrings.t(row.label), value: row.read(station.values[row.key]!))
                            .monospacedDigit()
                    }
                }
                Section {
                    EmptyView()
                } footer: {
                    Text(CoreStrings.t("stations.sheet.source"))
                }
            }
            .navigationTitle(station.name)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                Text(place)
                    .scaledFont(13, relativeTo: .footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 6)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: close) { Image(systemName: "xmark") }
                        .accessibilityLabel(CoreStrings.t("close"))
                        .accessibilityIdentifier("nativeMap.station.close")
                }
            }
        }
        .task(id: window) { load() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nativeMap.station.sheet")
    }

    @ViewBuilder
    private var history: some View {
        if let rows {
            let panels = StationHistory.panels(rows)
            if panels.isEmpty {
                Text(CoreStrings.t("stations.history.none")).foregroundStyle(.secondary)
            } else {
                let now = Date().timeIntervalSince1970 * 1000
                let from = StationHistory.windowStart(window, now: now)
                ForEach(panels, id: \.key) { panel in
                    StationPanelView(panel: panel, from: from, to: now)
                }
            }
        } else if failed {
            Text(CoreStrings.t("stations.history.none")).foregroundStyle(.secondary)
        } else {
            ProgressView().frame(maxWidth: .infinity, minHeight: 80)
        }
    }

    private func load() {
        rows = nil
        failed = false
        // Up to the next minute: the service takes at most seven days, and a
        // start rounded down to its second would be a moment over them.
        let start = StationHistory.windowStart(window, now: Date().timeIntervalSince1970 * 1000) / 1000
        let since = Date(timeIntervalSince1970: (start / 60).rounded(.up) * 60)
        var components = URLComponents(url: endpoints.data.appendingPathComponent("stations/\(station.id)/observations"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "since", value: ISO8601DateFormatter().string(from: since))]
        let asked = window
        fetch(components.url!) { data, _ in
            guard asked == window else { return }
            if let decoded = data.flatMap(ObservationRow.decode) { rows = decoded } else { failed = true }
        }
    }
}

/// One quantity over the window: its name with what summarises it, and its
/// lines, bars or dots (core's panel).
private struct StationPanelView: View {
    let panel: StationHistory.Panel
    let from: Double
    let to: Double

    private var title: String { CoreStrings.t("stations.history.panel.\(panel.key)") }

    private var summary: String {
        panel.stats.map { stat in
            let value = StationRules.formatNumber(stat.value, digits: panel.key == "sunshine" ? 1 : panel.digits, language: CoreStrings.language)
            let unit = panel.key == "sunshine" ? "h" : panel.unit
            return "\(CoreStrings.t("stations.history.stat.\(stat.key)")) \(stat.key == "change" && stat.value > 0 ? "+" : "")\(value) \(unit)"
        }
        .joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).scaledFont(13, weight: .semibold, relativeTo: .footnote)
                Spacer()
                Text(panel.unit).scaledFont(11, relativeTo: .caption2).foregroundStyle(.tertiary)
            }
            if !summary.isEmpty {
                Text(summary).scaledFont(12, relativeTo: .caption, digits: true).foregroundStyle(.secondary)
            }
            chart.frame(height: 90)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(CoreStrings.t("stations.history.aria", ["title": title, "unit": panel.unit]))
        .accessibilityValue(summary)
        .accessibilityIdentifier("nativeMap.station.panel.\(panel.key)")
    }

    /// One mark to plot: when, how much, how it is drawn, and which run of
    /// a line it belongs to.
    private struct Plot: Identifiable {
        let id: Int
        let date: Date
        let value: Double
        let style: StationHistory.Style
        let run: String
    }

    private var plots: [Plot] {
        var plots: [Plot] = []
        for series in panel.series {
            switch series.style {
            case .bars:
                for point in series.points where (point.v ?? 0) > 0 {
                    plots.append(Plot(id: plots.count, date: Date(timeIntervalSince1970: point.t / 1000), value: point.v!, style: .bars, run: series.key))
                }
            case .dots:
                for point in series.points where point.v != nil {
                    plots.append(Plot(id: plots.count, date: Date(timeIntervalSince1970: point.t / 1000), value: point.v!, style: .dots, run: series.key))
                }
            case .main, .context:
                for (index, run) in StationHistory.runs(series.points).enumerated() {
                    for point in run {
                        plots.append(Plot(id: plots.count, date: Date(timeIntervalSince1970: point.t / 1000), value: point.v ?? 0,
                                          style: series.style, run: "\(series.key)-\(index)"))
                    }
                }
            }
        }
        return plots
    }

    @ChartContentBuilder
    private func mark(_ plot: Plot) -> some ChartContent {
        switch plot.style {
        case .bars:
            BarMark(x: .value("time", plot.date), y: .value("value", plot.value), width: .fixed(2))
                .foregroundStyle(panel.key == "sunshine" ? Color.yellow : Color.blue)
        case .dots:
            PointMark(x: .value("time", plot.date), y: .value("value", plot.value))
                .symbolSize(6)
                .foregroundStyle(Color.accentColor)
        case .main:
            LineMark(x: .value("time", plot.date), y: .value("value", plot.value), series: .value("run", plot.run))
                .foregroundStyle(colour)
                .lineStyle(StrokeStyle(lineWidth: 2))
        case .context:
            LineMark(x: .value("time", plot.date), y: .value("value", plot.value), series: .value("run", plot.run))
                .foregroundStyle(Color.secondary.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1.2))
        }
    }

    private var chart: some View {
        Chart(plots) { plot in mark(plot) }
        .chartXScale(domain: Date(timeIntervalSince1970: from / 1000) ... Date(timeIntervalSince1970: to / 1000))
        .chartYScale(domain: yDomain)
        .chartYAxis {
            AxisMarks(position: .leading, values: panel.fixed.map { AxisMarkValues.stride(by: $0.ticks.count > 1 ? $0.ticks[1] - $0.ticks[0] : $0.max) } ?? .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if panel.key == "direction", let degrees = value.as(Double.self) {
                        Text(StationHistory.directionTicks[degrees].map { CoreStrings.t("storm.compass.\($0)") } ?? "")
                    } else if let number = value.as(Double.self) {
                        // A decimal where the scale is small: 0.5 mm is not "1".
                        Text(StationRules.formatNumber(number, digits: yDomain.upperBound - yDomain.lowerBound <= 5 ? 1 : 0,
                                                       language: CoreStrings.language))
                    }
                }
            }
        }
    }

    private var colour: Color {
        switch panel.key {
        case "temperature": return .orange
        case "humidity": return .teal
        case "pressure": return .purple
        default: return .accentColor
        }
    }

    /// The scale: fixed where the panel says, else the values', the bottom
    /// at zero with a floor for amounts that are mostly nothing.
    private var yDomain: ClosedRange<Double> {
        if let fixed = panel.fixed { return fixed.min ... fixed.max }
        let values = panel.series.flatMap { $0.points.compactMap(\.v) }
        guard var low = values.min(), var high = values.max() else { return 0 ... 1 }
        if let floor = panel.floor {
            low = 0
            high = max(high, floor)
        }
        if high - low < 1 { high = low + 1 }
        return low ... high
    }
}

/// The stations on or off: a pill in the tray beside the storm key's, pressed while they are drawn.
struct StationTogglePill: View {
    let on: Bool
    let theme: ChromeTheme
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 5) {
                Image(systemName: "wind").scaledFont(11, weight: .semibold, relativeTo: .caption2)
                Text(CoreStrings.t("stations.pill"))
            }
            .scaledFont(11, weight: .semibold, relativeTo: .caption2)
            .foregroundStyle(on ? Color.white : theme.text)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(on ? theme.accent : theme.tint, in: Capsule())
            .hitTarget()
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(CoreStrings.t("stations.toggle"))
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("nativeMap.stations.pill")
    }
}

/// Which parameter the stations show, and when what is on the map was
/// measured (core's `StationPicker`): a glass card over the player while they are on.
struct StationPicker: View {
    @ObservedObject var model: NativeMapModel
    @ObservedObject var state: StationState

    var body: some View {
        let theme = ChromeTheme(dark: model.isDark)
        VStack(alignment: .leading, spacing: 6) {
            Picker(CoreStrings.t("stations.choice.group"), selection: $state.choice) {
                ForEach(StationChoice.allCases, id: \.self) { choice in
                    Text(CoreStrings.t("stations.choice.\(choice.rawValue)")).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("nativeMap.stations.choice")
            Text(status)
                .scaledFont(11, weight: .medium, relativeTo: .caption2, digits: true)
                .foregroundStyle(theme.text2)
                .padding(.leading, 4)
                .accessibilityIdentifier("nativeMap.stations.status")
        }
        .padding(10)
        .chromeGlass(theme, in: RoundedRectangle(cornerRadius: ChromeTheme.trayRadius, style: .continuous), strong: true)
        .environment(\.colorScheme, theme.colorScheme)
        .padding(.horizontal, ChromeTheme.gutter)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nativeMap.stations.picker")
    }

    private var status: String {
        guard state.answered else { return " " }
        guard let at = state.observedAt else { return CoreStrings.t("stations.none") }
        return CoreStrings.t("stations.observed", ["time": at.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute())])
    }
}
