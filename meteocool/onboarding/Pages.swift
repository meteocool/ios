import Foundation

@MainActor class Pages {
    static let welcome = OnboardingPage(
        title: NSLocalizedString("Hi there!", comment:"Welcome Page Onbording"),
        imageName: "ob_rain_sun",
        description: NSLocalizedString("onboarding_welcome_text", comment: "Welcome Page Onbording")
    )

    static let nowcastingExplanation = OnboardingPage(
        title: NSLocalizedString("Nowcasting", comment:"Nowcasting Page Onbording"),
        imageName: "ob_jacket",
        description: NSLocalizedString("onboarding_nowcasting_text", comment:"Nowcasting Page Onbording")
    )

    static func getNotificationExplanation(action: OnboardingAction? = nil) -> OnboardingPage {
        return OnboardingPage(
            title: NSLocalizedString("Notifications", comment:"Notifications Page Onbording"),
            imageName: "ob_bell",
            description: NSLocalizedString("onboarding_notification_text", comment: "Notifications Page Onbording"),
            advanceButtonTitle: NSLocalizedString("Later", comment:"Later"),
            actionButtonTitle: NSLocalizedString("tell_me_before_it_rains", comment:"Notifications Page Onbording"),
            action: action)
    }

    static func getWhileUsingLocationPermission(action: OnboardingAction? = nil) -> OnboardingPage {
        return OnboardingPage(
            title: NSLocalizedString("Location Access", comment:"Location Page Onbording"),
            imageName: "ob_location",
            description: NSLocalizedString("onboarding_location_permission", comment: "Location Page Onbording"),
            advanceButtonTitle: NSLocalizedString("Later", comment:"Later"),
            actionButtonTitle: NSLocalizedString("allow_location_access", comment:"Location Page Onbording"),
            action: action)
    }

    static let settingsPage = OnboardingPage(
        title: NSLocalizedString("Settings", comment: "settings headline"),
        imageName: "dreaming_of_settings",
        description: NSLocalizedString("settings_onboarding", comment: "Settings Page Onboarding"),
        advanceButtonTitle: NSLocalizedString("Next", comment: "Next")
    )

    static let finish = OnboardingPage(
        title: NSLocalizedString("Now Go Outside!", comment:"Finish Page Onbording"),
        imageName: "ob_free",
        description: NSLocalizedString("onboarding_end_credits", comment: "Finish Page Onbording"),
        advanceButtonTitle: NSLocalizedString("Done", comment: "Done")
    )

}
