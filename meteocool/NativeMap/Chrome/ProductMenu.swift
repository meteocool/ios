//
//  ProductMenu.swift
//  meteocool
//
//  core's radar product menu (`RadarProductPicker.svelte`).
//

import SwiftUI

/// Each product's newest scan, from its own endpoint (`/v3/radar/europe`,
/// `/colmax`, `/dmax`), for the menu's ages.
@MainActor
final class ProductScans: ObservableObject {
    @Published var newest: [RadarProduct: Int] = [:]

    func load(_ map: NativeMapContext) {
        let paths: [RadarProduct: String] = [.merged: "europe", .colmax: "colmax", .dmax: "dmax"]
        for (product, path) in paths {
            map.fetch(map.endpoints.api.appendingPathComponent("v3/radar/\(path)")) { [weak self] data, _ in
                guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let scan = (object["upstream_time"] as? NSNumber)?.intValue ?? (object["processed_time"] as? NSNumber)?.intValue else { return }
                self?.newest[product] = scan
            }
        }
    }
}

/// The menu: the products in their two groups, each with its newest scan's
/// age, the chosen one ticked; "?" opens the explainer.
struct ProductMenu: View {
    @ObservedObject var player: RadarPlayer
    @ObservedObject var model: NativeMapModel
    @ObservedObject var scans: ProductScans
    let close: () -> Void
    let explain: () -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(RadarProduct.groups, id: \.group) { group in
                    Section {
                        ForEach(group.products, id: \.self) { product in row(product) }
                    } header: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(CoreStrings.t("chrome.radar_product.group_\(group.group)"))
                                Spacer()
                                if group.group == "lowest" {
                                    Text(CoreStrings.t("chrome.radar_product.age_heading")).scaledFont(10, weight: .semibold, relativeTo: .caption2)
                                }
                            }
                            Text(CoreStrings.t("chrome.radar_product.group_\(group.group)_hint"))
                                .scaledFont(11, weight: .medium, relativeTo: .caption2)
                                .textCase(nil)
                        }
                    }
                }
                if player.timeline.fellBack {
                    Text(CoreStrings.t("chrome.radar_product.fell_back", [
                        "product": CoreStrings.t("chrome.radar_product.\(model.product.rawValue)"),
                        "fallback": CoreStrings.t("chrome.radar_product.hx"),
                    ]))
                    .scaledFont(12, weight: .medium, relativeTo: .caption)
                    .foregroundStyle(.orange)
                }
            }
            .navigationTitle(CoreStrings.t("chrome.radar_product.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: explain) { Image(systemName: "questionmark.circle") }
                        .accessibilityLabel(CoreStrings.t("radar_help.open"))
                        .accessibilityIdentifier("nativeMap.productHelp")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: close) { Image(systemName: "xmark") }
                        .accessibilityLabel(CoreStrings.t("close"))
                }
            }
        }
        // A container: its own children keep their identifiers.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nativeMap.productMenu")
    }

    private func row(_ product: RadarProduct) -> some View {
        Button {
            model.product = product
            close()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "checkmark")
                    .scaledFont(13, weight: .bold, relativeTo: .footnote)
                    .foregroundStyle(.tint)
                    .opacity(model.product == product ? 1 : 0)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(CoreStrings.t("chrome.radar_product.\(product.rawValue)_option")).scaledFont(14, weight: .semibold, relativeTo: .subheadline)
                    Text(CoreStrings.t("chrome.radar_product.\(product.rawValue)_hint")).scaledFont(12, weight: .medium, relativeTo: .caption)
                        .foregroundStyle(.secondary)
                    Text(CoreStrings.t("chrome.radar_product.\(product.rawValue)_grid")).scaledFont(11, weight: .medium, relativeTo: .caption2, digits: true)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    Text(age(product, now: context.date))
                        .scaledFont(12, weight: .semibold, relativeTo: .caption, digits: true)
                        .foregroundStyle(behind(product) ? Color.orange : Color.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(model.product == product ? .isSelected : [])
        .accessibilityIdentifier("nativeMap.product.\(product.rawValue)")
    }

    private var hxScan: Int? { player.timeline.now }

    private func age(_ product: RadarProduct, now: Date) -> String {
        if product == .hx, player.timeline.drawn == .hx { return ProductPill.age(player.timeline.scanRange, now: now) }
        let scan = product == .hx ? hxScan : scans.newest[product]
        return ProductPill.age(scan.map { ($0, $0) }, now: now)
    }

    /// A product too far behind HX to be drawn (`fallsBehind`).
    private func behind(_ product: RadarProduct) -> Bool {
        guard product != .hx else { return false }
        guard let scan = scans.newest[product] else { return true }
        guard let hx = hxScan else { return false }
        return hx - scan > product.allowedBehind
    }
}
