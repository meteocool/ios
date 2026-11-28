//
//  BackFrom3D.swift
//  meteocool
//
//  The way back from a detour to the 3D map (core's `BackFrom3D.svelte`).
//

import SwiftUI

/// "Back to main map", under the top line's middle while the 3D map is a
/// detour: a 3D tag on the flat map, or a storm panel's "open on the 3D
/// map", took the reader there to look at one storm (`lib/open3d.ts`).
/// Without it the way back is the layer switcher, which says nothing about
/// having come from the radar. Closing the storm no longer goes back by
/// itself: a reader closes one storm to look at the next. Where the reader
/// picked the 3D map themselves there is nothing to go back to, and the
/// map hides the button.
struct BackFrom3D: View {
    @ObservedObject var model: NativeMapModel
    let back: () -> Void

    var body: some View {
        let theme = ChromeTheme(dark: model.isDark)
        Button(action: back) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.left")
                    .scaledFont(12, weight: .semibold, relativeTo: .footnote)
                    .foregroundStyle(theme.accent)
                Text(CoreStrings.t("guide_3d.back_to_map"))
                    .scaledFont(13, weight: .semibold, relativeTo: .footnote)
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
            }
            .padding(.leading, 12)
            .padding(.trailing, 14)
            .frame(minHeight: 32)
            .chromeGlass(theme, in: Capsule(), interactive: true)
            .hitTarget()
        }
        .buttonStyle(PressScale())
        .environment(\.colorScheme, theme.colorScheme)
        .accessibilityLabel(CoreStrings.t("guide_3d.back_to_map"))
        .accessibilityIdentifier("nativeMap.3d.back")
    }
}
