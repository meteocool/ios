//
//  ThreeDGuide.swift
//  meteocool
//
//  What the 3D map's marks mean and how to move it (core's `Guide3D.svelte`),
//  opened from its tray's "Legend" pill. The swatches come from the palette
//  and the constants the map paints with; the controls are a touch screen's.
//  Core's "Boxes" and "Faint" are left out: this map draws neither.
//

import SwiftUI

struct ThreeDGuide: View {
    let palette: String
    /// The KONRAD3D layer is on: its cells are on the map to explain.
    let cellsShown: Bool
    let close: () -> Void

    private func colour(_ dbz: Double) -> Color {
        let rgb = Colormaps.colour(dbz: dbz, palette: palette)
        return Color(red: Double(rgb.x) / 255, green: Double(rgb.y) / 255, blue: Double(rgb.z) / 255)
    }

    var body: some View {
        NavigationStack {
            List {
                Section(CoreStrings.t("guide_3d.legend")) {
                    item(CoreStrings.t("guide_3d.clouds"), CoreStrings.t("guide_3d.clouds_body")) {
                        LinearGradient(colors: stride(from: 10.0, through: 70, by: 5).map(colour), startPoint: .leading, endPoint: .trailing)
                            .frame(width: 44, height: 14)
                            .clipShape(Capsule())
                            .accessibilityLabel(CoreStrings.t("guide_3d.scale_aria", ["min": 10, "max": 70]))
                    }
                    item(CoreStrings.t("guide_3d.cut"), CoreStrings.t("guide_3d.cut_body")) {
                        CutSwatch(shells: [colour(20), colour(40), colour(55)]).frame(width: 32, height: 24)
                    }
                    item(CoreStrings.t("guide_3d.ground"), CoreStrings.t("guide_3d.ground_body")) {
                        RoundedRectangle(cornerRadius: 3).fill(colour(30).opacity(Double(ThreeDPaint.radarOpacity) * 1.6)).frame(width: 44, height: 14)
                    }
                    item(CoreStrings.t("guide_3d.lightning"),
                         CoreStrings.t("guide_3d.lightning_body", ["minutes": Int(ThreeDPaint.strikeMinutes)])) {
                        Image(systemName: "bolt.fill").foregroundStyle(Color(red: 1, green: 0.82, blue: 0.4)).frame(width: 44)
                    }
                    if cellsShown {
                        item(CoreStrings.t("guide_3d.cells"), CoreStrings.t("guide_3d.cells_body")) {
                            HStack(spacing: 3) {
                                ForEach(0 ..< 4, id: \.self) { band in
                                    RoundedRectangle(cornerRadius: 2)
                                        .stroke(Color(uiColor: StormStyle.colour(band)), lineWidth: 2)
                                        .frame(width: 8, height: 14)
                                        .accessibilityLabel(CoreStrings.t("storm.band.\(StormRules.bandNames[band])"))
                                }
                            }
                        }
                        .accessibilityIdentifier("nativeMap.3d.guide.cells")
                    }
                    Text(CoreStrings.t("guide_3d.heights", ["scale": String(ThreeDScale.vertical)]))
                        .scaledFont(13, relativeTo: .footnote)
                        .foregroundStyle(.secondary)
                }
                Section(CoreStrings.t("guide_3d.controls")) {
                    control(CoreStrings.t("guide_3d.drag"), CoreStrings.t("guide_3d.move"), symbol: "hand.draw")
                    control(NSLocalizedString("native_map_3d_pinch", comment: ""), CoreStrings.t("guide_3d.zoom"), symbol: "arrow.up.left.and.arrow.down.right")
                    control(NSLocalizedString("native_map_3d_two_fingers", comment: ""), CoreStrings.t("guide_3d.turn"), symbol: "rotate.3d")
                    control(NSLocalizedString("native_map_3d_tap", comment: ""), CoreStrings.t("guide_3d.click_storm"), symbol: "hand.tap")
                    control(CoreStrings.t("guide_3d.compass"), CoreStrings.t("guide_3d.compass_does"), symbol: "location.north.line")
                    control("3D", NSLocalizedString("native_map_3d_tilt", comment: ""), symbol: "view.3d")
                }
            }
            .navigationTitle(CoreStrings.t("guide_3d.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: close) { Image(systemName: "xmark") }
                        .accessibilityLabel(CoreStrings.t("close"))
                        .accessibilityIdentifier("nativeMap.3d.guide.close")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nativeMap.3d.guide")
    }

    private func item(_ title: String, _ body: String, @ViewBuilder swatch: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 12) {
            swatch().frame(width: 44, alignment: .leading).padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).scaledFont(15, weight: .semibold, relativeTo: .subheadline)
                Text(body).scaledFont(13, relativeTo: .footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func control(_ gesture: String, _ does: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 44)
            Text(gesture).scaledFont(15, weight: .semibold, relativeTo: .subheadline)
            Spacer()
            Text(does).scaledFont(13, relativeTo: .footnote).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A cut storm: the near half gone, the face it leaves standing (core's swatch).
private struct CutSwatch: View {
    let shells: [Color]

    var body: some View {
        Canvas { context, size in
            let sx = size.width / 32, sy = size.height / 24
            for (i, (rx, ry, opacity)) in [(12.0, 9.0, 0.55), (7.0, 6.0, 0.85), (3.5, 3.2, 1.0)].enumerated() {
                let rect = CGRect(x: (16 - rx) * sx, y: (12 - ry) * sy, width: 2 * rx * sx, height: 2 * ry * sy)
                var path = Path()
                path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2, startAngle: .degrees(90),
                            endAngle: .degrees(270), clockwise: false)
                path.closeSubpath()
                let squash = CGAffineTransform(translationX: 0, y: rect.midY).scaledBy(x: 1, y: ry / rx).translatedBy(x: 0, y: -rect.midY)
                context.fill(path.applying(squash), with: .color(shells[i].opacity(opacity)))
            }
            var line = Path()
            line.move(to: CGPoint(x: 16 * sx, y: 2 * sy))
            line.addLine(to: CGPoint(x: 16 * sx, y: 22 * sy))
            context.stroke(line, with: .color(.primary.opacity(0.7)), lineWidth: 1.2)
        }
        .accessibilityHidden(true)
    }
}
