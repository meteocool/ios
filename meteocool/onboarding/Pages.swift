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

    /// Asked first: alerts later upgrade When In Use to background access.
    static func location(action: @escaping OnboardingAction) -> OnboardingPage {
        OnboardingPage(
            artwork: .symbol("location.fill"),
            title: NSLocalizedString("Location Access", comment: "Location Page Onboarding"),
            message: NSLocalizedString("onboarding_location_permission", comment: "Location Page Onboarding"),
            primaryTitle: NSLocalizedString("allow_location_access", comment: "Location Page Onboarding"),
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
