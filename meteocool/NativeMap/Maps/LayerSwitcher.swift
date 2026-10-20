//
//  LayerSwitcher.swift
//  meteocool
//
//  The layers button's panel: core's maps as tiles (`McLayerSwitcher.svelte`,
//  `MiniMap.svelte`), and what the radar map draws over the radar, which
//  core keeps in its settings (`SettingsDialog.svelte`).
//

import MapKit
import SwiftUI

/// Pictures of the view for the tiles, taken as the panel opens.
@MainActor
final class LayerSnapshots: ObservableObject {
    @Published var flat: UIImage?
    @Published var tilted: UIImage?

    func take(region: MKCoordinateRegion, size: CGSize, dark: Bool) {
        let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        func options(_ pitched: Bool) -> MKMapSnapshotter.Options {
            let options = MKMapSnapshotter.Options()
            options.region = region
            options.size = size
            options.traitCollection = traits
            options.pointOfInterestFilter = .excludingAll
            if pitched {
                let camera = MKMapCamera(lookingAtCenter: region.center, fromDistance: region.span.latitudeDelta * 111_000 * 1.6,
                                         pitch: 60, heading: 0)
                options.camera = camera
                options.mapType = .hybridFlyover
            }
            return options
        }
        MKMapSnapshotter(options: options(false)).start { [weak self] snapshot, _ in
            Task { @MainActor in self?.flat = snapshot?.image }
        }
        MKMapSnapshotter(options: options(true)).start { [weak self] snapshot, _ in
            Task { @MainActor in self?.tilted = snapshot?.image }
        }
    }
}

struct LayerSwitcherView: View {
    @ObservedObject var model: NativeMapModel
    @ObservedObject var snapshots: LayerSnapshots
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
        let tint: Color
    }

    private var tiles: [Tile] {
        [
            Tile(id: .radar, label: "🌧 " + CoreStrings.t("rain_and_thunderstorms"), tint: .blue),
            Tile(id: .cells3d, label: "⛰ " + CoreStrings.t("storm_cells_3d"), tint: .purple),
            Tile(id: .precipitationTypes, label: "💧 " + CoreStrings.t("precipitation_types"), tint: .cyan),
            Tile(id: .lightning, label: "⚡️ " + CoreStrings.t("lightning"), tint: .yellow),
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
                        toggle(CoreStrings.t("settings.meteocool_nowcast"), .nowcast)
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
        let image = tile.id == .cells3d ? snapshots.tilted ?? snapshots.flat : snapshots.flat
        return Button { choose(tile.id) } label: {
            // The tile's size is its own; the picture fills it and is cut to it.
            Color.secondary.opacity(0.15)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .overlay {
                    if let image { Image(uiImage: image).resizable().scaledToFill() }
                }
                .overlay {
                    LinearGradient(colors: [tile.tint.opacity(0.0), tile.tint.opacity(0.35), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                }
                .overlay(alignment: .bottomLeading) {
                    Text(tile.label)
                        .font(.system(size: 15, weight: .semibold))
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
                // where it was filled to: the 3D map's tilted snapshot took
                // the taps of the tile above it.
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(tile.label)
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityIdentifier("nativeMap.layers.map.\(tile.id.rawValue)")
    }

    private func section(_ title: String, @ViewBuilder _ rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 17, weight: .bold))
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
