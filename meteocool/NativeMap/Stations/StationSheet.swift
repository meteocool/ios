//
//  StationSheet.swift
//  meteocool
//
//  A weather station tapped on the map (core's `StationDetails.svelte` and
//  `StationHistory.svelte`): its name, state, height and when it measured;
//  its newest values as the row of facts a place card carries; and what it
//  measured over the last day, three or seven, as small multiples over one
//  clock, laid out as Health and Weather lay out theirs.
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
    @State private var span: ClosedRange<Double>?
    @State private var failed = false
    /// The row the scrubber's line is on, down every panel at once.
    @State private var scrubbed: Int?

    /// A fact: its value, and a second way of saying it under it.
    struct Reading {
        let value: String
        var also: String?
    }

    /// The facts the sheet can show, in the control's order; each only when the station has it.
    private static let latest: [(key: String, label: String, read: (Double) -> Reading)] = [
        ("wind_speed_m_s", "stations.parameter.wind", speed),
        ("wind_direction_deg", "stations.parameter.wind_direction", heading),
        ("gust_m_s", "stations.parameter.gusts", speed),
        ("gust_direction_deg", "stations.parameter.gust_direction", heading),
        ("temperature_c", "stations.parameter.temperature", { Reading(value: StationRules.formatValue(.temperature, $0, language: CoreStrings.language) + " °C") }),
        ("precipitation_mm", "stations.parameter.precipitation", { Reading(value: StationRules.formatValue(.precipitation, $0, language: CoreStrings.language) + " mm") }),
        ("humidity_pct", "stations.parameter.humidity", { Reading(value: StationRules.formatValue(.humidity, $0, language: CoreStrings.language) + " %") }),
        ("pressure_msl_hpa", "stations.parameter.pressure", { Reading(value: StationRules.formatValue(.pressure, $0, language: CoreStrings.language) + " hPa") }),
    ]

    /// m/s as measured, and under it the knots a barb is drawn in.
    nonisolated private static func speed(_ value: Double) -> Reading {
        Reading(value: StationRules.formatValue(.wind, value, language: CoreStrings.language) + " m/s",
                also: "\(Int(WindBarb.toKnots(value).rounded())) kt")
    }

    /// Where it comes from as a compass point, its degrees under it.
    nonisolated private static func heading(_ value: Double) -> Reading {
        Reading(value: CoreStrings.t("storm.compass.\(StationHistory.compassPoint(value))"), also: "\(Int(value.rounded()))°")
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
                let facts = Self.latest.filter { station.values[$0.key] != nil }
                if !facts.isEmpty {
                    Section {
                        factsRow(facts)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }
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

    /// What it measures now, at a glance: label over value, the second way
    /// of saying it under that, divided as a place card's facts are.
    private func factsRow(_ facts: [(key: String, label: String, read: (Double) -> Reading)]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(facts.enumerated()), id: \.element.key) { index, fact in
                    let reading = fact.read(station.values[fact.key]!)
                    if index > 0 { Divider().padding(.vertical, 4) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(CoreStrings.t(fact.label))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(reading.value).font(.body.weight(.semibold)).monospacedDigit()
                        if let also = reading.also {
                            Text(also).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .padding(.horizontal, 14)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
        }
        .scrollClipDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(CoreStrings.t("stations.sheet.latest"))
        .accessibilityIdentifier("nativeMap.station.latest")
    }

    @ViewBuilder
    private var history: some View {
        if let rows, let span {
            let panels = StationHistory.panels(rows)
            if panels.isEmpty {
                Text(CoreStrings.t("stations.history.none")).foregroundStyle(.secondary)
            } else {
                let times = rows.map(\.t)
                ForEach(panels, id: \.key) { panel in
                    StationPanelView(panel: panel, span: span, times: times, window: window, scrubbed: $scrubbed)
                }
            }
        } else if failed {
            Text(CoreStrings.t("stations.history.none")).foregroundStyle(.secondary)
        } else {
            ProgressView().frame(maxWidth: .infinity, minHeight: 120)
        }
    }

    private func load() {
        rows = nil
        failed = false
        scrubbed = nil
        let now = Date().timeIntervalSince1970 * 1000
        let since = Date(timeIntervalSince1970: StationHistory.askSince(window, now: now) / 1000)
        var components = URLComponents(url: endpoints.data.appendingPathComponent("stations/\(station.id)/observations"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "since", value: ISO8601DateFormatter().string(from: since))]
        let asked = window
        fetch(components.url!) { data, _ in
            guard asked == window else { return }
            if let decoded = data.flatMap(ObservationRow.decode) {
                span = StationHistory.windowStart(asked, now: now) ... now
                rows = decoded
            } else {
                failed = true
            }
        }
    }
}

/// One quantity over the window (core's panel): its name; the figure it is
/// read for, large, with what sums the period up beside it; and a plot the
/// sheet's width with its scale on the trailing edge. While the scrubber's
/// line is out, the figure is the line's, in the panel's ink.
private struct StationPanelView: View {
    let panel: StationHistory.Panel
    let span: ClosedRange<Double>
    /// Every row's time, which the panels' points share.
    let times: [Double]
    let window: StationHistory.Window
    @Binding var scrubbed: Int?

    private var title: String { CoreStrings.t("stations.history.panel.\(panel.key)") }
    private var language: String { CoreStrings.language }
    private let compass = { (point: String) in CoreStrings.t("storm.compass.\(point)") }

    private var resting: StationHistory.Figure? { StationHistory.figure(panel, language: language, compass: compass) }

    private var summary: String {
        StationHistory.summary(panel, figure: resting, language: language) { CoreStrings.t("stations.history.stat.\($0)") }
    }

    /// The line's figure, and beside it when that was and the context's value then.
    private var reading: (figure: StationHistory.Figure, line: String)? {
        guard let row = scrubbed, times.indices.contains(row) else { return nil }
        let figure = StationHistory.value(panel, at: row).map { StationHistory.reading(panel, $0, language: language, compass: compass) }
            ?? StationHistory.Figure(value: "–", unit: "")
        var parts = [moment(times[row])]
        for other in panel.series where other.style == .context {
            let value = other.points.indices.contains(row) ? other.points[row].v : nil
            parts.append("\(CoreStrings.t("stations.history.series.\(other.key)")) "
                         + (value.map { StationHistory.unitted(StationRules.formatNumber($0, digits: panel.digits, language: language), panel.unit) } ?? "–"))
        }
        return (figure, parts.joined(separator: " · "))
    }

    /// The clock, and the weekday over more than a day.
    private func moment(_ t: Double) -> String {
        let date = Date(timeIntervalSince1970: t / 1000)
        let clock = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute()
        return window == .day ? date.formatted(clock) : date.formatted(clock.weekday(.abbreviated))
    }

    private var ink: Color {
        switch panel.key {
        case "temperature": return .red
        case "sunshine": return .yellow
        case "wind": return .orange
        case "humidity": return .teal
        default: return .accentColor
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.footnote.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                // The period's figure and the line's laid over each other, the
                // one not in use hidden, so the chart never moves under them.
                ZStack(alignment: .topLeading) {
                    caption(resting, summary.isEmpty ? " " : summary, ink: .primary).opacity(reading == nil ? 1 : 0)
                    if let reading { caption(reading.figure, reading.line, ink: ink) }
                }
            }
            chart.frame(height: 114)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(CoreStrings.t("stations.history.aria", ["title": title, "unit": panel.unit]))
        .accessibilityValue([resting.map { StationHistory.unitted($0.value, $0.unit) }, summary.isEmpty ? nil : summary]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier("nativeMap.station.panel.\(panel.key)")
    }

    private func caption(_ figure: StationHistory.Figure?, _ summary: String, ink: Color) -> some View {
        // The summary beside the figure on its baseline, or under it where a
        // long language has no room for both.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) { figureText(figure, ink: ink); summaryText(summary).lineLimit(1) }
            VStack(alignment: .leading, spacing: 0) { figureText(figure, ink: ink); summaryText(summary) }
        }
    }

    @ViewBuilder
    private func figureText(_ figure: StationHistory.Figure?, ink: Color) -> some View {
        if let figure {
            (Text(figure.value).font(.title2.weight(.semibold)).foregroundColor(ink)
             + Text(figure.unit.isEmpty ? "" : " " + figure.unit).font(.footnote.weight(.medium)).foregroundColor(.secondary))
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    private func summaryText(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
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
                .foregroundStyle(ink)
        case .dots:
            PointMark(x: .value("time", plot.date), y: .value("value", plot.value))
                .symbolSize(6)
                .foregroundStyle(Color.primary.opacity(0.7))
        case .main:
            LineMark(x: .value("time", plot.date), y: .value("value", plot.value), series: .value("run", plot.run))
                .foregroundStyle(ink)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        case .context:
            LineMark(x: .value("time", plot.date), y: .value("value", plot.value), series: .value("run", plot.run))
                .foregroundStyle(Color.primary.opacity(0.45))
                .lineStyle(StrokeStyle(lineWidth: 1.25))
        }
    }

    private var chart: some View {
        Chart {
            ForEach(plots) { plot in mark(plot) }
            if let row = scrubbed, times.indices.contains(row) {
                let date = Date(timeIntervalSince1970: times[row] / 1000)
                RuleMark(x: .value("time", date)).foregroundStyle(Color.primary.opacity(0.7)).lineStyle(StrokeStyle(lineWidth: 1))
                ForEach(panel.series.filter { $0.style != .bars }, id: \.key) { series in
                    if series.points.indices.contains(row), let value = series.points[row].v {
                        PointMark(x: .value("time", date), y: .value("value", value))
                            .symbolSize(36)
                            .foregroundStyle(series.style == .context ? Color.primary : ink)
                    }
                }
            } else if panel.key != "direction", let last = StationHistory.last(panel), let value = last.v {
                // The newest value, where the line ends.
                PointMark(x: .value("time", Date(timeIntervalSince1970: last.t / 1000)), y: .value("value", value))
                    .symbolSize(36)
                    .foregroundStyle(ink)
            }
        }
        .chartXScale(domain: Date(timeIntervalSince1970: span.lowerBound / 1000) ... Date(timeIntervalSince1970: span.upperBound / 1000))
        .chartYScale(domain: yDomain)
        .chartYAxis {
            AxisMarks(position: .trailing, values: panel.fixed.map { AxisMarkValues.stride(by: $0.ticks.count > 1 ? $0.ticks[1] - $0.ticks[0] : $0.max) } ?? .automatic(desiredCount: 3)) { value in
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
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    // Sideways drags move the line, which stays where it is let
                    // go; vertical ones are the sheet's. A tap puts it there,
                    // or takes it away when tapped on.
                    .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { drag in
                        guard abs(drag.translation.width) > abs(drag.translation.height) else { return }
                        scrub(to: drag.location.x, proxy, geometry)
                    })
                    .onTapGesture { location in
                        let before = scrubbed
                        scrub(to: location.x, proxy, geometry)
                        if let before, let now = scrubbed, abs(now - before) <= 2 { scrubbed = nil }
                    }
            }
        }
    }

    private func scrub(to x: CGFloat, _ proxy: ChartProxy, _ geometry: GeometryProxy) {
        guard let plot = proxy.plotFrame else { return }
        let origin = geometry[plot].origin.x
        guard let date: Date = proxy.value(atX: x - origin),
              let row = StationHistory.row(nearest: date.timeIntervalSince1970 * 1000, in: times), row != scrubbed else { return }
        scrubbed = row
        UISelectionFeedbackGenerator().selectionChanged()
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
    /// Switches the stations off, as an open radar's card closes it.
    var hide: () -> Void = {}
    /// Whether a tap swapped how long ago for the clock.
    @State private var showClock = false

    var body: some View {
        let theme = ChromeTheme(dark: model.isDark)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Picker(CoreStrings.t("stations.choice.group"), selection: $state.choice) {
                    ForEach(StationChoice.allCases, id: \.self) { choice in
                        Text(CoreStrings.t("stations.choice.\(choice.rawValue)")).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("nativeMap.stations.choice")
                // The way out, outside the parameters so it is always in reach.
                Button(action: hide) {
                    Image(systemName: "xmark")
                        .scaledFont(13, weight: .semibold, relativeTo: .footnote)
                        .foregroundStyle(theme.text3)
                        .frame(width: 30, height: 30)
                        .background(theme.tint, in: Circle())
                        .hitTarget()
                }
                .buttonStyle(PressScale())
                .accessibilityLabel(CoreStrings.t("stations.close"))
                .accessibilityIdentifier("nativeMap.stations.close")
            }
            // How long ago what is on the map was measured, counting up: the
            // question is how fresh it is. A tap swaps it for the clock.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Button { showClock.toggle() } label: {
                    Text(shown(now: context.date))
                        .scaledFont(12, weight: .semibold, relativeTo: .caption, digits: true)
                        .foregroundStyle(state.observedAt == nil ? theme.text2 : theme.accent)
                        .padding(.horizontal, 6)
                        .frame(minHeight: 24)
                        .contentShape(Capsule())
                }
                .buttonStyle(PressScale())
                .disabled(state.observedAt == nil)
                .accessibilityLabel(status(now: context.date))
                .accessibilityValue(shown(now: context.date))
                .accessibilityAddTraits(showClock ? .isSelected : [])
                .accessibilityIdentifier("nativeMap.stations.status")
            }
        }
        .padding(10)
        .chromeGlass(theme, in: RoundedRectangle(cornerRadius: ChromeTheme.trayRadius, style: .continuous), strong: true)
        .environment(\.colorScheme, theme.colorScheme)
        .padding(.horizontal, ChromeTheme.gutter)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nativeMap.stations.picker")
    }

    private var clock: String? {
        state.observedAt?.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute())
    }

    /// "12 min ago"; never "in 1 min" from a clock a little ahead of DWD's.
    private func age(now: Date) -> String? {
        guard let at = state.observedAt else { return nil }
        let minutes = max(0, now.timeIntervalSince(at) / 60)
        return CoreStrings.t("storm.ago", ["duration": StormRules.duration(minutes) { CoreStrings.t($0, $1) }])
    }

    private func shown(now: Date) -> String {
        guard state.answered else { return " " }
        guard state.observedAt != nil else { return CoreStrings.t("stations.none") }
        return (showClock ? clock : age(now: now)) ?? "–"
    }

    private func status(now: Date) -> String {
        guard state.answered else { return " " }
        guard let clock, let age = age(now: now) else { return CoreStrings.t("stations.none") }
        return CoreStrings.t("stations.observed", ["time": clock]) + ", " + age
    }
}
