//
//  RadarExplainer.swift
//  meteocool
//
//  "How the Radar Works" (core's `RadarExplainer.svelte`).
//

import SwiftUI

/// core's reading panel on how the radars scan and when their pictures
/// reach the map, with its sweep and tilt diagrams drawn to core's numbers.
struct RadarExplainer: View {
    let palette: String
    let close: () -> Void

    private func t(_ key: String) -> String { CoreStrings.plain("radar_help.\(key)") }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(t("lede")).font(.body)
                    Text(t("measured")).font(.footnote).foregroundStyle(.secondary)

                    section("turn") {
                        paragraphs("turn", 2)
                        SweepDiagram(palette: palette).frame(height: 240)
                        Text(t("turn.caption")).font(.footnote).foregroundStyle(.secondary)
                        facts
                    }
                    section("tilts") {
                        paragraphs("tilts", 1)
                        Text(t("tilts.reach"))
                        TiltDiagram().frame(height: 220)
                        Text(t("tilts.caption")).font(.footnote).foregroundStyle(.secondary)
                        Text(t("tilts.p2"))
                        Text(t("tilts.p3"))
                    }
                    section("products") { paragraphs("products", 3) }
                    section("cycle") {
                        paragraphs("cycle", 3)
                        table(["pcp_done", "hx", "frame", "wn", "sweep_low", "vol_done", "dmax", "sweep_last", "clouds", "next_frame"],
                              heading: (t("times.what"), t("times.when"))) { (t("times.\($0)"), t("times.\($0)_at")) }
                        Text(t("times.note")).font(.footnote).foregroundStyle(.secondary)
                    }
                    section("made") {
                        Text(t("made.caption")).font(.footnote).foregroundStyle(.secondary)
                        ForEach(["de", "forecast", "types", "networks", "europe", "colmax", "cells", "clouds", "meso", "lightning"], id: \.self) { key in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t("made.\(key)")).font(.subheadline.weight(.semibold))
                                Text("\(t("made.from")): \(t("made.\(key)_from"))").font(.caption).foregroundStyle(.secondary)
                                Text(t("made.\(key)_how")).font(.callout)
                            }
                        }
                    }
                    section("why") { paragraphs("why", 3) }
                }
                .padding()
            }
            .navigationTitle(t("title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: close) { Image(systemName: "xmark") }
                        .accessibilityLabel(CoreStrings.t("close"))
                }
            }
        }
        .accessibilityIdentifier("nativeMap.explainer")
    }

    @ViewBuilder
    private func section(_ key: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("\(key).title")).font(.title3.weight(.bold)).padding(.top, 8)
            content()
        }
    }

    @ViewBuilder
    private func paragraphs(_ key: String, _ count: Int) -> some View {
        ForEach(1 ... count, id: \.self) { i in
            let text = t("\(key).p\(i)")
            if text != "radar_help.\(key).p\(i)" { Text(text) }
        }
    }

    private var facts: some View {
        HStack(alignment: .top) {
            ForEach(["rays", "bins", "sweep"], id: \.self) { key in
                VStack(alignment: .leading, spacing: 2) {
                    Text(t("turn.fact_\(key)")).font(.subheadline.weight(.semibold))
                    Text(t("turn.fact_\(key)_sub")).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func table(_ keys: [String], heading: (String, String), row: @escaping (String) -> (String, String)) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text(heading.0).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(heading.1).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            ForEach(keys, id: \.self) { key in
                let cells = row(key)
                GridRow {
                    Text(cells.0).font(.callout)
                    Text(cells.1).font(.callout.monospacedDigit())
                }
            }
        }
    }
}

/// One sweep from above: the beam turning once every eight seconds over
/// echoes in the radar's palette.
private struct SweepDiagram: View {
    let palette: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func colour(_ dbz: Double) -> Color {
        guard let rgb = RadarPalette.colour(dbz: dbz, palette: palette) else { return .gray }
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            Canvas { graphics, size in
                let radius = min(size.width, size.height) / 2 - 4
                let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                graphics.fill(Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)),
                              with: .color(.secondary.opacity(0.12)))
                for ring in 1 ... 3 {
                    let r = radius * CGFloat(ring) / 3
                    graphics.stroke(Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2)),
                                    with: .color(.secondary.opacity(0.3)), lineWidth: 0.5)
                }
                let echoes: [(Double, CGFloat, CGFloat, CGFloat)] = [(22, 0.55, -0.35, 0.28), (42, 0.6, -0.3, 0.14), (57, 0.62, -0.28, 0.06),
                                                                     (22, -0.4, 0.45, 0.2), (42, -0.42, 0.47, 0.08)]
                for (dbz, x, y, r) in echoes {
                    let c = CGPoint(x: centre.x + x * radius, y: centre.y + y * radius)
                    graphics.fill(Path(ellipseIn: CGRect(x: c.x - r * radius, y: c.y - r * radius, width: r * radius * 2, height: r * radius * 1.6)),
                                  with: .color(colour(dbz)))
                }
                let angle = reduceMotion ? 0.8 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 8) / 8 * 2 * .pi
                var beam = Path()
                beam.move(to: centre)
                beam.addLine(to: CGPoint(x: centre.x + cos(angle - .pi / 2) * radius, y: centre.y + sin(angle - .pi / 2) * radius))
                graphics.stroke(beam, with: .color(.blue), lineWidth: 2)
            }
        }
        .accessibilityLabel(CoreStrings.plain("radar_help.turn.caption"))
    }
}

/// The ten tilts from the side, drawn to scale with the 4/3 earth radius.
private struct TiltDiagram: View {
    /// DWD's ten tilts and how far each reaches, km.
    private static let tilts: [(Double, Double)] = [(0.5, 180), (1.5, 180), (2.5, 180), (3.5, 180), (4.5, 180), (5.5, 180),
                                                    (8, 124), (12, 60), (17, 60), (25, 60)]
    private static let earthKm = 4.0 / 3 * 6371

    /// A beam's centre above the ground at a range, km (`beamHeight`).
    static func beamHeight(range: Double, tilt: Double) -> Double {
        let t = tilt * .pi / 180
        return (range * range + earthKm * earthKm + 2 * range * earthKm * sin(t)).squareRoot() - earthKm
    }

    var body: some View {
        Canvas { graphics, size in
            let left: CGFloat = 28, bottom = size.height - 18, top: CGFloat = 6
            let x = { (km: Double) in left + (size.width - left - 6) * CGFloat(km / 180) }
            let y = { (h: Double) in bottom - (bottom - top) * CGFloat(h / 14) }
            graphics.stroke(Path { p in p.move(to: CGPoint(x: left, y: bottom)); p.addLine(to: CGPoint(x: size.width, y: bottom)) },
                            with: .color(.secondary), lineWidth: 1)
            for (tilt, reach) in Self.tilts {
                var beam = Path()
                beam.move(to: CGPoint(x: x(0), y: y(0)))
                var r = 0.0
                while r <= reach {
                    let h = Self.beamHeight(range: r, tilt: tilt)
                    if h > 14 { break }
                    beam.addLine(to: CGPoint(x: x(r), y: y(h)))
                    r += 2
                }
                graphics.stroke(beam, with: .color(tilt < 6 ? .blue : .teal), lineWidth: 1.2)
            }
            for km in stride(from: 0.0, through: 180, by: 60) {
                graphics.draw(Text("\(Int(km))").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: x(km), y: bottom + 9))
            }
            for h in [0.0, 5, 10] {
                graphics.draw(Text("\(Int(h))").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: left - 10, y: y(h)))
            }
        }
        .accessibilityLabel(CoreStrings.plain("radar_help.tilts.caption"))
    }
}
