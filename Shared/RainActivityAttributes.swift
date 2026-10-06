import ActivityKit

/// The rain Live Activity. Everything it shows changes with the weather, so
/// it lives in the content state (`RainForecast`); there are no fixed
/// attributes. A push-to-start names this type in `attributes-type` and
/// sends `"attributes": {}`.
struct RainActivityAttributes: ActivityAttributes {
    typealias ContentState = RainForecast
}
