import Foundation
import OnboardKit

class Pages {
    static let welcome = OnboardPage(
        title: NSLocalizedString("Hi there!", comment:"Welcome Page Onbording"),
        imageName: "ob_rain_sun",
        description: NSLocalizedString("onboarding_welcome_text", comment: "Welcome Page Onbording")
    )

    static let nowcastingExplanation = OnboardPage(
        title: NSLocalizedString("Nowcasting", comment:"Nowcasting Page Onbording"),
        imageName: "ob_jacket",
        description: NSLocalizedString("onboarding_nowcasting_text", comment:"Nowcasting Page Onbording")
    )

    static func getNotificationExplanation(action: OnboardPageAction? = nil) -> OnboardPage {
        return OnboardPage(
            title: NSLocalizedString("Notifications", comment:"Notifications Page Onbording"),
            imageName: "ob_bell",
            description: NSLocalizedString("onboarding_notification_text", comment: "Notifications Page Onbording"),
            advanceButtonTitle: NSLocalizedString("Later", comment:"Later"),
            actionButtonTitle: NSLocalizedString("tell_me_before_it_rains", comment:"Notifications Page Onbording"),
            action: action)
    }

    static func getBackgroundLocationPermission(action: OnboardPageAction? = nil) -> OnboardPage {
        return OnboardPage(
            title: NSLocalizedString("Location Access", comment:"Location Page Onbording"),
            imageName: "ob_umbrella",
            description: NSLocalizedString("onboarding_notification_location_permission_text", comment: "Location Page Onbording description"),
            advanceButtonTitle: NSLocalizedString("", comment:""),
            actionButtonTitle: NSLocalizedString("allow_location_access", comment:"Location Page Onbording"),
            action: action)
    }

    static func getWhileUsingLocationPermission(action: OnboardPageAction? = nil) -> OnboardPage {
        return OnboardPage(
            title: NSLocalizedString("Location Access", comment:"Location Page Onbording"),
            imageName: "ob_location",
            description: NSLocalizedString("onboarding_location_permission", comment: "Location Page Onbording"),
            advanceButtonTitle: NSLocalizedString("Later", comment:"Later"),
            actionButtonTitle: NSLocalizedString("allow_location_access", comment:"Location Page Onbording"),
            action: action)
    }

    static let settingsPage = OnboardPage(
        title: NSLocalizedString("Settings", comment: "settings headline"),
        imageName: "dreaming_of_settings",
        description: NSLocalizedString("settings_onboarding", comment: "Settings Page Onboarding"),
        advanceButtonTitle: NSLocalizedString("Next", comment: "Next")
    )

    static let finish = OnboardPage(
        title: NSLocalizedString("Now Go Outside!", comment:"Finish Page Onbording"),
        imageName: "ob_free",
        description: NSLocalizedString("onboarding_end_credits", comment: "Finish Page Onbording"),
        advanceButtonTitle: NSLocalizedString("Done", comment: "Done")
    )

    static func getLocationNag(action: OnboardPageAction? = nil) -> OnboardPage {
        return OnboardPage(
            title: NSLocalizedString("Push Notifications", comment:"Location Nag Onbording"),
            imageName: "ob_bell",
            description: NSLocalizedString("onboarding_nag_text", comment: "Location Nag Onbording"),
            advanceButtonTitle: NSLocalizedString("Use Without Notifications", comment: "Location Nag Onbording"),
            actionButtonTitle: NSLocalizedString("Enable Push Notifications", comment:"Location Nag Onbording"),
            action: action
        )
    }

    static let locationNagSorry = OnboardPage(
        title: NSLocalizedString("We'll shut up now.", comment: "Location Nag Sorry"),
        imageName: "ob_bell",
        description: NSLocalizedString("won't ask you again", comment:"Location Nag Sorry"),
        advanceButtonTitle: NSLocalizedString("Done", comment: "Done")
    )
    
    static let welcomeUpdate = OnboardPage(
        title: NSLocalizedString("Hello again!", comment: "Welcome Update Onbording"),
        imageName: "ob_rain_sun",
        description: NSLocalizedString("new_features", comment:"Welcome Update Onbording"),
        advanceButtonTitle: NSLocalizedString("Next", comment: "Next"))
}
