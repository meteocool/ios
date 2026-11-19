//
//  StormKey.swift
//  meteocool
//
//  What the storm marks on the flat map mean (core's `StormKey.svelte`),
//  behind a pill in the player: DWD's diamonds and meteocool's circles, the
//  colours, rings, paths, dotted joins, badges and "3D" tags. Each row turns
//  its mark off the map, and each strength chip its storms
//  (`hiddenStormMarks`); the lightning and the mesocyclones are layers of
//  their own, switched here because they are read with the storms. With the
//  storm marks off in the layer switcher the key keeps just those two, so
//  they can still be switched. The pill carries a dot while any is off.
//
//  A sheet rather than core's popover card: it is looked up, not read
//  alongside the map, and a sheet is the phone's way of doing that.
//

import SwiftUI

/// The pill in the tray that opens the key: a diamond and a circle, and a
/// dot while anything is turned off.
struct StormKeyPill: View {
    @ObservedObject var model: NativeMapModel
    let filtered: Bool
    let theme: ChromeTheme
    let open: () -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ScaledMetric(relativeTo: .caption2) private var scale: CGFloat = 1

    var body: some View {
        let metrics = ChipMetrics.of(sizeClass)
        let mark = metrics.icon / 11 * scale
        Button(action: open) {
            HStack(spacing: 5) {
                HStack(spacing: 2) {
                    Diamond().fill(Color(uiColor: StormStyle.colour(2))).frame(width: 9 * mark, height: 9 * mark)
                    Circle().fill(Color(uiColor: StormStyle.colour(1))).frame(width: 8 * mark, height: 8 * mark)
                }
                Text(CoreStrings.t("storm.key.pill"))
                if filtered {
                    Circle().fill(theme.accent).frame(width: 6 * mark, height: 6 * mark)
                }
            }
            .scaledFont(metrics.font, weight: .semibold, relativeTo: .caption2)
            .foregroundStyle(theme.text)
            .chip(theme, metrics)
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(CoreStrings.t("storm.key.open"))
        .accessibilityValue(filtered ? CoreStrings.t("storm.key.title") : "")
        .accessibilityIdentifier("nativeMap.stormKey.pill")
    }
}

/// The key itself.
struct StormKeyView: View {
    @ObservedObject var model: NativeMapModel
    /// The mesocyclones' layer switch, which the key's last row is.
    let mesocyclones: Binding<Bool>
    /// The lightning's layer switch, the last row of what holds everywhere.
    let lightning: Binding<Bool>
    let close: () -> Void

    /// The storm marks are drawn: their rows are in the key.
    private var storms: Bool { model.layersOn.contains(.storms) }

    private let strong = Color(uiColor: StormStyle.colour(2))
    private let moderate = Color(uiColor: StormStyle.colour(1))

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if storms { stormRows }
                    let lightningKept = NativeMapLayer.lightning.hasPast || model.window == nil
                    item(CoreStrings.t("storm.key.lightning"),
                         CoreStrings.t(lightningKept ? "storm.key.lightning_body" : "chrome.archive.no_past"), on: lightning,
                         id: "lightning", disabled: !lightningKept) {
                        Image("MapLightning").resizable().scaledToFit().frame(width: 20, height: 20)
                    }
                }
                // What DWD's tracking adds, over Germany alone.
                Section(CoreStrings.t("storm.key.germany_only")) {
                    if storms { dwdRows }
                    // DWD keeps no series of them: in a past window there are none to show.
                    let kept = NativeMapLayer.mesocyclones.hasPast || model.window == nil
                    item(CoreStrings.t("storm.key.mesocyclone"),
                         CoreStrings.t(kept ? "storm.key.mesocyclone_body" : "chrome.archive.no_past"), on: mesocyclones,
                         id: "mesocyclone", disabled: !kept) {
                        Image("MapMesocyclone").resizable().scaledToFit().frame(width: 20, height: 20)
                    }
                }
            }
            .navigationTitle(CoreStrings.t("storm.key.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: close) { Image(systemName: "xmark") }
                        .accessibilityLabel(CoreStrings.t("close"))
                        .accessibilityIdentifier("nativeMap.stormKey.close")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nativeMap.stormKey")
    }

    /// meteocool's storms, their strengths and what is drawn round them.
    @ViewBuilder
    private var stormRows: some View {
        row(.meteocool, badge: .meteocool) { Circle().fill(strong).overlay(Circle().stroke(.white, lineWidth: 1.5)).frame(width: 14) }
        strength
        row(.live) {
            ZStack {
                Circle().stroke(style: StrokeStyle(lineWidth: 1.6, dash: [3.2, 2.6])).foregroundStyle(.secondary).frame(width: 20)
                Circle().fill(moderate).overlay(Circle().stroke(.white, lineWidth: 1.5)).frame(width: 10)
            }
        }
        row(.path) {
            HStack(spacing: 0) {
                Capsule().fill(moderate).frame(width: 16, height: 3).rotationEffect(.degrees(-20))
                Circle().fill(moderate).frame(width: 9)
            }
        }
        row(.join) {
            Capsule().stroke(style: StrokeStyle(lineWidth: 2.2, lineCap: .round, dash: [0.1, 5])).foregroundStyle(moderate)
                .frame(width: 26, height: 1).rotationEffect(.degrees(-25))
        }
        row(.volume) {
            HStack(spacing: 2) {
                Image(systemName: "cube.fill").foregroundStyle(strong).imageScale(.small)
                Text("3D").scaledFont(9, weight: .bold, relativeTo: .caption2)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.background, in: Capsule())
            .overlay(Capsule().stroke(.secondary.opacity(0.4)))
        }
    }

    /// DWD's storms and what its tracking adds to them.
    @ViewBuilder
    private var dwdRows: some View {
        row(.dwd, badge: .dwd) { Diamond().fill(strong).overlay(Diamond().stroke(.white, lineWidth: 1.5)).frame(width: 16, height: 16) }
        row(.hail) { badged("✦", rim: Color(uiColor: StormStyle.hail)) }
        row(.rotation) { badged("↻", rim: .white) }
        row(.forecast) {
            ZStack {
                Ellipse().stroke(style: StrokeStyle(lineWidth: 1.6, dash: [4, 3])).foregroundStyle(moderate).frame(width: 24, height: 16)
                Ellipse().stroke(style: StrokeStyle(lineWidth: 1.6, dash: [4, 3])).foregroundStyle(moderate).frame(width: 12, height: 8)
                    .offset(x: -5)
            }
        }
    }

    /// Strength: a chip for each band, each turning its storms off and on.
    private var strength: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                HStack(spacing: 2) {
                    ForEach(0 ..< 4, id: \.self) { band in
                        Circle().fill(Color(uiColor: StormStyle.colour(band))).frame(width: 6)
                    }
                }
                .frame(width: 34)
                Text(CoreStrings.t("storm.key.strength")).scaledFont(15, weight: .semibold, relativeTo: .subheadline)
            }
            HStack(spacing: 6) {
                ForEach(0 ..< 4, id: \.self) { band in
                    let mark = StormMarkToggle(rawValue: StormRules.bandNames[band])!
                    let shown = !model.hiddenStormMarks.contains(mark)
                    Button {
                        flip(mark)
                    } label: {
                        HStack(spacing: 4) {
                            Circle().fill(Color(uiColor: StormStyle.colour(band))).frame(width: 8)
                            Text(CoreStrings.t("storm.band.\(StormRules.bandNames[band])"))
                        }
                        .scaledFont(12, weight: .medium, relativeTo: .caption)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 28)
                        .background(shown ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.1), in: Capsule())
                        .foregroundStyle(shown ? Color.primary : Color.secondary)
                        .opacity(shown ? 1 : 0.6)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(shown ? .isSelected : [])
                    .accessibilityIdentifier("nativeMap.stormKey.band.\(mark.rawValue)")
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func row(_ mark: StormMarkToggle, badge: StormSource? = nil, @ViewBuilder swatch: () -> some View) -> some View {
        let on = Binding(get: { !model.hiddenStormMarks.contains(mark) }, set: { _ in flip(mark) })
        return item(CoreStrings.t("storm.key.\(mark.rawValue)"), CoreStrings.t("storm.key.\(mark.rawValue)_body"), on: on,
                    id: mark.rawValue, badge: badge, swatch: swatch)
    }

    private func item(_ title: String, _ body: String, on: Binding<Bool>, id: String, badge: StormSource? = nil, disabled: Bool = false,
                      @ViewBuilder swatch: () -> some View) -> some View {
        Toggle(isOn: on) {
            HStack(alignment: .top, spacing: 12) {
                swatch().frame(width: 34, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).scaledFont(15, weight: .semibold, relativeTo: .subheadline)
                        if let badge { SourceBadge(source: badge) }
                    }
                    Text(body).scaledFont(13, relativeTo: .footnote).foregroundStyle(.secondary)
                }
            }
            .opacity(on.wrappedValue && !disabled ? 1 : 0.55)
        }
        .disabled(disabled)
        .accessibilityLabel(CoreStrings.t("storm.key.show", ["mark": title]))
        .accessibilityIdentifier("nativeMap.stormKey.\(id)")
    }

    private func badged(_ glyph: String, rim: Color) -> some View {
        VStack(spacing: 0) {
            Text(glyph).scaledFont(11, weight: .bold, relativeTo: .caption2).foregroundStyle(strong)
            Diamond().fill(strong).overlay(Diamond().stroke(rim, lineWidth: 2)).frame(width: 12, height: 12)
        }
    }

    private func flip(_ mark: StormMarkToggle) {
        if model.hiddenStormMarks.contains(mark) { model.hiddenStormMarks.remove(mark) } else { model.hiddenStormMarks.insert(mark) }
    }
}

/// A square stood on its corner: how DWD's storms are marked.
struct Diamond: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}
