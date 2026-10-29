//
//  LayerSwitcher.swift
//  meteocool
//
//  The layers button's panel: core's maps as tiles (`McLayerSwitcher.svelte`,
//  `MiniMap.svelte`), and what the radar map draws over the radar, which
//  core keeps in its settings (`SettingsDialog.svelte`).
//

import SwiftUI

struct LayerSwitcherView: View {
    @ObservedObject var model: NativeMapModel
    let isOn: (NativeMapLayer) -> Bool
    let setOn: (NativeMapLayer, Bool) -> Void
    let fromStart: Binding<Bool>
    let choose: (NativeMapModel.Capability) -> Void
    let close: () -> Void

    /// Bumped on a switch, so the rows read the stored values again.
    @State private var revision = 0

    private struct Tile: Identifiable {
        let id: NativeMapModel.Capability
        let label: String
    }

    private var tiles: [Tile] {
        [
            Tile(id: .radar, label: "🌧 " + CoreStrings.t("rain_and_thunderstorms")),
            Tile(id: .cells3d, label: "⛰ " + CoreStrings.t("storm_cells_3d")),
            Tile(id: .precipitationTypes, label: "💧 " + CoreStrings.t("precipitation_types")),
            Tile(id: .lightning, label: "⚡️ " + CoreStrings.t("lightning")),
        ]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    grid
                    section(CoreStrings.t("rain_and_thunderstorms")) {
                        toggle(CoreStrings.t("chrome.playback.lightning"), .lightning)
                        toggle(CoreStrings.t("chrome.playback.mesocyclones"), .mesocyclones)
                        toggle(CoreStrings.t("chrome.playback.cells"), .storms)
                        toggle(CoreStrings.t("chrome.playback.radar_sites"), .sites)
                        toggle(CoreStrings.t("stations.title"), .stations)
                    }
                    section(CoreStrings.t("settings.playback")) {
                        Toggle(CoreStrings.t("settings.playback_from_start"), isOn: fromStart)
                            .accessibilityIdentifier("nativeMap.layers.fromStart")
                    }
                    section(CoreStrings.t("settings.map_3d")) {
                        toggle(CoreStrings.t("settings.konrad_cells"), .cells3d)
                        toggle(CoreStrings.t("settings.terrain"), .terrain3d)
                    }
                }
                .padding(16)
            }
            .navigationTitle(CoreStrings.t("chrome.layer_switcher"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: close) { Image(systemName: "xmark") }
                        .accessibilityLabel(CoreStrings.t("close"))
                        .accessibilityIdentifier("nativeMap.layers.close")
                }
            }
        }
        // A container: its own children keep their identifiers.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nativeMap.layers")
    }

    /// The hero across the top, the rest two across; an odd one out spans its row.
    private var grid: some View {
        let rest = Array(tiles.dropFirst())
        let spans = rest.count % 2 == 1
        return VStack(spacing: 10) {
            tile(tiles[0], height: 150)
            if spans, let first = rest.first { tile(first, height: 110) }
            let pairs = Array(spans ? rest.dropFirst() : rest[...])
            ForEach(Array(stride(from: 0, to: pairs.count, by: 2)), id: \.self) { i in
                HStack(spacing: 10) {
                    tile(pairs[i], height: 110)
                    if i + 1 < pairs.count { tile(pairs[i + 1], height: 110) }
                }
            }
        }
    }

    private func tile(_ tile: Tile, height: CGFloat) -> some View {
        let active = model.capability == tile.id
        return Button { choose(tile.id) } label: {
            // The tile's size is its own; the picture fills it and is cut to it.
            Color.secondary.opacity(0.15)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .overlay {
                    // A storm on that map, as it draws one (`LayerPreview-*`,
                    // taken by `testCaptureLayerPreviews`): what its colours
                    // mean, where a tint over the view said nothing.
                    Image("LayerPreview-\(tile.id.rawValue)").resizable().scaledToFill()
                }
                .overlay {
                    // The label's ground.
                    LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
                }
                .overlay(alignment: .bottomLeading) {
                    Text(tile.label)
                        .scaledFont(15, weight: .semibold, relativeTo: .subheadline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                        .padding(10)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(active ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: active ? 3 : 1))
                // Clipping draws the picture to the tile but leaves its taps
                // where it was filled to, over the tiles around it.
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(tile.label)
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityIdentifier("nativeMap.layers.map.\(tile.id.rawValue)")
    }

    private func section(_ title: String, @ViewBuilder _ rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).scaledFont(17, weight: .bold, relativeTo: .body)
            VStack(spacing: 12) { rows() }
                .padding(14)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func toggle(_ label: String, _ layer: NativeMapLayer) -> some View {
        Toggle(label, isOn: Binding(get: { _ = revision; return isOn(layer) },
                                    set: { setOn(layer, $0); revision += 1 }))
            .accessibilityIdentifier("nativeMap.layers.\(layer.rawValue)")
    }
}
