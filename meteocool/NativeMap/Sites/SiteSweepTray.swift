//
//  SiteSweepTray.swift
//  meteocool
//
//  Site mode's controls, in the player's tray while a radar is open (core's
//  `SiteSweepTray.svelte`), and the legend of radial velocity
//  (`VelocityScaleLine.svelte`).
//

import SwiftUI

/// What to draw of the open radar, at which tilt, the sweep's own scan
/// time, and the way out. Each tilt is offered with how high its beam is
/// 100 km out; a velocity sweep says whether the server could dealias it,
/// because a fold looks exactly like a couplet.
struct SiteSweepTray: View {
    @ObservedObject var state: SiteSweepState
    /// Whether Escape may close the radar: nothing over it is what the key is for.
    let escapes: Bool
    let theme: ChromeTheme

    var body: some View {
        if let mode = state.mode {
            let name = CoreStrings.t("site.title", ["name": RadarSiteAnnotation.name(mode.site)])
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(name)
                        .scaledFont(13, weight: .bold, relativeTo: .footnote)
                        .tracking(-0.13)
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if let status = status(state.view) {
                        Text(status)
                            .scaledFont(11, weight: .medium, relativeTo: .caption2, digits: true)
                            .foregroundStyle(theme.text2)
                            .lineLimit(1)
                            .accessibilityIdentifier("nativeMap.site.status")
                    }
                    Spacer(minLength: 0)
                    Button(action: state.close) {
                        Image(systemName: "xmark")
                            .scaledFont(13, weight: .semibold, relativeTo: .footnote)
                            .foregroundStyle(theme.text3)
                            .frame(width: 30, height: 30)
                            .background(theme.tint, in: Circle())
                            .hitTarget()
                    }
                    .buttonStyle(PressScale())
                    .keyboardShortcut(escapes ? .cancelAction : nil)
                    .accessibilityLabel(CoreStrings.t("site.close"))
                    .accessibilityIdentifier("nativeMap.site.close")
                }
                .padding(.leading, 8)
                Picker(CoreStrings.t("site.quantity.group"), selection: quantity(mode)) {
                    ForEach(quantities, id: \.self) { quantity in
                        Text(CoreStrings.t("site.quantity.\(quantity.rawValue)")).tag(quantity)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("nativeMap.site.quantity")
                HStack(spacing: 8) {
                    if let tilts = state.view?.tilts, !tilts.isEmpty {
                        tiltMenu(tilts, mode)
                    }
                    if let note = note(mode) {
                        Text(note.text)
                            .scaledFont(11, weight: .medium, relativeTo: .caption2)
                            .foregroundStyle(note.warn ? theme.orangeInk : theme.text2)
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                            .accessibilityIdentifier("nativeMap.site.note")
                    }
                    Spacer(minLength: 0)
                }
                if mode.quantity == .srv, let view = state.view {
                    MotionRow(state: state, view: view, theme: theme)
                }
            }
            // A container: its own children keep their identifiers.
            .accessibilityElement(children: .contain)
            .accessibilityLabel(name)
            .accessibilityIdentifier("nativeMap.site")
        }
    }

    private var quantities: [SiteQuantity] {
        state.view?.hasVelocity == true ? SiteQuantity.allCases : [.reflectivity]
    }

    private func quantity(_ mode: SiteMode) -> Binding<SiteQuantity> {
        Binding(get: { mode.quantity }, set: { quantity in state.mode?.quantity = quantity })
    }

    /// The tilts in a menu, each with how high its beam is 100 km out.
    private func tiltMenu(_ tilts: [OfferedTilt], _ mode: SiteMode) -> some View {
        let chosen = tilts.min { abs($0.elevation - mode.elevation) < abs($1.elevation - mode.elevation) } ?? tilts[0]
        return Menu {
            Picker(CoreStrings.t("site.tilt"), selection: Binding(get: { chosen.elevation },
                                                                   set: { elevation in state.mode?.elevation = elevation })) {
                ForEach(tilts, id: \.elevation) { tilt in
                    Text(SiteSweepRules.tiltLabel(tilt.elevation, tilt.beamKmAt100)).tag(tilt.elevation)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(SiteSweepRules.tiltLabel(chosen.elevation, chosen.beamKmAt100))
                    .scaledFont(12, weight: .medium, relativeTo: .caption, digits: true)
                Image(systemName: "chevron.up.chevron.down")
                    .scaledFont(9, weight: .semibold, relativeTo: .caption2)
            }
            .foregroundStyle(theme.text)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(theme.tint, in: Capsule())
            .hitTarget()
        }
        .accessibilityLabel(CoreStrings.t("site.tilt"))
        .accessibilityValue(SiteSweepRules.tiltLabel(chosen.elevation, chosen.beamKmAt100))
        .accessibilityIdentifier("nativeMap.site.tilt")
    }

    /// When the sweep was scanned, or why there is none.
    private func status(_ view: SiteSweepView?) -> String? {
        guard let view else { return nil }
        switch view.status {
        case .none: return CoreStrings.t("site.none")
        case .failed: return CoreStrings.t("site.failed")
        case .loading, .shown:
            guard let iso = view.startedAt ?? view.scannedAt, let seconds = SiteSweepRules.seconds(iso) else { return nil }
            let time = Date(timeIntervalSince1970: seconds).formatted(.dateTime.hour(.twoDigits(amPM: .abbreviated)).minute().second()
                .locale(Locale(identifier: CoreStrings.language)))
            return CoreStrings.t("site.scanned", ["time": time])
        }
    }

    /// What the server says of the fold, or that SRV needs a storm.
    private func note(_ mode: SiteMode) -> (text: String, warn: Bool)? {
        guard let view = state.view else { return nil }
        // Storm-relative with nothing to take out: no storm, no motion set.
        if mode.quantity == .srv && view.srv.source == .manual && view.srv.motion.speedMs == 0 {
            return (CoreStrings.t("site.srv_hint"), false)
        }
        guard mode.quantity != .reflectivity else { return nil }
        if view.dealiased == true { return (CoreStrings.t("site.dealiased"), false) }
        if view.dealiased == false { return (CoreStrings.t("site.not_dealiased"), true) }
        return nil
    }
}

/// What storm-relative velocity takes out (core's `StormMotion.svelte`): a
/// row saying whose motion and how fast, which opens a dial for the heading
/// and a stepper for the speed, and a choice of the storm's or one's own.
struct MotionRow: View {
    @ObservedObject var state: SiteSweepState
    let view: SiteSweepView
    let theme: ChromeTheme
    private var open: Bool { state.motionOpen }

    private var shown: ManualMotion { SrvMotionRules.editBase(view.srv, manual: state.manual) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { state.motionOpen.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "location.north.fill")
                        .rotationEffect(.degrees(shown.headingDeg))
                        .foregroundStyle(theme.accent)
                    Text(line)
                        .scaledFont(12, weight: .medium, relativeTo: .caption, digits: true)
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(open ? 180 : 0))
                        .foregroundStyle(theme.text3)
                }
                .scaledFont(11, weight: .semibold, relativeTo: .caption2)
                .padding(.horizontal, 10)
                .frame(minHeight: 32)
                .background(theme.tint, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(PressScale())
            .accessibilityLabel(CoreStrings.t("site.motion.edit"))
            .accessibilityValue(line)
            .accessibilityHint(CoreStrings.t("site.motion.title"))
            .accessibilityIdentifier("nativeMap.site.motion")
            if open { editor }
        }
    }

    private var line: String {
        CoreStrings.t("site.motion.line", [
            "source": view.srv.source == .manual ? CoreStrings.t("site.motion.manual") : view.stormName ?? CoreStrings.t("storm.storm_label.unclassed"),
            "speed": Int(shown.speedKmh),
            "direction": CoreStrings.t("storm.compass.\(SrvMotionRules.compassPoint(shown.headingDeg))"),
        ])
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            if view.stormMoves {
                Picker(CoreStrings.t("site.motion.source"), selection: Binding(get: { view.srv.source },
                                                                               set: { state.prefersManual = $0 == .manual })) {
                    Text(CoreStrings.t("site.motion.storm")).tag(SrvMotion.Source.storm)
                    Text(CoreStrings.t("site.motion.by_hand")).tag(SrvMotion.Source.manual)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("nativeMap.site.motion.source")
            }
            HStack(alignment: .center, spacing: 16) {
                MotionDial(heading: shown.headingDeg, theme: theme) { state.editMotion(heading: $0) }
                    .frame(width: 96, height: 96)
                VStack(alignment: .leading, spacing: 6) {
                    Text(CoreStrings.t("site.motion.speed"))
                        .scaledFont(11, weight: .medium, relativeTo: .caption2)
                        .foregroundStyle(theme.text2)
                    Stepper(value: Binding(get: { shown.speedKmh }, set: { next in
                        state.editMotion(speed: SrvMotionRules.stepSpeed(shown.speedKmh, direction: next > shown.speedKmh ? 1 : -1))
                    }), in: 0 ... SrvMotionRules.maxSpeedKmh, step: SrvMotionRules.speedStep) {
                        Text("\(Int(shown.speedKmh)) km/h")
                            .scaledFont(15, weight: .semibold, relativeTo: .subheadline, digits: true)
                            .foregroundStyle(theme.text)
                    }
                    .accessibilityLabel(CoreStrings.t("site.motion.speed"))
                    .accessibilityValue("\(Int(shown.speedKmh)) km/h")
                    .accessibilityIdentifier("nativeMap.site.motion.speed")
                }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

/// The heading as a compass dial: an arrow from its centre the way the storm
/// goes, turned by a finger anywhere on it, in five-degree clicks.
struct MotionDial: View {
    let heading: Double
    let theme: ChromeTheme
    let turn: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let centre = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            ZStack {
                Circle().fill(theme.tint)
                Circle().stroke(theme.edge, lineWidth: 1)
                ForEach(["N", "E", "S", "W"], id: \.self) { point in
                    let angle = ["N": 0.0, "E": 90, "S": 180, "W": 270][point]! * .pi / 180
                    Text(CoreStrings.t("storm.compass.\(point)"))
                        .scaledFont(9, weight: .semibold, relativeTo: .caption2)
                        .foregroundStyle(theme.text3)
                        .position(x: centre.x + sin(angle) * side * 0.38, y: centre.y - cos(angle) * side * 0.38)
                }
                Image(systemName: "location.north.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: side * 0.32)
                    .foregroundStyle(theme.accent)
                    .rotationEffect(.degrees(heading))
            }
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let dx = Double(value.location.x - centre.x), dy = Double(value.location.y - centre.y)
                guard let next = SrvMotionRules.headingFromPoint(dx: dx, dy: dy), next != heading else { return }
                UISelectionFeedbackGenerator().selectionChanged()
                turn(next)
            })
        }
        .accessibilityElement()
        .accessibilityLabel(CoreStrings.t("site.motion.heading"))
        .accessibilityValue("\(Int(heading))° " + CoreStrings.t("storm.compass.\(SrvMotionRules.compassPoint(heading))"))
        .accessibilityAdjustableAction { direction in
            turn(SrvMotionRules.turnHeading(heading, steps: direction == .increment ? 1 : -1))
        }
        .accessibilityIdentifier("nativeMap.site.motion.dial")
    }
}

/// The open radar's controls as a glass card over the player (core's pill
/// over it): the player keeps its height and its timeline.
struct SiteSweepCard: View {
    @ObservedObject var state: SiteSweepState
    @ObservedObject var model: NativeMapModel

    var body: some View {
        let theme = ChromeTheme(dark: model.isDark)
        SiteSweepTray(state: state, escapes: model.selectedStorm == nil && model.covers.isEmpty, theme: theme)
            .padding(EdgeInsets(top: 10, leading: 6, bottom: 12, trailing: 10))
            .chromeGlass(theme, in: RoundedRectangle(cornerRadius: ChromeTheme.trayRadius, style: .continuous), strong: true)
            .environment(\.colorScheme, theme.colorScheme)
            .padding(.horizontal, ChromeTheme.gutter)
    }
}

/// The legend for a radar's radial velocity: toward the radar green, away
/// red, across the sweep's own Nyquist velocity, which is as fast a wind as
/// that tilt measures at all. Ticks every 5 m/s, every 10 on a narrow tray
/// past 20.
struct VelocityLegend: View {
    /// The sweep's Nyquist velocity in m/s, or nil when unknown.
    let nyquist: Double?
    /// Storm-relative: the same colours, the storm's motion taken out.
    let relative: Bool
    let theme: ChromeTheme
    @Environment(\.horizontalSizeClass) private var sizeClass

    private static let fallback = 30.0
    private static let steps = 40

    private var span: Double { min(60, max(5, nyquist ?? Self.fallback)) }

    var body: some View {
        HStack(spacing: 8) {
            Text(CoreStrings.plain(relative ? "site.legend.srv" : "site.legend.velocity"))
                .scaledFont(9, weight: .medium, relativeTo: .caption2)
                .foregroundStyle(theme.text2)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .fixedSize()
            VStack(spacing: 2) {
                Capsule()
                    .fill(LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing))
                    .background(theme.tint, in: Capsule())
                    .overlay(Capsule().stroke(theme.edge, lineWidth: 1))
                    .frame(height: 10)
                    .padding(.top, 2)
                GeometryReader { geometry in ticks(width: geometry.size.width) }
                    .frame(height: 14)
            }
        }
        .frame(height: 28)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(CoreStrings.plain(relative ? "site.legend.srv" : "site.legend.velocity"))
        .accessibilityValue(String(format: "±%.0f m/s", span))
        .accessibilityHint(CoreStrings.t("site.legend.hint"))
        .accessibilityIdentifier("nativeMap.site.legend")
    }

    private var stops: [Gradient.Stop] {
        (0 ... Self.steps).map { i in
            let v = -span + 2 * span * Double(i) / Double(Self.steps)
            let c = VelocityPalette.table[Sweep.velocityByte(v)]
            return Gradient.Stop(color: Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255),
                                 location: Double(i) / Double(Self.steps))
        }
    }

    private func ticks(width: CGFloat) -> some View {
        let every = sizeClass == .compact && span > 20 ? 10.0 : 5.0
        let count = Int(span / every)
        let values = (-count ... count).map { Double($0) * every }
        return ZStack(alignment: .topLeading) {
            ForEach(values, id: \.self) { value in
                Text(value > 0 ? "+\(Int(value))" : "\(Int(value))")
                    .scaledFont(10, weight: .semibold, relativeTo: .caption2, digits: true)
                    .foregroundStyle(theme.text)
                    .fixedSize()
                    .position(x: CGFloat((value + span) / (2 * span)) * width, y: 7)
            }
        }
        .accessibilityHidden(true)
    }
}
