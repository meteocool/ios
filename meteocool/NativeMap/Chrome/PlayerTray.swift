//
//  PlayerTray.swift
//  meteocool
//
//  core's player tray (`NowcastPlayback.svelte`): the place, the radar
//  product, the timeline strip, play and the legend.
//

import SwiftUI

/// What the tray's buttons do, supplied by the map.
struct TrayActions {
    var showForMyLocation: () -> Void = {}
    var openProducts: () -> Void = {}
    var openStormKey: () -> Void = {}
}

/// The tray at the bottom of the radar map.
struct PlayerTray: View {
    @ObservedObject var player: RadarPlayer
    @ObservedObject var model: NativeMapModel
    /// Site mode: one radar's own sweep, its controls where the timeline was.
    @ObservedObject var site: SiteSweepState
    let actions: TrayActions

    init(player: RadarPlayer, model: NativeMapModel, actions: TrayActions) {
        self.player = player
        self.model = model
        site = model.site
        self.actions = actions
    }

    private var theme: ChromeTheme { ChromeTheme(dark: model.isDark) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            head
            // With a radar open the strip scrubs its sweeps as it scrubs frames.
            TimelineStrip(player: player, theme: theme)
            HStack(spacing: 6) {
                PlayButton(player: player, theme: theme)
                Group {
                    if let mode = site.mode, mode.quantity != .reflectivity {
                        VelocityLegend(nyquist: site.view?.nyquist, relative: mode.quantity == .srv, theme: theme)
                    } else {
                        RadarLegend(palette: player.palette, dbz: $model.legendDBZ, theme: theme)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(.top, 6)
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
        .frame(height: 168)
        .chromeGlass(theme, in: RoundedRectangle(cornerRadius: ChromeTheme.trayRadius, style: .continuous), strong: true)
        .environment(\.colorScheme, theme.colorScheme)
        // A container: its own children keep their identifiers.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nativeMap.player")
    }

    /// The place the bars are for, a way back to your own, and the product.
    private var head: some View {
        HStack(spacing: 10) {
            if let title = model.trayTitle {
                Text(title)
                    .scaledFont(13, weight: .bold, relativeTo: .footnote)
                    .tracking(-0.13)
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("nativeMap.title")
            }
            if model.point != nil, model.userLocation != nil {
                Button(action: actions.showForMyLocation) {
                    Label(CoreStrings.t("show_for_my_location"), systemImage: "location.viewfinder")
                        .scaledFont(12, weight: .semibold, relativeTo: .caption)
                        .labelStyle(ChipLabel())
                        .foregroundStyle(theme.accent)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 9)
                        .background(theme.accentTint, in: Capsule())
                }
                .buttonStyle(PressScale())
                .accessibilityIdentifier("nativeMap.showForMyLocation")
            }
            Spacer(minLength: 0)
            // What the storm marks are, while they are drawn.
            if model.layersOn.contains(.storms) {
                StormKeyPill(model: model, filtered: !model.hiddenStormMarks.isEmpty || !model.layersOn.contains(.mesocyclones),
                             theme: theme, open: actions.openStormKey)
            }
            ProductPill(player: player, theme: theme, site: site.mode.map { _ in site.view }, open: actions.openProducts)
            if model.point != nil, model.userLocation == nil {
                Button(action: actions.showForMyLocation) {
                    Image(systemName: "xmark")
                        .scaledFont(13, weight: .semibold, relativeTo: .footnote)
                        .foregroundStyle(theme.text3)
                        .frame(width: 30, height: 30)
                        .background(theme.tint, in: Circle())
                }
                .buttonStyle(PressScale())
                .accessibilityLabel(CoreStrings.t("close"))
                .accessibilityIdentifier("nativeMap.clearPoint")
            }
        }
        .padding(.leading, 8)
        .frame(minHeight: 28)
    }
}

private struct ChipLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.scaledFont(11, weight: .semibold, relativeTo: .caption2)
            configuration.title
        }
    }
}

/// Play or pause, disabled where there is nothing to play (`canPlay`).
struct PlayButton: View {
    @ObservedObject var player: RadarPlayer
    let theme: ChromeTheme

    var body: some View {
        let enabled = player.playing || player.canPlay
        Button(action: player.togglePlay) {
            Image(systemName: player.playing ? "pause.fill" : "play.fill")
                .scaledFont(15, weight: .semibold, relativeTo: .subheadline)
                .offset(x: player.playing ? 0 : 2)
                .foregroundStyle(enabled ? Color.white : theme.text3)
                .frame(width: ChromeTheme.control, height: ChromeTheme.control)
                .background(enabled ? theme.accent : theme.tintActive, in: Circle())
        }
        .buttonStyle(PressScale())
        .disabled(!enabled)
        .accessibilityLabel(player.playing ? NSLocalizedString("native_map_pause", comment: "") : CoreStrings.t("chrome.playback.play"))
        .accessibilityValue(player.playing ? "playing" : "paused")
        .accessibilityIdentifier("nativeMap.play")
    }
}

/// The colour scale (`RadarScaleLine.svelte`): pictograms, or dBZ values,
/// a tap switching between them.
struct RadarLegend: View {
    let palette: String
    @Binding var dbz: Bool
    let theme: ChromeTheme

    /// RVP6 values from 5 dBZ up, as core's legend starts there.
    private static let from = 75

    private var table: (leftPad: Int, rgba: [UInt32]) {
        ColormapTables.tables[palette] ?? ColormapTables.tables["classic"]!
    }
    private var high: Double { Double(table.leftPad + table.rgba.count - 1) / 2 - 32.5 }
    private static let low = Double(from) / 2 - 32.5

    var body: some View {
        Button { dbz.toggle() } label: {
            VStack(spacing: 2) {
                Capsule()
                    .fill(LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing))
                    .background(theme.tint, in: Capsule())
                    .overlay(Capsule().stroke(theme.edge, lineWidth: 1))
                    .frame(height: 10)
                    .padding(.top, 2)
                GeometryReader { geometry in
                    if dbz { ticks(width: geometry.size.width) } else { pictograms }
                }
                .frame(height: 14)
            }
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(CoreStrings.t(dbz ? "chrome.scales.show_pictograms" : "chrome.scales.show_dbz"))
        .accessibilityHint(CoreStrings.t("chrome.scales.colormap", ["name": CoreStrings.t("settings.color_maps.\(palette)"),
                                                                     "min": Int(Self.low), "max": Int(high)]))
        .accessibilityIdentifier("nativeMap.legend")
    }

    private var stops: [Gradient.Stop] {
        let table = self.table
        let first = max(Self.from, table.leftPad)
        let last = table.leftPad + table.rgba.count - 1
        guard last > first else { return [] }
        return stride(from: first, through: last, by: 2).map { value in
            let packed = table.rgba[value - table.leftPad]
            let colour = Color(red: Double(packed >> 24) / 255, green: Double((packed >> 16) & 0xFF) / 255,
                               blue: Double((packed >> 8) & 0xFF) / 255, opacity: Double(packed & 0xFF) / 255)
            return Gradient.Stop(color: colour, location: Double(value - first) / Double(last - first))
        }
    }

    /// Drizzle, rain, heavy rain, hail: selectors spread along the scale,
    /// not positions on it.
    private var pictograms: some View {
        HStack {
            Color.clear.frame(width: 1)
            Spacer()
            ForEach(["LegendDrizzle", "LegendRain", "LegendHeavyRain", "LegendHail"], id: \.self) { name in
                Image(name)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(height: 13)
                    .foregroundStyle(theme.text)
                if name != "LegendHail" { Spacer() }
            }
        }
        .padding(.horizontal, 12)
        .accessibilityHidden(true)
    }

    /// Ticks every 10 dBZ where they fall, the last kept one marked "dBZ".
    private func ticks(width: CGFloat) -> some View {
        let values = stride(from: 10.0, to: high, by: 10).filter { ($0 - Self.low) / (high - Self.low) <= 0.95 }
        return ZStack(alignment: .topLeading) {
            ForEach(values, id: \.self) { value in
                let at = (value - Self.low) / (high - Self.low)
                HStack(spacing: 1) {
                    Text("\(Int(value))")
                        .scaledFont(11, weight: .semibold, relativeTo: .caption2, digits: true)
                        .foregroundStyle(theme.text)
                    if value == values.last {
                        Text("dBZ").scaledFont(8, weight: .medium, relativeTo: .caption2).foregroundStyle(theme.text2)
                    }
                }
                .fixedSize()
                .position(x: CGFloat(at) * width + (value == values.last ? 10 : 0), y: 7)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The radar product and how old its scans are (`RadarProductPicker` pill).
struct ProductPill: View {
    @ObservedObject var player: RadarPlayer
    let theme: ChromeTheme
    /// With a radar open, its sweep shown: the pill is about that radar.
    var site: SiteSweepView?? = nil
    let open: () -> Void

    var body: some View {
        if let site { sitePill(site) } else { productPill }
    }

    /// The open radar's name, and how long ago its sweep on screen was scanned.
    private func sitePill(_ view: SiteSweepView?) -> some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            Button(action: open) {
                HStack(spacing: 5) {
                    Image(systemName: "dot.radiowaves.left.and.right").scaledFont(12, weight: .semibold, relativeTo: .caption)
                    Text(view.map { RadarSiteAnnotation.name($0.site.site) } ?? "").truncationMode(.tail)
                    Text(Self.siteAge(view, now: context.date))
                        .scaledFont(11, weight: .medium, relativeTo: .caption2, digits: true)
                        .foregroundStyle(theme.text2)
                        .layoutPriority(1)
                }
                .scaledFont(11, weight: .semibold, relativeTo: .caption2)
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(theme.tint, in: Capsule())
            }
            .buttonStyle(PressScale())
        }
        .accessibilityLabel(CoreStrings.t("chrome.radar_product.choose") + ": " + (view.map { RadarSiteAnnotation.name($0.site.site) } ?? ""))
        .accessibilityIdentifier("nativeMap.productPill")
    }

    static func siteAge(_ view: SiteSweepView?, now: Date) -> String {
        guard let iso = view?.startedAt ?? view?.scannedAt, let at = SiteSweepRules.seconds(iso) else {
            return CoreStrings.t("chrome.radar_product.unavailable")
        }
        return CoreStrings.t("chrome.radar_product.age", ["minutes": max(0, Int(((now.timeIntervalSince1970 - at) / 60).rounded()))])
    }

    @ViewBuilder
    private var productPill: some View {
        let timeline = player.timeline
        let forecast = player.step.map(timeline.isForecast) ?? false
        let product = forecast ? RadarProduct.hx : timeline.drawn
        TimelineView(.periodic(from: .now, by: 15)) { context in
            Button(action: open) {
                HStack(spacing: 5) {
                    Image(systemName: "antenna.radiowaves.left.and.right").scaledFont(12, weight: .semibold, relativeTo: .caption)
                    Text(CoreStrings.t("chrome.radar_product.\(product.rawValue)_short"))
                    Group {
                        if forecast {
                            Text(CoreStrings.t("chrome.radar_product.forecast_short"))
                        } else if timeline.fellBack {
                            Text(CoreStrings.t("chrome.radar_product.fell_back_short")).foregroundStyle(theme.orangeInk)
                        } else {
                            Text(Self.age(timeline.scanRange, now: context.date))
                        }
                    }
                    .scaledFont(11, weight: .medium, relativeTo: .caption2, digits: true)
                    .foregroundStyle(theme.text2)
                }
                .scaledFont(11, weight: .semibold, relativeTo: .caption2)
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(theme.tint, in: Capsule())
            }
            .buttonStyle(PressScale())
            .disabled(forecast)
            .opacity(forecast ? 0.5 : 1)
        }
        .accessibilityLabel(CoreStrings.t("chrome.radar_product.choose"))
        .accessibilityIdentifier("nativeMap.productPill")
    }

    /// "3 min ago", "3–8 min ago", "unavailable" (`age`, `ageSpan`).
    static func age(_ range: (freshest: Int, stalest: Int)?, now: Date) -> String {
        guard let range else { return CoreStrings.t("chrome.radar_product.unavailable") }
        let seconds = now.timeIntervalSince1970
        let from = max(0, Int((seconds - Double(range.freshest)) / 60))
        let to = max(0, Int((seconds - Double(range.stalest)) / 60))
        if from == to { return CoreStrings.t("chrome.radar_product.age", ["minutes": from]) }
        return CoreStrings.t("chrome.radar_product.age_span", ["from": from, "to": to])
    }
}
