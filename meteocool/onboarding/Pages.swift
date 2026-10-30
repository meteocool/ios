import Foundation

@MainActor enum Pages {
    static let welcome = OnboardingPage(
        artwork: .illustration("ob_rain_sun"),
        title: NSLocalizedString("onboarding_welcome_title", comment: "Welcome Page Onboarding"),
        features: [
            OnboardingFeature(
                symbol: "cloud.rain.fill",
                title: NSLocalizedString("onboarding_feature_radar_title", comment: "Welcome Page Onboarding"),
                detail: NSLocalizedString("onboarding_feature_radar_text", comment: "Welcome Page Onboarding")),
            OnboardingFeature(
                symbol: "wind",
                title: NSLocalizedString("Nowcasting", comment: "Welcome Page Onboarding"),
                detail: NSLocalizedString("onboarding_feature_nowcast_text", comment: "Welcome Page Onboarding")),
            OnboardingFeature(
                symbol: "bell.badge.fill",
                title: NSLocalizedString("Rain Alerts", comment: "Welcome Page Onboarding"),
                detail: NSLocalizedString("onboarding_feature_alerts_text", comment: "Welcome Page Onboarding")),
            OnboardingFeature(
                symbol: "heart.fill",
                title: NSLocalizedString("onboarding_feature_free_title", comment: "Welcome Page Onboarding"),
                detail: NSLocalizedString("onboarding_feature_free_text", comment: "Welcome Page Onboarding")),
        ]
    )

    /// Shown before the alerts page, because the alerts page upgrades When In Use to background access.
    /// Only Continue, which always leads to the system prompt.
    /// App Review rejects a location pre-prompt that lets the user skip or delay it (guideline 5.1.1(iv)).
    static func location(action: @escaping OnboardingAction) -> OnboardingPage {
        OnboardingPage(
            artwork: .symbol("location.fill"),
            title: NSLocalizedString("Location Access", comment: "Location Page Onboarding"),
            message: NSLocalizedString("onboarding_location_permission", comment: "Location Page Onboarding"),
            action: action)
    }

    /// Asked the first time the storm log is opened, not at first launch: the
    /// log is off until the user turns it on. Says what it keeps, where, and
    /// for how long, as ng's storm log (ADR 0040) and this app do.
    static func stormLog(action: @escaping OnboardingAction) -> OnboardingPage {
        OnboardingPage(
            artwork: .symbol("book.closed.fill"),
            title: NSLocalizedString("storm_log_title", value: "Storm Log", comment: "Storm log onboarding"),
            message: NSLocalizedString("storm_log_onboarding_message", comment: "Storm log onboarding"),
            features: [
                OnboardingFeature(
                    symbol: "cloud.bolt.rain.fill",
                    title: NSLocalizedString("storm_log_onboarding_saves_title", comment: "Storm log onboarding"),
                    detail: NSLocalizedString("storm_log_onboarding_saves_text", comment: "Storm log onboarding")),
                OnboardingFeature(
                    symbol: "mappin.and.ellipse",
                    title: NSLocalizedString("storm_log_onboarding_area_title", comment: "Storm log onboarding"),
                    detail: NSLocalizedString("storm_log_onboarding_area_text", comment: "Storm log onboarding")),
                OnboardingFeature(
                    symbol: "server.rack",
                    title: NSLocalizedString("storm_log_onboarding_server_title", comment: "Storm log onboarding"),
                    detail: NSLocalizedString("storm_log_onboarding_server_text", comment: "Storm log onboarding")),
                OnboardingFeature(
                    symbol: "trash.fill",
                    title: NSLocalizedString("storm_log_onboarding_off_title", comment: "Storm log onboarding"),
                    detail: NSLocalizedString("storm_log_onboarding_off_text", comment: "Storm log onboarding")),
            ],
            footnote: NSLocalizedString("storm_log_onboarding_footnote", comment: "Storm log onboarding"),
            primaryTitle: NSLocalizedString("storm_log_turn_on", comment: "Storm log onboarding"),
            secondaryTitle: NSLocalizedString("Not Now", comment: "Skip a permission"),
            action: action)
    }

    static func notifications(action: @escaping OnboardingAction) -> OnboardingPage {
        OnboardingPage(
            artwork: .symbol("bell.badge.fill"),
            title: NSLocalizedString("Rain Alerts", comment: "Notifications Page Onboarding"),
            message: NSLocalizedString("onboarding_notification_text", comment: "Notifications Page Onboarding"),
            footnote: NSLocalizedString("onboarding_settings_footnote", comment: "Notifications Page Onboarding"),
            primaryTitle: NSLocalizedString("tell_me_before_it_rains", comment: "Notifications Page Onboarding"),
            secondaryTitle: NSLocalizedString("Not Now", comment: "Skip a permission"),
            action: action)
    }
}
