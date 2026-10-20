//
//  ChromeTheme.swift
//  meteocool
//
//  core's glass chrome (`glass.css`) as SwiftUI colours and backgrounds.
//

import SwiftUI

/// core's chrome tokens: light or dark after the base map, not the system
/// (core's `html[data-chrome]`), so the controls read on the map under them.
struct ChromeTheme {
    let dark: Bool

    var text: Color { dark ? .white : Color(red: 0x1c / 255, green: 0x1c / 255, blue: 0x1e / 255) }
    var text2: Color { dark ? Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255).opacity(0.82) : Color(red: 60 / 255, green: 60 / 255, blue: 67 / 255).opacity(0.84) }
    var text3: Color { dark ? Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255).opacity(0.62) : Color(red: 60 / 255, green: 60 / 255, blue: 67 / 255).opacity(0.66) }
    var tint: Color { dark ? Color.white.opacity(0.14) : Color(red: 60 / 255, green: 60 / 255, blue: 67 / 255).opacity(0.10) }
    var tintActive: Color { dark ? Color.white.opacity(0.30) : Color(red: 60 / 255, green: 60 / 255, blue: 67 / 255).opacity(0.22) }
    var accent: Color { dark ? Color(red: 0x0a / 255, green: 0x84 / 255, blue: 1) : Color(red: 0, green: 0x7a / 255, blue: 1) }
    var accentTint: Color { dark ? Color(red: 10 / 255, green: 132 / 255, blue: 1).opacity(0.24) : Color(red: 0, green: 122 / 255, blue: 1).opacity(0.14) }
    var red: Color { dark ? Color(red: 1, green: 0x45 / 255, blue: 0x3a / 255) : Color(red: 1, green: 0x3b / 255, blue: 0x30 / 255) }
    var redDim: Color { red.opacity(0.45) }
    var redVeil: Color { red.opacity(dark ? 0.32 : 0.28) }
    var orange: Color { dark ? Color(red: 1, green: 0x9f / 255, blue: 0x0a / 255) : Color(red: 1, green: 0x95 / 255, blue: 0) }
    var orangeInk: Color { dark ? Color(red: 1, green: 0xb3 / 255, blue: 0x40 / 255) : Color(red: 0x9a / 255, green: 0x5a / 255, blue: 0) }
    var brand: Color { Color(red: 0x8b / 255, green: 0xcd / 255, blue: 0xd8 / 255) }
    var preloadOpacity: Double { dark ? 0.09 : 0.20 }
    var fill: Color { dark ? Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255).opacity(0.82) : Color.white.opacity(0.82) }
    var fillStrong: Color { dark ? Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255).opacity(0.90) : Color.white.opacity(0.90) }
    var edge: Color { dark ? Color.white.opacity(0.22) : Color.white.opacity(0.70) }
    var colorScheme: ColorScheme { dark ? .dark : .light }

    /// Corner radii and sizes (`glass.css:189-215`).
    static let trayRadius: CGFloat = 26
    static let cardRadius: CGFloat = 22
    static let pillHeight: CGFloat = 28
    static let control: CGFloat = 40
    static let gutter: CGFloat = 8
    /// How far in from the right the app's own button column reaches (its
    /// 52 pt discs, 12 pt from the edge, and 12 pt clear of them): where a
    /// wide screen's side panel stops.
    static let controlColumn: CGFloat = 76
    static let stripHeight: CGFloat = 104
}

extension View {
    /// core's glass: Liquid Glass where there is one, else a material with
    /// core's fill over it, so text never sits on bare blur.
    func chromeGlass<S: Shape>(_ theme: ChromeTheme, in shape: S, strong: Bool = false) -> some View {
        modifier(ChromeGlass(theme: theme, shape: shape, strong: strong))
    }
}

private struct ChromeGlass<S: Shape>: ViewModifier {
    let theme: ChromeTheme
    let shape: S
    let strong: Bool
    @Environment(\.accessibilityReduceTransparency) private var solid

    func body(content: Content) -> some View {
        if solid {
            content.background((theme.dark ? Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255) : Color.white).opacity(0.94), in: shape)
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(strong ? theme.fillStrong : theme.fill, in: shape)
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(theme.edge, lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 15, y: 10)
        }
    }
}

/// A press that shrinks a little, as core's controls do (`--mc-press` .96).
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The drawers' glass (`--mc-drawer-fill`, `--mc-drawer-backdrop`): a blur
/// darkened or lightened enough that a sheet over the radar stays readable;
/// solid where transparency is reduced.
struct DrawerBackground: View {
    let dark: Bool
    @Environment(\.accessibilityReduceTransparency) private var solid

    var body: some View {
        if solid {
            (dark ? Color(red: 30 / 255, green: 33 / 255, blue: 40 / 255) : Color(red: 246 / 255, green: 246 / 255, blue: 248 / 255))
        } else {
            ZStack {
                Rectangle().fill(.regularMaterial)
                (dark ? Color(red: 30 / 255, green: 34 / 255, blue: 42 / 255).opacity(0.62) : Color(red: 250 / 255, green: 250 / 255, blue: 252 / 255).opacity(0.8))
            }
        }
    }
}
