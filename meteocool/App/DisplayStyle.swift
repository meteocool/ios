import SwiftUI
import UIKit

enum DisplayStyle: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var labelKey: String {
        switch self {
        case .system:
            return "display_style_system"
        case .light:
            return "display_style_light"
        case .dark:
            return "display_style_dark"
        }
    }

    var localizedLabel: String {
        NSLocalizedString(labelKey, comment: "")
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .light:
            return .light
        case .dark:
            return .dark
        case .system:
            return nil
        }
    }

    static func from(_ value: String) -> DisplayStyle {
        DisplayStyle(rawValue: value) ?? .system
    }

    @MainActor
    static func applyToAllWindows(_ style: DisplayStyle) {
        let uiStyle: UIUserInterfaceStyle
        switch style {
        case .light:
            uiStyle = .light
        case .dark:
            uiStyle = .dark
        case .system:
            uiStyle = .unspecified
        }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = uiStyle
            }
        }
    }
}
