//
//  PointStyle.swift
//  meteocool
//
//  core's glass tokens (`glass.css`) for what the held point and the other
//  maps float over the map: ink, accent, tints, and the glass itself.
//

import SwiftUI
import UIKit

/// The light and dark values of core's chrome tokens. Over the map they
/// follow the base map, not the system (core's `data-chrome`): the views
/// set `colorScheme` from `NativeMapModel.isDark`, and these resolve by it.
enum PointStyle {
    private static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    private static func token(_ light: UIColor, _ dark: UIColor) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    /// `--mc-chrome-text` and its two quieter steps.
    static let text = token(rgb(0x1C1C1E), rgb(0xFFFFFF))
    static let text2 = token(rgb(0x3C3C43, 0.84), rgb(0xEBEBF5, 0.82))
    static let text3 = token(rgb(0x3C3C43, 0.66), rgb(0xEBEBF5, 0.62))
    static let accent = token(rgb(0x007AFF), rgb(0x0A84FF))
    static let accentTint = token(rgb(0x007AFF, 0.14), rgb(0x0A84FF, 0.24))
    /// Flat controls on glass, at rest, hovered and pressed.
    static let tint = token(rgb(0x3C3C43, 0.10), rgb(0xFFFFFF, 0.14))
    static let tintActive = token(rgb(0x3C3C43, 0.22), rgb(0xFFFFFF, 0.30))
    static let red = token(rgb(0xFF3B30), rgb(0xFF453A))
    static let separator = token(rgb(0x3C3C43, 0.29), rgb(0x545458, 0.6))
    static let hairline = token(rgb(0x3C3C43, 0.22), rgb(0x545458, 0.65))
    /// The models' lines behind the median (`--mc-plot-thicket`).
    static let thicket = token(rgb(0x3C3C43, 0.16), rgb(0xEBEBF5, 0.18))
    /// The agreement capsules: fill and ink.
    static let greenTint = token(rgb(0x34C759, 0.18), rgb(0x30D158, 0.22))
    static let greenInk = token(rgb(0x1B7F3B), rgb(0x30D158))
    static let orangeTint = token(rgb(0xFF9500, 0.20), rgb(0xFF9F0A, 0.24))
    static let orangeInk = token(rgb(0x9A5A00), rgb(0xFFB340))
    static let redTint = token(rgb(0xFF3B30, 0.16), rgb(0xFF453A, 0.22))
    static let redInk = token(rgb(0xB3261E), rgb(0xFF6961))
    /// The swipe's "Hide" (`--mc-red-veil`, strong).
    static let redVeil = token(rgb(0xFF3B30, 0.28), rgb(0xFF453A, 0.32))
    static let redVeilStrong = token(rgb(0xFF3B30, 0.62), rgb(0xFF453A, 0.66))

    /// A palette entry as a colour.
    static func color(_ hex: UInt32) -> Color {
        Color(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    /// core's motion: 120 ms fade, 340 ms spring; none under Reduce Motion.
    static func spring(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.8)
    }
}

/// core's glass (`.glass`, the trays, the menus): Liquid Glass on iOS 26,
/// the thickest material before it, solid under Reduce Transparency.
struct PointGlass<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var solid
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        if solid {
            content.background(scheme == .dark ? Color(white: 0.11) : Color(white: 0.97), in: shape)
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.ultraThickMaterial, in: shape)
        }
    }
}

extension View {
    func pointGlass<S: Shape>(_ shape: S) -> some View { modifier(PointGlass(shape: shape)) }

    /// A tray's glass: core's 26 pt corners.
    func pointTray(radius: CGFloat = 26) -> some View {
        pointGlass(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// The table's strings: core's where it has them, ours where it does not.
enum PointText {
    static func local(_ key: String) -> String {
        NSLocalizedString("native_map_" + key, comment: "")
    }
}
