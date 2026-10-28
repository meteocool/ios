//
//  SourceBadge.swift
//  meteocool
//
//  Whose tracking a storm is, as a small chip (core's `SourceBadge.svelte`):
//  "DWD" or "meteocool", with the shape the flat map draws that storm's
//  position in, so the chip and the mark it was tapped on say the same thing.
//

import SwiftUI

struct SourceBadge: View {
    let source: StormSource
    /// Quieter, for a second source behind the one the readings are from.
    var secondary = false

    /// DWD's own blue, so the chip reads as their product at a glance.
    static let dwdBlue = Color(red: 0x1D / 255, green: 0x5C / 255, blue: 0xA8 / 255)

    var body: some View {
        HStack(spacing: 4) {
            Group {
                if source == .dwd {
                    Rectangle().rotation(.degrees(45)).scale(0.72)
                } else {
                    Circle().scale(0.8)
                }
            }
            .frame(width: 8, height: 8)
            Text(CoreStrings.t("storm.source.\(source.rawValue)"))
                .scaledFont(11, weight: .bold, relativeTo: .caption2)
        }
        .foregroundStyle(source == .dwd ? Color.white : Color.accentColor)
        .padding(.horizontal, 6)
        .frame(minHeight: 18)
        .background(source == .dwd ? Self.dwdBlue : Color.accentColor.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .opacity(secondary ? 0.55 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(CoreStrings.t("storm.source.\(source.rawValue)_long"))
        .accessibilityIdentifier("nativeMap.storm.source.\(source.rawValue)")
    }
}

/// A selection's sources in a row, the lead one first.
struct SourceBadges: View {
    let sources: [StormSource]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(sources.enumerated()), id: \.element) { index, source in
                SourceBadge(source: source, secondary: index > 0)
            }
        }
    }
}
