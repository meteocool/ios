//
//  WebSettings.swift
//  meteocool
//
//  The settings the host pushes into the web map.
//

import Foundation

/// The one place that knows which stored settings the web map is told about.
///
/// Two web views read this now — the phone's map and CarPlay's — and a setting
/// that reaches one but not the other is a bug that only shows up in a car.
@MainActor
enum WebSettings {
    /// `window.settings.injectSettings({...})`, or nil if the dictionary
    /// cannot be serialized.
    ///
    /// The overlay layers (lightning, mesocyclones, snow) are deliberately
    /// absent: the web map owns those toggles and persists them itself, so
    /// injecting a native copy would overwrite the user's choice on every
    /// launch.
    static func injectionJS() -> String? {
        let defaults = UserDefaults(suiteName: "group.org.frcy.app.meteocool")
        let config = [
            "mapRotation": defaults?.value(forKey: "mapRotation"),
            "radarColorMapping": defaults?.value(forKey: "radarColorMapping"),
            "mapBaseLayer": defaults?.value(forKey: "baseLayer"),
            "experimentalFeatures": defaults?.value(forKey: "experimentalFeatures"),
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: config, options: .withoutEscapingSlashes),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return "window.settings.injectSettings(\(json));"
    }
}
