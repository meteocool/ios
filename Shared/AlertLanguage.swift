import Foundation

/// The language the backend words rain alerts, widgets and Live Activities
/// in: the one the app shows itself in, when the backend has words for it.
///
/// The backend rejects any other `lang`, and the legacy endpoint then drops
/// the push registration and the barometric reading without an error, so
/// anything else is sent as English.
///
/// No app dependencies here: `scripts/check.sh` compiles this file alone.
enum AlertLanguage {
    /// What the backend words alerts in: ng's `wording.LANGUAGES`.
    static let worded: Set<String> = ["de", "en", "nl", "lt", "et", "hr", "da", "fi", "sv", "nb",
                                      "fr", "it", "pl", "cs", "sk"]

    /// The app's own language, so an alert reads like the app around it and
    /// follows the per-app language in Settings. The widget extension has
    /// the same localisations as the app.
    static var current: String { code(for: Bundle.main.preferredLocalizations.first ?? "en") }

    /// `identifier` (a localisation or a language tag such as `pt-BR`) as
    /// the backend's code: Norwegian is `nb`, unworded languages English.
    static func code(for identifier: String) -> String {
        let language = identifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { $0.lowercased() } ?? ""
        if language == "no" || language == "nn" { return "nb" }
        return worded.contains(language) ? language : "en"
    }
}
