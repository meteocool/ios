//
//  ArchiveFrame.swift
//  meteocool
//
//  A past window, said by the screen's own edge (core's
//  `ArchiveFrame.svelte`): a graphite frame round the map, and on the top
//  line a tab that names the step and leads to the picker and back to live.
//

import SwiftUI

/// The graphite frame round the map while a past window is open, so nobody
/// takes the archive for now, not even in a screenshot passed on. Drawn in
/// the content layer, under every control and taking no touches: below the
/// status bar, its top corners rounded, its bottom ones concentric with the
/// screen's. Its ink follows the map's brightness, as core's does. Always
/// there and only faded in, so leaving the archive is seen too.
struct ArchiveFrame: View {
    @ObservedObject var model: NativeMapModel

    /// The band's width and its top corners (`--mc-archive-frame-w`, `--mc-archive-radius-top`).
    static let width: CGFloat = 4
    static let radius: CGFloat = 18

    /// core's graphite: near black on a light map, near white on a dark one.
    private var ink: Color {
        model.isDark ? Color(red: 0xe5 / 255, green: 0xe5 / 255, blue: 0xea / 255)
            : Color(red: 0x1c / 255, green: 0x1c / 255, blue: 0x1e / 255)
    }

    var body: some View {
        GeometryReader { geometry in
            ink
                .mask {
                    ZStack {
                        Rectangle()
                        hole(homeIndicator: geometry.safeAreaInsets.bottom > 0)
                            .padding(Self.width)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
                }
        }
        .ignoresSafeArea(edges: [.horizontal, .bottom])
        .opacity(model.window != nil ? 1 : 0)
        .animation(.easeOut(duration: 0.25), value: model.window != nil)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func hole(homeIndicator: Bool) -> some View {
        if #available(iOS 26.0, *) {
            ConcentricRectangle(uniformTopCorners: .fixed(Self.radius), uniformBottomCorners: .concentric(minimum: .fixed(Self.radius)))
        } else {
            // A screen with a home indicator has rounder corners (core's
            // `--mc-archive-radius` on such a phone).
            let bottom = homeIndicator ? 56 - Self.width : Self.radius
            UnevenRoundedRectangle(topLeadingRadius: Self.radius, bottomLeadingRadius: bottom,
                                   bottomTrailingRadius: bottom, topTrailingRadius: Self.radius, style: .continuous)
        }
    }
}

/// The frame's tab on the top line, in the status pill's place: the step on
/// screen, which opens the picker to choose another window, and a cross back
/// to live. A phone shows the step's date and time alone, to fit between
/// the logo's row and the buttons on the right; a wide screen also names the
/// window, its day and span, and the step by its clock.
struct ArchiveTab: View {
    let window: RadarWindow
    let step: Int?
    let theme: ChromeTheme
    let choose: () -> Void
    let live: () -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let shown = step ?? window.end
        HStack(spacing: 6) {
            Button(action: choose) {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .scaledFont(12, weight: .semibold, relativeTo: .caption)
                        .foregroundStyle(theme.accent)
                    // Squeezed between the logo's row and the buttons at the
                    // largest text: the step's clock alone, never a cut date.
                    ViewThatFits(in: .horizontal) {
                        Text(label(shown))
                        Text(StatusPill.clock(shown))
                    }
                    .scaledFont(13, weight: .semibold, relativeTo: .footnote, digits: true)
                    .lineLimit(1)
                }
                .foregroundStyle(theme.text)
                .padding(.horizontal, 12)
                .frame(height: ChromeTheme.pillHeight)
                .chromeGlass(theme, in: Capsule(), interactive: true)
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScale())
            .accessibilityLabel(CoreStrings.t("chrome.archive.title") + ", " + RadarWindow.dateTime(shown, weekday: true))
            .accessibilityHint(CoreStrings.t("chrome.archive.choose"))
            .accessibilityIdentifier("nativeMap.archive.tab")
            Button(action: live) {
                Image(systemName: "xmark")
                    .scaledFont(12, weight: .bold, relativeTo: .caption)
                    .foregroundStyle(theme.text)
                    .frame(width: ChromeTheme.pillHeight, height: ChromeTheme.pillHeight)
                    .chromeGlass(theme, in: Circle(), interactive: true)
                    .hitTarget()
            }
            .buttonStyle(PressScale())
            .accessibilityLabel(CoreStrings.t("chrome.archive.pill_live", ["time": RadarWindow.dateTime(shown, weekday: true)]))
            .accessibilityIdentifier("nativeMap.archive.tab.live")
        }
        .environment(\.colorScheme, theme.colorScheme)
    }

    private func label(_ step: Int) -> String {
        guard sizeClass == .regular else { return RadarWindow.dateTime(step) }
        return [CoreStrings.t("chrome.archive.title"), window.span(), window.clock(step)].joined(separator: " · ")
    }
}
