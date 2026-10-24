//
//  ChartSkeleton.swift
//  meteocool
//
//  core's `ChartSkeleton.svelte`, for the charts that load on demand.
//

import SwiftUI

/// Placeholder bars while a chart's data is on its way (core's
/// `ChartSkeleton`): a fixed silhouette, a crest of brightness running
/// along it every 2.6 s; still under Reduce Motion.
struct ChartSkeleton: View {
    let bars: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let heights = LightningRules.skeletonHeights(bars)
        let stagger = (900.0 / Double(max(bars, 1))).rounded() / 1000
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { geometry in
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(0 ..< bars, id: \.self) { i in
                        UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2, style: .continuous)
                            .fill(PointStyle.tint)
                            .frame(height: max(0, geometry.size.height - 18) * heights[i] / 100)
                            .opacity(reduceMotion ? 0.5 : Self.wave(t - Double(i) * stagger))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 18)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The keyframes: 0.55, up to 1 at 14 %, back to 0.55 by 34 %, resting after.
    static func wave(_ t: Double) -> Double {
        let phase = (t.truncatingRemainder(dividingBy: 2.6) + 2.6).truncatingRemainder(dividingBy: 2.6) / 2.6
        if phase < 0.14 { return 0.55 + 0.45 * ease(phase / 0.14) }
        if phase < 0.34 { return 1 - 0.45 * ease((phase - 0.14) / 0.2) }
        return 0.55
    }

    private static func ease(_ x: Double) -> Double {
        // Close to core's cubic-bezier(0.2, 0.8, 0.2, 1): fast out, long settle.
        1 - pow(1 - x, 3)
    }
}
