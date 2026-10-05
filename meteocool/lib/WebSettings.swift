//
//  WebSettings.swift
//  meteocool
//
//  The settings the host pushes into the web map.
//

import Foundation

/// Defines which stored settings are sent to the web map.
///
/// The phone map and the CarPlay map both use it. A setting that reaches
/// only one of them is a bug that shows up only in a car.
@MainActor
enum WebSettings {
    /// Returns the `window.settings.injectSettings({...})` call, or nil if the
    /// dictionary cannot be serialized.
    ///
    /// The overlay layers (lightning, mesocyclones, snow) are not included.
    /// The web map owns those toggles and stores them itself. Injecting a
    /// native copy would overwrite the user's choice on every launch.
    static func injectionJS() -> String? {
        let defaults = UserDefaults(suiteName: "group.org.frcy.app.meteocool")
        let config = [
            "mapRotation": defaults?.value(forKey: "mapRotation"),
            "radarColorMapping": defaults?.value(forKey: "radarColorMapping"),
            "mapBaseLayer": defaults?.value(forKey: "baseLayer"),
            "experimentalFeatures": MeteocoolEnvironment.current == .staging,
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: config, options: .withoutEscapingSlashes),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return "window.settings.injectSettings(\(json));"
    }
}
