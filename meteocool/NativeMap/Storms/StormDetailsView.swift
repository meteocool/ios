//
//  StormDetailsView.swift
//  meteocool
//
//  A storm's panel: core's `StormDetails.svelte` in `StormPanel.svelte`.
//

import SwiftUI

/// What the storm panel says about the selection, refreshed on a 15 s clock.
struct StormDetailsView: View {
    @ObservedObject var store: StormStore
    /// iPad's floating panel: the base type scale, its own discs.
    let wide: Bool
    /// The newest radar frame, ms (core's `capLatestObservation`).
    let newestRadarMs: () -> Double?
    let close: () -> Void
    let share: () -> Void
    /// Opens the AR view at the storm; nil where AR is not offered.
    let openAR: (() -> Void)?

    @Environment(\.colorScheme) private var scheme
    private let t: StormTranslate = { CoreStrings.t($0, $1) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let now = context.date.timeIntervalSince1970 * 1000
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    stats(now: now)
                    signals
                    readings
                    if let openAR {
                        Button(action: openAR) {
                            Text(NSLocalizedString("map_ar", comment: ""))
                                .font(.system(size: 15, weight: .semibold))
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .foregroundStyle(Color.accentColor)
                                .background(Color.accentColor.opacity(scheme == .dark ? 0.24 : 0.14), in: Capsule())
                        }
                        .buttonStyle(PressScale())
                        .padding(.top, 10)
                        .accessibilityIdentifier("nativeMap.storm.ar")
                    }
                    history(now: now)
                    merges
                    family(now: now)
                    facts(now: now)
                }
                .padding(.horizontal, wide ? 18 : 16)
                .padding(.top, wide ? 16 : 21)
                .padding(.trailing, wide ? 0 : 8)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.automatic)
        }
        .overlay(alignment: .topTrailing) { discs }
        .accessibilityIdentifier("nativeMap.storm.details")
    }

    // MARK: - Derived

    private var selection: StormSelection? { store.selection }
    private var track: TrackProperties? { selection?.cell }
    private var storm: StormProperties? { selection?.summary?.properties ?? selection?.detail?.storm.properties }
    private var classed: Bool { selection.map(StormSelect.knowsSeverity) ?? false }
    private var severity: Int { selection.flatMap(StormSelect.severityOf) ?? 0 }
    private var colour: Color { Color(uiColor: StormStyle.colour(severity)) }
    private var band: String { StormRules.bandNames[max(0, min(severity, 3))] }
    private var placement: CellPlacement? { track?.placement ?? storm?.placement }

    /// "Strong", or the place, or "Storm".
    var title: String {
        if classed { return Self.capitalised(CoreStrings.t("storm.band.\(band)")) }
        return store.named?.name ?? Self.capitalised(CoreStrings.t("storm.storm_label.unclassed"))
    }

    private var place: String? {
        StormRules.placementLabel(placement, t, style: .long) ?? store.named?.area
    }

    /// The share sheet's subject: "Strong storm, 18 km N of Freising".
    var subject: String {
        let label = classed ? CoreStrings.t("storm.storm_label.\(band)") : CoreStrings.t("storm.storm_label.unclassed")
        return [label, place].compactMap { $0 }.joined(separator: ", ")
    }

    private var lastSeen: String? { storm?.lastSeen ?? track?.lastSeen ?? selection?.volume?.referenceTime }

    private func recency(now: Double) -> StormRules.Recency? {
        lastSeen.map { StormRules.cellRecency(lastSeenMs: StormTime.ms($0), nowMs: now, radarFrameMs: newestRadarMs()) }
    }

    static func capitalised(_ text: String) -> String {
        text.split(separator: " ", omittingEmptySubsequences: false).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    private func clock(_ iso: String?) -> String {
        guard let iso else { return "–" }
        let ms = StormTime.ms(iso)
        guard ms.isFinite else { return "–" }
        return StatusPill.clock(Int(ms / 1000))
    }

    // MARK: - Type (`glass.css:105-111`)

    private var titleFont: Font { .system(size: wide ? 22 : 24, weight: .bold) }
    private var subtitleFont: Font { .system(size: wide ? 14 : 15, weight: .medium) }
    private var headingFont: Font { .system(size: wide ? 17 : 19, weight: .bold) }
    private var labelFont: Font { .system(size: wide ? 12 : 13, weight: .medium) }
    private var valueFont: Font { .system(size: wide ? 15 : 17, weight: .semibold).monospacedDigit() }

    private func heading(_ key: String, aside: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(CoreStrings.t(key)).font(headingFont).tracking(-0.19)
            Spacer()
            if let aside { Text(aside).font(.system(size: 13)).foregroundStyle(.tertiary) }
        }
        .padding(.top, 26)
        .padding(.bottom, 10)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(colour).frame(width: 4).padding(.vertical, 3)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(titleFont).tracking(-0.48).accessibilityIdentifier("nativeMap.storm.title")
                if let place { Text(place).font(subtitleFont).foregroundStyle(.secondary) }
            }
            Spacer(minLength: wide ? 76 : 98)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 14)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func stats(now: Double) -> some View {
        if storm != nil || track != nil {
            let recency = self.recency(now: now)
            let age = recency?.ageMinutes ?? 0
            let status: StormRules.StatusKind = storm.map { StormRules.stormStatus($0.status, ageMinutes: age) }
                ?? StormRules.cellStatus(active: track?.active ?? false, childCodes: track?.childCodes ?? [], ageMinutes: age)
            let since = storm?.bornAt ?? track?.firstSeen
            HStack(alignment: .top, spacing: 8) {
                stat("storm.stat.status") {
                    HStack(spacing: 6) {
                        Circle().fill(statusColour(status)).frame(width: 7, height: 7)
                        Text(StormRules.sentence(StormRules.statusLabel(status, t))).foregroundStyle(statusColour(status))
                    }
                }
                stat("storm.stat.tracked") {
                    Text(since.map { StormRules.duration(max(0, (now - StormTime.ms($0)) / 60_000), t) } ?? "–")
                }
                stat("storm.stat.updated") {
                    Text(CoreStrings.t("storm.ago", ["duration": StormRules.duration(age, t)]))
                        .foregroundStyle(StormRules.radarOffsetLabel(recency?.behindMinutes, t) != nil ? Color.orange : Color.primary)
                }
            }
            .padding(.bottom, 14)
        }
    }

    private func statusColour(_ status: StormRules.StatusKind) -> Color {
        switch status {
        case .live: return .red
        case .stale: return .orange
        default: return .secondary
        }
    }

    private func stat(_ key: String, @ViewBuilder value: () -> some View) -> some View {
        VStack(spacing: 4) {
            Text(CoreStrings.t(key)).font(labelFont).foregroundStyle(.secondary)
            value().font(valueFont).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var signals: some View {
        if let track {
            let items = signalItems(track)
            if !items.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(items, id: \.text) { item in
                        Text(item.text)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .padding(.vertical, 5)
                            .padding(.horizontal, 11)
                            .foregroundStyle(item.ink)
                            .background(item.fill, in: Capsule())
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    private func signalItems(_ track: TrackProperties) -> [(text: String, ink: Color, fill: Color)] {
        let dark = scheme == .dark
        var out: [(String, Color, Color)] = []
        if track.mesoEver {
            let text = CoreStrings.t("storm.signal.rotating") + (track.mesoMinutes > 0 ? " " + StormRules.duration(Double(track.mesoMinutes), t) : "")
            out.append((text, dark ? Color(red: 0xda / 255, green: 0x8f / 255, blue: 1) : Color(red: 0x89 / 255, green: 0x44 / 255, blue: 0xab / 255),
                        dark ? Color(red: 191 / 255, green: 90 / 255, blue: 242 / 255).opacity(0.24) : Color(red: 175 / 255, green: 82 / 255, blue: 222 / 255).opacity(0.18)))
        }
        if track.hailEver {
            let text = CoreStrings.t("hail") + (track.hailMinutes > 0 ? " " + StormRules.duration(Double(track.hailMinutes), t) : "")
            out.append((text, dark ? Color(red: 1, green: 0x69 / 255, blue: 0x61 / 255) : Color(red: 0xb3 / 255, green: 0x26 / 255, blue: 0x1e / 255),
                        Color.red.opacity(dark ? 0.22 : 0.16)))
        }
        if track.lightningJumpRecent {
            out.append((CoreStrings.t("storm.signal.lightning_jump"), dark ? Color(red: 1, green: 0xb3 / 255, blue: 0x40 / 255) : Color(red: 0x9a / 255, green: 0x5a / 255, blue: 0),
                        Color.orange.opacity(dark ? 0.24 : 0.20)))
        }
        let tint = Color.secondary.opacity(0.12)
        if track.intensifying { out.append((CoreStrings.t("storm.signal.intensifying"), .primary, tint)) }
        if track.splitEver { out.append((CoreStrings.t("storm.signal.split"), .primary, tint)) }
        if track.mergeEver { out.append((CoreStrings.t("storm.signal.merged"), .primary, tint)) }
        if let deviation = track.deviationDeg, deviation > 30 {
            out.append((CoreStrings.t("storm.signal.deviant", ["deg": Int(StormDrawing.jsRound(deviation))]), .accentColor, Color.accentColor.opacity(dark ? 0.24 : 0.14)))
        }
        return out
    }

    private var readingItems: [StormRules.Reading] {
        if let track { return StormRules.cellReadings(track, t) }
        guard let storm else { return [] }
        let step = selection?.detail.flatMap { StormSelect.trackerSeries($0).last }
        var out = [StormRules.reading("peak", step?.peakDbz ?? storm.peakDbz ?? selection?.volume?.peakDbz, t)]
        if let area = step?.areaKm2 {
            out.append(StormRules.Reading(key: "area", label: CoreStrings.t("storm.reading.area"), text: "\(Int(StormDrawing.jsRound(area))) km²",
                                          band: nil, bandName: nil, fill: nil))
        }
        if let speed = storm.speedKmh {
            out.append(StormRules.reading("speed", speed, t, suffix: " " + StormRules.compass16(selection.flatMap(StormSelect.headingOf), t)))
        }
        return out
    }

    @ViewBuilder
    private var readings: some View {
        let items = readingItems
        if !items.isEmpty {
            heading("storm.section.readings")
            Grid(alignment: .topLeading, horizontalSpacing: wide ? 20 : 16, verticalSpacing: 14) {
                ForEach(Array(stride(from: 0, to: items.count, by: 2)), id: \.self) { row in
                    GridRow {
                        readingCell(items[row])
                        if row + 1 < items.count { readingCell(items[row + 1]) } else { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                    }
                }
            }
        }
    }

    private func bandInk(_ band: Int?) -> Color {
        guard let band else { return .primary }
        let dark = scheme == .dark
        let inks: [(UInt32, UInt32)] = [(0x1b7a31, 0x57c96a), (0x8a5e05, 0xf5c95c), (0xb02020, 0xff8585), (0x7a219a, 0xd68bea)]
        let hex = dark ? inks[band].1 : inks[band].0
        return Color(red: Double(hex >> 16) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    private func readingCell(_ item: StormRules.Reading) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(StormRules.sentence(item.label)).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Text(item.text).font(.system(size: wide ? 15 : 16, weight: .semibold).monospacedDigit()).foregroundStyle(bandInk(item.band))
            }
            if let fill = item.fill {
                GeometryReader { geometry in
                    let ink = item.band.map { Color(uiColor: StormStyle.colour($0)) } ?? Color.gray
                    ZStack(alignment: .leading) {
                        Capsule().fill(item.band == nil ? Color.gray.opacity(0.16) : ink.opacity(0.2))
                        Capsule().fill(ink).frame(width: geometry.size.width * fill)
                    }
                }
                .frame(height: 4)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(item.bandName ?? "")
    }

    // MARK: History

    private struct Panel {
        let key: String
        let title: String
        let unit: String
        let height: Double
        let axis: Bool
        let digits: Int
        let values: [(t: Double, v: Double?)]
        let kin: [[(t: Double, v: Double?)]]
        let tinted: Bool
    }

    private func panels() -> [Panel] {
        let series: [(t: Double, dbz: Double?, second: Double?)]
        if let track {
            series = track.series.map { (StormTime.ms($0.t), $0.maxDbz, $0.echoTopM.map { $0 / 1000 }) }
        } else if let detail = selection?.detail {
            series = StormSelect.trackerSeries(detail).map { (StormTime.ms($0.t), $0.peakDbz, $0.areaKm2) }
        } else {
            series = []
        }
        let relatives = track.map { root in
            store.family.values.filter { $0.code != root.code && $0.series.count > 1 }
                .sorted { ($0.firstSeen, $0.code) < ($1.firstSeen, $1.code) }
        } ?? []
        let kinDbz = relatives.map { $0.series.map { (t: StormTime.ms($0.t), v: $0.maxDbz) } }
        let kinTop = relatives.map { $0.series.map { (t: StormTime.ms($0.t), v: $0.echoTopM.map { $0 / 1000 }) } }
        var out = [Panel(key: "dbz", title: CoreStrings.t("storm.history.reflectivity"), unit: "dBZ", height: 62, axis: false, digits: 0,
                         values: series.map { ($0.t, $0.dbz) }, kin: kinDbz, tinted: true)]
        if track != nil {
            out.append(Panel(key: "top", title: CoreStrings.t("storm.history.echo_top"), unit: "km", height: 58, axis: true, digits: 1,
                             values: series.map { ($0.t, $0.second) }, kin: kinTop, tinted: false))
        } else {
            out.append(Panel(key: "area", title: CoreStrings.t("storm.history.area"), unit: "km²", height: 58, axis: true, digits: 0,
                             values: series.map { ($0.t, $0.second) }, kin: [], tinted: false))
        }
        return out.filter { $0.values.compactMap(\.v).filter(\.isFinite).count >= 2 }
    }

    @ViewBuilder
    private func history(now: Double) -> some View {
        let panels = self.panels()
        let times = panels.flatMap { $0.values.map(\.t) + $0.kin.flatMap { $0.map(\.t) } }.filter(\.isFinite)
        if !panels.isEmpty, times.count >= 2, let from = times.min(), let latest = times.max() {
            let end = max(latest, now)
            let span = (from: from, to: end + (end - from) * 0.05)
            heading("storm.section.history")
            ForEach(Array(panels.enumerated()), id: \.offset) { index, panel in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(panel.title), \(panel.unit)").font(.system(size: 12)).foregroundStyle(.secondary)
                    HistoryChart(panel: panel, span: span, now: now, first: index == 0, colour: colour)
                        .aspectRatio(336 / panel.height, contentMode: .fit)
                        .accessibilityLabel(CoreStrings.t("storm.history.aria", ["title": panel.title, "unit": panel.unit]))
                }
                .padding(.bottom, 6)
            }
        }
    }

    /// One small multiple, drawn in core's 336-wide space.
    private struct HistoryChart: View {
        let panel: Panel
        let span: (from: Double, to: Double)
        let now: Double
        let first: Bool
        let colour: Color

        var body: some View {
            Canvas { context, size in
                let k = size.width / 336
                context.scaleBy(x: k, y: k)
                let x0 = 28.0, x1 = 298.0, top = 9.0
                let y0 = panel.height - (panel.axis ? 16 : 5)
                let atX = { (t: Double) in x0 + (t - span.from) / (span.to - span.from) * (x1 - x0) }
                let values = panel.values.compactMap(\.v) + panel.kin.flatMap { $0.compactMap(\.v) }
                guard let scale = StormRules.verticalScale(values, y0: y0, y1: top, target: 3) else { return }
                let ink = Color.primary
                for tick in scale.ticks {
                    let y = scale.at(tick)
                    context.stroke(Path { $0.move(to: CGPoint(x: x0, y: y)); $0.addLine(to: CGPoint(x: x1, y: y)) }, with: .color(ink.opacity(0.12)), lineWidth: 1)
                    context.draw(Text(StormRules.toFixed(tick, tick.rounded() == tick ? 0 : 1)).font(.system(size: 9).monospacedDigit()).foregroundStyle(ink.opacity(0.6)),
                                 at: CGPoint(x: x0 - 5, y: y), anchor: .trailing)
                }
                if now > span.from {
                    let nowX = atX(now)
                    context.stroke(Path { $0.move(to: CGPoint(x: nowX, y: top)); $0.addLine(to: CGPoint(x: nowX, y: y0)) },
                                   with: .color(ink.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    if first {
                        let label = Text(CoreStrings.t("now").uppercased()).font(.system(size: 8)).tracking(0.5).foregroundStyle(ink.opacity(0.55))
                        if x1 - nowX > 24 {
                            context.draw(label, at: CGPoint(x: nowX + 3, y: top + 7), anchor: .leading)
                        } else {
                            context.draw(label, at: CGPoint(x: nowX - 3, y: top + 7), anchor: .trailing)
                        }
                    }
                }
                if panel.axis {
                    let ticks = StormRules.timeTicks(span.from, span.to, target: 4)
                    for (i, t) in ticks.enumerated() {
                        let x = atX(t)
                        context.stroke(Path { $0.move(to: CGPoint(x: x, y: y0)); $0.addLine(to: CGPoint(x: x, y: y0 + 3)) }, with: .color(ink.opacity(0.35)), lineWidth: 1)
                        let anchor: UnitPoint = i == 0 ? .leading : i == ticks.count - 1 ? .trailing : .center
                        context.draw(Text(StatusPill.clock(Int(t / 1000))).font(.system(size: 9)).foregroundStyle(ink.opacity(0.6)),
                                     at: CGPoint(x: x, y: y0 + 13), anchor: anchor)
                    }
                }
                var axes = Path()
                axes.move(to: CGPoint(x: x0, y: top))
                axes.addLine(to: CGPoint(x: x0, y: y0))
                axes.addLine(to: CGPoint(x: x1, y: y0))
                context.stroke(axes, with: .color(ink.opacity(0.35)), lineWidth: 1)
                func trace(_ points: [(t: Double, v: Double?)]) -> Path {
                    var path = Path()
                    var drawing = false
                    for point in points {
                        guard let v = point.v, v.isFinite else { drawing = false; continue }
                        let p = CGPoint(x: atX(point.t), y: scale.at(v))
                        if drawing { path.addLine(to: p) } else { path.move(to: p); drawing = true }
                    }
                    return path
                }
                for kin in panel.kin {
                    context.stroke(trace(kin), with: .color(ink.opacity(0.3)), style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [3, 3]))
                }
                let lineColour = panel.tinted ? colour : ink.opacity(0.7)
                context.stroke(trace(panel.values), with: .color(lineColour), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                if let last = panel.values.last(where: { $0.v?.isFinite == true }), let v = last.v {
                    let p = CGPoint(x: atX(last.t), y: scale.at(v))
                    context.fill(Path(ellipseIn: CGRect(x: p.x - 2.6, y: p.y - 2.6, width: 5.2, height: 5.2)), with: .color(lineColour))
                    context.draw(Text(StormRules.toFixed(v, panel.digits)).font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(ink),
                                 at: CGPoint(x: x1 + 5, y: p.y), anchor: .leading)
                }
            }
        }
    }

    // MARK: Merges

    @ViewBuilder
    private var merges: some View {
        let into = storm?.status == "merged" ? storm?.mergedInto : nil
        let from = storm.map { StormSelect.mergedInto(store.held, $0.id) } ?? []
        if into != nil || !from.isEmpty {
            heading("storm.section.merges")
            VStack(alignment: .leading, spacing: 4) {
                if let into {
                    Button(CoreStrings.t("storm.merges.into") + " ›") { store.open(id: into) }
                        .font(.system(size: 13, weight: .medium))
                        .padding(.vertical, 4)
                }
                ForEach(from, id: \.id) { other in
                    Button(CoreStrings.t("storm.merges.from", ["time": clock(other.properties.lastSeen)]) + " ›") { store.open(id: other.properties.id) }
                        .font(.system(size: 13, weight: .medium))
                        .padding(.vertical, 4)
                }
            }
            .padding(.bottom, 8)
        }
    }

    // MARK: Family

    @ViewBuilder
    private func family(now: Double) -> some View {
        if let track {
            let lineage = StormRules.buildLineage(store.family, track.code)
            if let layout = StormRules.familyLayout(lineage, known: store.family, nowMs: now,
                                                    clock: { clock($0) }, t: t) {
                heading("storm.section.family", aside: CoreStrings.t("storm.lineage.tap") + (store.familyLoading ? " · " + CoreStrings.t("storm.lineage.loading") : ""))
                FamilyChart(layout: layout, dark: scheme == .dark) { code in store.walk(to: code) }
                    .accessibilityLabel(CoreStrings.t("storm.lineage.aria"))
            }
        }
    }

    // MARK: Facts

    @ViewBuilder
    private func facts(now: Double) -> some View {
        let recency = self.recency(now: now)
        let coreOnly = storm == nil && track == nil
        let forecast = StormDrawing.forecastCell(selection)?.forecast ?? []
        heading("storm.section.details")
        VStack(spacing: 0) {
            fact(CoreStrings.t("storm.fact.observed"), clock(lastSeen)
                 + (coreOnly ? " · " + CoreStrings.t("storm.ago", ["duration": StormRules.duration(recency?.ageMinutes ?? 0, t)]) : ""))
            if !coreOnly, let offset = StormRules.radarOffsetLabel(recency?.behindMinutes, t) {
                Divider()
                fact(CoreStrings.t("storm.fact.radar"), offset, ink: .orange)
            }
            if let last = forecast.last {
                Divider()
                fact(CoreStrings.t("storm.fact.forecast"),
                     CoreStrings.t("storm.fact.forecast_value", ["time": clock(last.t), "km": last.majorKm.map { StormRules.toFixed($0, 1) } ?? "–"]))
            }
        }
    }

    private func fact(_ label: String, _ value: String, ink: Color = .primary) -> some View {
        HStack(spacing: 12) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(ink).multilineTextAlignment(.trailing)
        }
        .font(.system(size: wide ? 14 : 15))
        .padding(.vertical, 10)
    }

    // MARK: Discs

    private var discs: some View {
        HStack(spacing: 8) {
            disc("square.and.arrow.up", label: CoreStrings.t("share.share"), id: "nativeMap.storm.share", action: share)
            disc("xmark", label: CoreStrings.t("close"), id: "nativeMap.storm.close", action: close)
        }
        .padding(.top, wide ? 14 : 11)
        .padding(.trailing, wide ? 14 : 12)
    }

    private func disc(_ symbol: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: wide ? 14 : 18, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: wide ? 30 : 44, height: wide ? 30 : 44)
                .background(Color.secondary.opacity(0.12), in: Circle())
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

/// The family: who split from and merged into whom, left to right in time,
/// scrolling sideways (`CellLineage.svelte`).
private struct FamilyChart: View {
    let layout: StormRules.FamilyLayout
    let dark: Bool
    let open: (String) -> Void

    var body: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in draw(&context) }
                        .frame(width: layout.width, height: layout.height)
                    ForEach(layout.nodes, id: \.code) { node in
                        Button { if !node.isSelf { open(node.code) } } label: {
                            Color.clear.frame(width: StormRules.nodeW, height: StormRules.nodeH).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(node.isSelf)
                        .position(x: node.x, y: node.y)
                        .accessibilityLabel(node.place.isEmpty ? node.label : "\(node.place), \(node.label)")
                        .accessibilityAddTraits(node.isSelf ? .isSelected : [])
                        .id(node.code)
                    }
                }
                .frame(width: layout.width, height: layout.height)
            }
            .onAppear { if let me = layout.nodes.first(where: \.isSelf) { reader.scrollTo(me.code, anchor: .center) } }
        }
        .frame(height: layout.height)
    }

    private func draw(_ context: inout GraphicsContext) {
        let ink = Color.primary
        let graph = layout.height - StormRules.axisH
        for mark in layout.marks {
            context.stroke(Path { $0.move(to: CGPoint(x: mark.x, y: 0)); $0.addLine(to: CGPoint(x: mark.x, y: graph)) }, with: .color(ink.opacity(0.1)), lineWidth: 1)
            context.draw(Text(mark.label).font(.system(size: 9, weight: .medium)).foregroundStyle(ink.opacity(0.55)),
                         at: CGPoint(x: mark.x, y: layout.height - 8))
        }
        context.stroke(Path { $0.move(to: CGPoint(x: 0, y: graph)); $0.addLine(to: CGPoint(x: layout.width, y: graph)) }, with: .color(ink.opacity(0.25)), lineWidth: 1)
        if let nowX = layout.nowX {
            context.stroke(Path { $0.move(to: CGPoint(x: nowX, y: 0)); $0.addLine(to: CGPoint(x: nowX, y: graph)) },
                           with: .color(ink.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            context.draw(Text(CoreStrings.t("now").uppercased()).font(.system(size: 8)).foregroundStyle(ink.opacity(0.55)),
                         at: CGPoint(x: nowX - 3, y: 8), anchor: .trailing)
        }
        for edge in layout.edges {
            var path = Path()
            path.move(to: CGPoint(x: edge.from.0, y: edge.from.1))
            path.addCurve(to: CGPoint(x: edge.to.0, y: edge.to.1), control1: CGPoint(x: edge.from.0 + edge.bend, y: edge.from.1),
                          control2: CGPoint(x: edge.to.0 - edge.bend, y: edge.to.1))
            context.stroke(path, with: .color(Color(red: 0x78 / 255, green: 0x71 / 255, blue: 0x6c / 255).opacity(0.85)), lineWidth: 2)
        }
        for node in layout.nodes {
            let rect = CGRect(x: node.x - StormRules.nodeW / 2, y: node.y - StormRules.nodeH / 2, width: StormRules.nodeW, height: StormRules.nodeH)
            let fill: Color = node.isSelf ? (dark ? Color(white: 0.2) : Color(red: 0xf5 / 255, green: 0xf5 / 255, blue: 0xf4 / 255)) : (dark ? Color(white: 0.08) : .white)
            context.fill(Path(roundedRect: rect, cornerRadius: 7), with: .color(fill))
            context.stroke(Path(roundedRect: rect, cornerRadius: 7), with: .color(Color(uiColor: StormStyle.colour(node.severity))), lineWidth: node.isSelf ? 2.5 : 1.5)
            context.draw(Text(node.peak.isEmpty ? node.at : node.peak).font(.system(size: 10, weight: .semibold)).foregroundStyle(ink),
                         at: CGPoint(x: node.x, y: node.y + 1))
            if !node.badge.isEmpty {
                context.draw(Text(node.badge).font(.system(size: 10, weight: .bold)).foregroundStyle(Color(uiColor: StormStyle.colour(node.severity))),
                             at: CGPoint(x: node.x + 24, y: node.y - 9))
            }
        }
    }
}

/// Lays capsules out in rows that wrap, as core's flex-wrap does.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += row + spacing
                x = 0
                row = 0
            }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += row + spacing
                x = bounds.minX
                row = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}
