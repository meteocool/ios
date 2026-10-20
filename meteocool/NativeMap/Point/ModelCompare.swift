//
//  ModelCompare.swift
//  meteocool
//
//  The model comparison: 21 weather models from Open-Meteo, their spread
//  hour by hour and their weighted days (core's `ModelCompare.svelte`,
//  `ModelSpread.svelte`, `lib/compare/*`).
//

import SwiftUI

/// Open-Meteo, asked as core asks it: the daily answer per panel, the hourly
/// per variable shared for ten minutes between the panel and the strip.
@MainActor
final class OpenMeteoClient {
    static let shared = OpenMeteoClient()

    private var hourlyCache: [String: (at: Date, series: OpenMeteo.HourlySeries)] = [:]
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    func forecast(latitude: Double, longitude: Double) async throws -> OpenMeteo.Forecast {
        let data = try await get(OpenMeteo.dailyURL(latitude: latitude, longitude: longitude))
        guard let forecast = OpenMeteo.forecast(data) else { throw OpenMeteo.Failure(message: "open-meteo: unreadable answer") }
        return forecast
    }

    func hourly(latitude: Double, longitude: Double, variable: String) async throws -> OpenMeteo.HourlySeries {
        let key = OpenMeteo.hourlyKey(latitude: latitude, longitude: longitude, variable: variable)
        if let cached = hourlyCache[key], Date().timeIntervalSince(cached.at) < OpenMeteo.hourlyTTL { return cached.series }
        let data = try await get(OpenMeteo.hourlyURL(latitude: latitude, longitude: longitude, variable: variable))
        guard let series = OpenMeteo.hourly(data, variable: variable) else { throw OpenMeteo.Failure(message: "open-meteo: unreadable answer") }
        hourlyCache[key] = (Date(), series)
        return series
    }

    private func get(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else { throw OpenMeteo.failure(status: status, body: data) }
        return data
    }
}

/// What a spread plots: hourly rainfall from 0 with a 6 mm soft ceiling, or
/// temperature scaled to the models (`RAINFALL`, `VARIABLES`).
struct SpreadSpec: Equatable {
    let variable: String
    let unit: String
    let suggestedMax: Double?

    static let rainfall = SpreadSpec(variable: "precipitation", unit: " mm", suggestedMax: 6)
    static let temperature = SpreadSpec(variable: "temperature_2m", unit: "°", suggestedMax: nil)
}

/// Every model as one recessive thicket, their range as a band, the median
/// on top in the accent (`drawSpread`). A touch lifts the nearest model's
/// line out and names it.
struct SpreadChart: View {
    let series: OpenMeteo.HourlySeries
    let from: Int
    let steps: Int
    let spec: SpreadSpec
    var compact = false
    var dark = false

    @State private var picked: (index: Int, model: String)?

    private var count: Int { max(0, min(steps, series.times.count - from)) }
    private var envelope: Outlook.Envelope { Outlook.envelope(series, from: from, steps: count) }

    private var ticks: [Double] {
        let env = envelope
        let low = env.min.compactMap { $0 }.min() ?? 0
        let high = env.max.compactMap { $0 }.max() ?? 1
        return SpreadAxis.yTicks(low: low, high: high, compact: compact, fromZero: spec.suggestedMax != nil, suggestedMax: spec.suggestedMax)
    }

    private struct Frame {
        let x0: CGFloat, x1: CGFloat, top: CGFloat, bottom: CGFloat
        let low: Double, high: Double, count: Int

        func x(_ i: Int) -> CGFloat { count < 2 ? x0 : x0 + CGFloat(i) / CGFloat(count - 1) * (x1 - x0) }
        func y(_ v: Double) -> CGFloat { bottom - CGFloat((v - low) / max(high - low, 1e-9)) * (bottom - top) }
    }

    private func frame(_ size: CGSize, ticks: [Double]) -> Frame {
        let labelWidth: CGFloat = compact ? 34 : 40
        return Frame(x0: labelWidth, x1: size.width - 2, top: compact ? 4 : 6, bottom: size.height - (compact ? 14 : 18),
                     low: ticks.first ?? 0, high: ticks.last ?? 1, count: count)
    }

    var body: some View {
        let ticks = self.ticks
        let accent = ChromeTheme(dark: dark).accent
        let ink = Color.primary
        GeometryReader { geometry in
            let f = frame(geometry.size, ticks: ticks)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    let env = envelope
                    let font = Font.system(size: compact ? 9 : 10).monospacedDigit()
                    for tick in ticks {
                        let y = f.y(tick)
                        context.stroke(Path { $0.move(to: CGPoint(x: f.x0, y: y)); $0.addLine(to: CGPoint(x: f.x1, y: y)) },
                                       with: .color(ink.opacity(0.1)), lineWidth: 1)
                        let label = tick.rounded() == tick ? String(Int(tick)) : String(format: "%.1f", tick)
                        context.draw(Text(label + spec.unit).font(font).foregroundStyle(ink.opacity(0.6)),
                                     at: CGPoint(x: f.x0 - 4, y: y), anchor: .trailing)
                    }
                    let times = Array(series.times[from ..< from + count])
                    let zone = TimeZone(secondsFromGMT: series.utcOffset) ?? .current
                    let formatter = DateFormatter()
                    formatter.timeZone = zone
                    formatter.locale = Locale(identifier: CoreStrings.language)
                    for (index, mark) in SpreadAxis.xMarks(times, steps: count, timeZone: zone) {
                        let x = f.x(index)
                        context.stroke(Path { $0.move(to: CGPoint(x: x, y: f.top)); $0.addLine(to: CGPoint(x: x, y: f.bottom)) },
                                       with: .color(ink.opacity(0.1)), lineWidth: 1)
                        formatter.dateFormat = mark == .weekday ? "EEE" : "HH"
                        // Kept inside the plot: the last midnight lands on its edge.
                        let anchor: UnitPoint = x > f.x1 - 12 ? .trailing : x < f.x0 + 12 ? .leading : .center
                        context.draw(Text(formatter.string(from: times[index])).font(font).foregroundStyle(ink.opacity(0.6)),
                                     at: CGPoint(x: x, y: f.bottom + (compact ? 8 : 10)), anchor: anchor)
                    }
                    // The band: the models' full spread.
                    var band = Path()
                    let upper = (0 ..< count).compactMap { i in env.max[i].map { CGPoint(x: f.x(i), y: f.y($0)) } }
                    let lower = (0 ..< count).reversed().compactMap { i in env.min[i].map { CGPoint(x: f.x(i), y: f.y($0)) } }
                    if upper.count > 1 {
                        band.addLines(upper + lower)
                        band.closeSubpath()
                        context.fill(band, with: .color(accent.opacity(dark ? 0.24 : 0.14)))
                    }
                    for id in series.ids where id != picked?.model {
                        context.stroke(line(series.series[id] ?? [], f), with: .color(ink.opacity(0.16)), lineWidth: compact ? 1 : 1.25)
                    }
                    context.stroke(line(env.mid, f, offset: 0), with: .color(accent),
                                   style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    if let picked, let values = series.series[picked.model] {
                        context.stroke(line(values, f), with: .color(accent), lineWidth: 2.5)
                    }
                }
                if let picked {
                    tooltip(picked, frame: f)
                }
            }
            .contentShape(Rectangle())
            .gesture(compact ? nil : DragGesture(minimumDistance: 0)
                .onChanged { value in pick(at: value.location, frame: f) }
                .onEnded { _ in })
        }
        .accessibilityElement()
        .accessibilityLabel(CoreStrings.t("compare.spread.heading", ["variable": CoreStrings.t("compare.variable.\(spec.variable)")]))
        .accessibilityValue(summary)
    }

    /// A model's line over the window; `offset` is where its values start
    /// (the whole series, or the envelope's own window).
    private func line(_ values: [Double?], _ f: Frame, offset: Int? = nil) -> Path {
        let start = offset ?? from
        var path = Path()
        var drawing = false
        for i in 0 ..< f.count {
            let index = start + i
            guard index >= 0, index < values.count, let v = values[index] else { drawing = false; continue }
            let p = CGPoint(x: f.x(i), y: f.y(v))
            if drawing { path.addLine(to: p) } else { path.move(to: p); drawing = true }
        }
        return path
    }

    private func pick(at location: CGPoint, frame f: Frame) {
        guard f.count > 1 else { return }
        let i = max(0, min(f.count - 1, Int(((location.x - f.x0) / (f.x1 - f.x0) * CGFloat(f.count - 1)).rounded())))
        let nearest = series.ids.compactMap { id -> (String, CGFloat)? in
            guard let v = series.series[id]?[safe: from + i] ?? nil else { return nil }
            return (id, abs(f.y(v) - location.y))
        }.min { $0.1 < $1.1 }
        if let nearest { picked = (i, nearest.0) }
    }

    private func tooltip(_ picked: (index: Int, model: String), frame f: Frame) -> some View {
        let env = envelope
        let digits = 1
        let value = series.series[picked.model]?[safe: from + picked.index] ?? nil
        let low = env.min[safe: picked.index] ?? nil, high = env.max[safe: picked.index] ?? nil
        let spread = (low != nil && high != nil) ? String(format: "%.\(digits)f", high! - low!) : "–"
        let median = (env.mid[safe: picked.index] ?? nil).map { String(format: "%.\(digits)f", $0) } ?? "–"
        let time = series.times[safe: from + picked.index].map { date -> String in
            let formatter = DateFormatter()
            formatter.timeZone = TimeZone(secondsFromGMT: series.utcOffset)
            formatter.locale = Locale(identifier: CoreStrings.language)
            formatter.dateFormat = "EEE HH:mm"
            return formatter.string(from: date)
        } ?? ""
        let x = f.x(picked.index)
        return VStack(alignment: .leading, spacing: 2) {
            Text(time).font(.system(size: 11, weight: .semibold))
            Text("\(CompareModels.label(picked.model)): \(value.map { String(format: "%.1f", $0) } ?? "–")\(spec.unit)")
                .font(.system(size: 11))
            Text(CoreStrings.t("compare.spread.tooltip", ["median": median, "spread": spread, "count": env.count[safe: picked.index] ?? 0]))
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .fixedSize()
        .offset(x: min(max(0, x - 80), max(0, f.x1 - 170)), y: f.top)
        .allowsHitTesting(false)
    }

    private var summary: String {
        let env = envelope
        let mids = env.mid.compactMap { $0 }
        guard let low = mids.min(), let high = mids.max() else { return "" }
        return "\(CoreStrings.t("compare.spread.median")): \(String(format: "%.1f", low))–\(String(format: "%.1f", high))\(spec.unit)"
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// The comparison's state: the daily answer, the place's name, which day is open.
@MainActor
final class ModelCompareModel: ObservableObject {
    let latitude: Double
    let longitude: Double
    @Published var place: String?
    @Published var forecast: OpenMeteo.Forecast?
    @Published var error: String?
    @Published var loading = true
    @Published var expanded: String?
    // The spread.
    @Published var spec = SpreadSpec.rainfall
    @Published var hours: Int
    @Published var hourly: [String: OpenMeteo.HourlySeries] = [:]
    @Published var spreadError: String?
    @Published var spreadLoading = false

    init(latitude: Double, longitude: Double, hours: Int) {
        self.latitude = latitude
        self.longitude = longitude
        self.hours = hours
    }

    func start() {
        let language = CoreStrings.language
        Task {
            let name = await ReverseGeocoder.shared.name(latitude: latitude, longitude: longitude, language: language)
            place = name
        }
        load()
        loadSpread()
    }

    func load() {
        loading = true
        error = nil
        Task {
            do {
                forecast = try await OpenMeteoClient.shared.forecast(latitude: latitude, longitude: longitude)
            } catch {
                self.error = (error as? OpenMeteo.Failure)?.message ?? error.localizedDescription
            }
            loading = false
        }
    }

    func loadSpread() {
        let spec = self.spec
        guard hourly[spec.variable] == nil else { spreadError = nil; return }
        spreadLoading = true
        spreadError = nil
        Task {
            do {
                let series = try await OpenMeteoClient.shared.hourly(latitude: latitude, longitude: longitude, variable: spec.variable)
                hourly[spec.variable] = series
            } catch {
                if spec == self.spec { spreadError = (error as? OpenMeteo.Failure)?.message ?? error.localizedDescription }
            }
            if spec == self.spec { spreadLoading = false }
        }
    }

    /// A wake: a failed answer is asked again.
    func wake() {
        if error != nil, !loading { load() }
        if spreadError != nil { loadSpread() }
    }
}

/// The comparison in the drawers' frame (`ModelCompare.svelte` in `StormPanel`).
struct ModelCompareView: View {
    @ObservedObject var model: ModelCompareModel
    let wide: Bool
    let close: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var scrolled = false

    var body: some View {
        Group {
            if wide {
                // The title and the way out in a row of their own over the
                // reading: a disc over an iPad's scroll view took no taps.
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 8) {
                        header
                        Spacer(minLength: 0)
                        closeDisc
                    }
                    .padding(.leading, 18)
                    .padding(.trailing, 14)
                    .padding(.top, 14)
                    reading
                }
            } else {
                reading.overlay(alignment: .topTrailing) {
                    closeDisc
                        .padding(.top, 11)
                        .padding(.trailing, 12)
                }
            }
        }
        // A container: its own children keep their identifiers.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nativeMap.compare")
    }

    /// Everything under the title, scrolling; on a phone the title too.
    private var reading: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !wide { header.padding(.trailing, 56) }
                if model.loading {
                    Text(CoreStrings.t("compare.loading")).font(.system(size: 15)).foregroundStyle(.secondary).padding(.vertical, 24)
                } else if let error = model.error {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(CoreStrings.t("compare.error")).font(.system(size: 15))
                        Text(error).font(.system(size: 13)).foregroundStyle(.secondary)
                        Button(CoreStrings.t("retry"), action: model.load).buttonStyle(.bordered)
                    }
                    .padding(.vertical, 16)
                } else {
                    spread
                    days
                    footer
                }
            }
            .padding(.horizontal, wide ? 18 : 16)
            .padding(.top, wide ? 4 : 21)
            .padding(.bottom, 28)
        }
        // Clear of the close disc, which an iPad's indicator would take a
        // tap for.
        .contentMargins(.top, wide ? 0 : 56, for: .scrollIndicators)
        .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 1 } action: { _, now in
            scrolled = now
        }
        // What scrolls up fades out at the top, as core's drawer body does.
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: scrolled ? (wide ? 16 : 40) : (wide ? 1 : 11))
                Color.black
            }
            .animation(.easeOut(duration: 0.2), value: scrolled)
        }
    }

    private var closeDisc: some View {
        Button(action: close) {
            Image(systemName: "xmark")
                .font(.system(size: wide ? 14 : 18, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: wide ? 30 : 44, height: wide ? 30 : 44)
                .background(Color.secondary.opacity(0.12), in: Circle())
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(CoreStrings.t("close"))
        .accessibilityIdentifier("nativeMap.compare.close")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(model.place ?? String(format: "%.3f, %.3f", model.latitude, model.longitude))
                .font(.system(size: wide ? 22 : 24, weight: .bold))
                .tracking(-0.48)
                .accessibilityLabel(model.place.map { CoreStrings.t("compare.title_place", ["place": $0]) } ?? CoreStrings.t("compare.title"))
                .accessibilityIdentifier("nativeMap.compare.title")
            Text(model.forecast.map { CoreStrings.t("compare.responding", ["count": $0.respondingModels.count]) } ?? CoreStrings.t("compare.comparing"))
                .font(.system(size: wide ? 14 : 15, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 14)
    }

    private func heading(_ text: String, aside: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).font(.system(size: wide ? 17 : 19, weight: .bold)).tracking(-0.19)
            Spacer()
            if let aside { Text(aside).font(.system(size: 13)).foregroundStyle(.tertiary) }
        }
        .padding(.top, 18)
        .padding(.bottom, 6)
    }

    // MARK: Spread

    private var spread: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading(CoreStrings.t("compare.spread.heading", ["variable": CoreStrings.t("compare.variable.\(model.spec.variable)")]))
            Text(CoreStrings.t("compare.spread.sub")).font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Picker(CoreStrings.t("compare.spread.variable_group"), selection: Binding(
                    get: { model.spec.variable },
                    set: { model.spec = $0 == SpreadSpec.temperature.variable ? .temperature : .rainfall; model.loadSpread() })) {
                    Text(CoreStrings.t("compare.variable.precipitation")).tag(SpreadSpec.rainfall.variable)
                    Text(CoreStrings.t("compare.variable.temperature_2m")).tag(SpreadSpec.temperature.variable)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("nativeMap.compare.variable")
                Picker(CoreStrings.t("compare.spread.range_group"), selection: $model.hours) {
                    Text(CoreStrings.t("compare.range.day")).tag(24)
                    Text(CoreStrings.t("compare.range.week")).tag(168)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("nativeMap.compare.range")
            }
            if let error = model.spreadError {
                HStack {
                    Text(CoreStrings.t("compare.spread.error") + " " + error).font(.system(size: 13)).foregroundStyle(.secondary)
                    Button(CoreStrings.t("retry"), action: model.loadSpread).buttonStyle(.bordered).controlSize(.small)
                }
            } else if let series = model.hourly[model.spec.variable] {
                SpreadChart(series: series, from: Outlook.stepAt(series.times, Date()), steps: model.hours, spec: model.spec,
                            dark: scheme == .dark)
                    .frame(height: 190)
                    .id("\(model.spec.variable)-\(model.hours)")
                legend(count: series.ids.count)
            } else {
                ChartSkeleton(bars: 24).frame(height: 190)
            }
        }
    }

    private func legend(count: Int) -> some View {
        let accent = ChromeTheme(dark: scheme == .dark).accent
        return HStack(spacing: 14) {
            HStack(spacing: 5) { Capsule().fill(accent).frame(width: 14, height: 3); Text(CoreStrings.t("compare.spread.median")) }
            HStack(spacing: 5) { RoundedRectangle(cornerRadius: 2).fill(accent.opacity(0.18)).frame(width: 14, height: 9); Text(CoreStrings.t("compare.spread.range")) }
            HStack(spacing: 5) { Capsule().fill(Color.primary.opacity(0.3)).frame(width: 14, height: 1); Text(CoreStrings.t("compare.models", ["count": count == 0 ? 21 : count])) }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }

    // MARK: Days

    private struct DayView: Identifiable {
        let id: String
        let name: String
        let code: Consensus
        let high: Consensus
        let low: Consensus
        let precip: Consensus
        let probability: Consensus
    }

    private func dayViews(_ forecast: OpenMeteo.Forecast) -> [DayView] {
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: CoreStrings.language)
        formatter.timeZone = TimeZone(secondsFromGMT: forecast.utcOffset)
        formatter.dateFormat = "EEE"
        return forecast.days.enumerated().map { index, day in
            let lead = OpenMeteo.leadHours(date: day.date, utcOffset: forecast.utcOffset, now: now)
            let name = index == 0 ? CoreStrings.t("compare.today") : index == 1 ? CoreStrings.t("compare.tomorrow")
                : OpenMeteo.instant(day.date + "T12:00", utcOffset: forecast.utcOffset).map(formatter.string(from:)) ?? day.date
            func of(_ variable: DailyVar) -> Consensus { Consensus.of(day.values[variable] ?? [], variable, leadHours: lead) }
            return DayView(id: day.date, name: name, code: of(.weatherCode), high: of(.temperatureMax), low: of(.temperatureMin),
                           precip: of(.precipitationSum), probability: of(.precipitationProbability))
        }
    }

    private func round(_ value: Double?, _ digits: Int = 0) -> String {
        guard let value else { return "–" }
        return String(format: "%.\(digits)f", value)
    }

    @ViewBuilder
    private var days: some View {
        if let forecast = model.forecast {
            heading(CoreStrings.t("compare.days_heading"), aside: CoreStrings.t("compare.days_aside"))
            VStack(spacing: 0) {
                ForEach(dayViews(forecast)) { day in
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { model.expanded = model.expanded == day.id ? nil : day.id }
                    } label: { dayRow(day) }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.expanded == day.id ? .isSelected : [])
                    if model.expanded == day.id { breakdown(forecast, day.id) }
                    Divider()
                }
            }
        }
    }

    private func dayRow(_ day: DayView) -> some View {
        let tier = Consensus.tier(day.high.predictability)
        let code = WeatherCodes.code(day.code.value)
        return HStack(spacing: 10) {
            Text(day.name).font(.system(size: 15, weight: .semibold)).frame(width: 74, alignment: .leading).lineLimit(1)
            Text(WeatherCodes.icon(day.code.value)).font(.system(size: 20))
                .accessibilityLabel(code.map { CoreStrings.t("compare.weather.\($0)") } ?? "–")
            HStack(spacing: 3) {
                Text("\(round(day.high.value))°").font(.system(size: 15, weight: .semibold))
                Text("/ \(round(day.low.value))°").font(.system(size: 13)).foregroundStyle(.secondary)
                if day.high.stdDev >= 0.5 {
                    Text("±\(round(day.high.stdDev, 1))").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .monospacedDigit()
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 0) {
                Text("\(round(day.precip.value, 1)) mm").font(.system(size: 13)).monospacedDigit()
                if day.probability.value != nil {
                    Text("\(round(day.probability.value))%").font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Text(CoreStrings.t("compare.tier.\(tier.rawValue)"))
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .foregroundStyle(tierInk(tier))
                .background(tierInk(tier).opacity(0.14), in: Capsule())
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func tierInk(_ tier: Consensus.Tier) -> Color {
        switch tier {
        case .high: return .green
        case .mid: return .orange
        case .low: return .red
        }
    }

    private func breakdown(_ forecast: OpenMeteo.Forecast, _ date: String) -> some View {
        let day = forecast.days.first { $0.date == date }
        let highs = Dictionary(uniqueKeysWithValues: (day?.values[.temperatureMax] ?? []).map { ($0.id, $0.value) })
        let lows = Dictionary(uniqueKeysWithValues: (day?.values[.temperatureMin] ?? []).map { ($0.id, $0.value) })
        let precip = Dictionary(uniqueKeysWithValues: (day?.values[.precipitationSum] ?? []).map { ($0.id, $0.value) })
        let ids = highs.keys.sorted { CompareModels.label($0).localizedCompare(CompareModels.label($1)) == .orderedAscending }
        return VStack(spacing: 4) {
            ForEach(ids, id: \.self) { id in
                HStack {
                    Text(CompareModels.label(id)).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                    Text("\(round(highs[id]))°").frame(width: 40, alignment: .trailing)
                    Text("\(round(lows[id]))°").frame(width: 40, alignment: .trailing).foregroundStyle(.secondary)
                    Text("\(round(precip[id], 1)) mm").frame(width: 64, alignment: .trailing)
                }
                .font(.system(size: 12).monospacedDigit())
            }
        }
        .padding(.bottom, 10)
    }

    // MARK: Footer

    private var footer: some View {
        let method = CoreStrings.t("compare.footer.method", [
            "lat": String(format: "%.4f", model.latitude), "lon": String(format: "%.4f", model.longitude),
            "count": model.forecast?.respondingModels.count ?? 0,
        ])
        let markdown = "\(method) \(CoreStrings.t("compare.footer.registry")) [meteocompare](https://github.com/Flowm/meteocompare); "
            + "\(CoreStrings.t("compare.footer.data")) [Open-Meteo.com](https://open-meteo.com/) ([CC BY 4.0](https://creativecommons.org/licenses/by/4.0/))."
        return Text((try? AttributedString(markdown: markdown)) ?? AttributedString(markdown))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.top, 16)
    }
}

/// Opens and closes the comparison in a drawer (`modelCompareAt`).
@MainActor
final class ModelCompareDrawer {
    private weak var map: NativeMapContext?
    private let drawer: MapDrawer
    private var model: ModelCompareModel?

    init(map: NativeMapContext) {
        self.map = map
        drawer = MapDrawer(map: map, owner: "compare")
        drawer.onClose = { [weak self] in self?.closed() }
    }

    var isOpen: Bool { model != nil }

    func open(latitude: Double, longitude: Double, hours: Int) {
        let model = ModelCompareModel(latitude: latitude, longitude: longitude, hours: hours)
        self.model = model
        self.map?.model.compareOpen = true
        model.start()
        // Charts to read: at half height they were a strip of axis labels.
        drawer.show(ModelCompareView(model: model, wide: drawer.wide, close: { [weak self] in self?.close() }), full: true)
    }

    func close() {
        guard model != nil else { return }
        drawer.close()
        closed()
    }

    private func closed() {
        model = nil
        map?.model.compareOpen = false
    }

    func wake() { model?.wake() }
}
