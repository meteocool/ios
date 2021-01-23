import Foundation
import OnboardKit

class Pages {
    static let welcome = OnboardPage(
        title: NSLocalizedString("Hi there!", comment:"Welcome Page Onbording"),
        imageName: "ob_rain_sun",
        description: NSLocalizedString("The meteocool project is an ongoing effort to make freely available meteorological data useful to everyone.\n\nWe process and aggregate data from different sources and try to visualize them in an intuitive way.", comment: "Welcome Page Onbording")
    )

    static let nowcastingExplanation = OnboardPage(
        title: NSLocalizedString("Nowcasting", comment:"Nowcasting Page Onbording"),
        imageName: "ob_jacket",
        description: NSLocalizedString("We use a super-accurate forecast model (a so-called \"nowcast\") which predicts the path and extent of rain clouds based on factors like wind, air pressure and lightning activity.\n\nObviously, longer terms are less accurate. But in our experience, at least the first 45 minutes are pretty spot-on.", comment:"Nowcasting Page Onbording")
    )

    static func getNotificationExplanation(action: OnboardPageAction? = nil) -> OnboardPage {
        return OnboardPage(
            title: NSLocalizedString("Notifications", comment:"Notifications Page Onbording"),
            imageName: "ob_bell",
            description: NSLocalizedString("Based on this data, do you want us to inform you about upcoming rain at your location?\n\nWe put a lot of effort into making the notifications non-intrusive. They disappear as soon as it stops raining.", comment: "Notifications Page Onbording"),
            advanceButtonTitle: NSLocalizedString("Later", comment:"Later"),
            actionButtonTitle: NSLocalizedString("Tell Me Before It Rains!", comment:"Notifications Page Onbording"),
            action: action)
    }

    static func getBackgroundLocationPermission(action: OnboardPageAction? = nil) -> OnboardPage {
        return OnboardPage(
            title: NSLocalizedString("Location Access", comment:"Location Page Onbording"),
            imageName: "ob_umbrella",
            description: NSLocalizedString("Nice! For notifications, you first need to select \"Allow While Using App\" in the following dialog.\n\nLater your device will ask you to allow background location. Don't worry, this won't drain your battery.", comment: "Location Page Onbording description"),
            advanceButtonTitle: NSLocalizedString("", comment:""),
            actionButtonTitle: NSLocalizedString("Allow Location Access", comment:"Location Page Onbording"),
            action: action)
    }

    static func getWhileUsingLocationPermission(action: OnboardPageAction? = nil) -> OnboardPage {
        return OnboardPage(
            title: NSLocalizedString("Location Access", comment:"Location Page Onbording"),
            imageName: "ob_location",
            description: NSLocalizedString("To show your current location on the weather and satellite map, we need your permission.\n\n We won't ever share or store your location data.", comment: "Location Page Onbording"),
            advanceButtonTitle: NSLocalizedString("Later", comment:"Later"),
            actionButtonTitle: NSLocalizedString("Allow Location Access", comment:"Location Page Onbording"),
            action: action)
    }

    static let satelliteView = OnboardPage(
        title: "",
        imageName: "satellite_screenshot",
        description: NSLocalizedString("☀️ Something for cloudless days: A new “near-realtime” satellite layer is now available from the layers menu!\n\n🛰 Satellite overpasses are expected every 5 days with a ground resolution ±10m/pixel.", comment: "Satellite View Onbording"),
        advanceButtonTitle: NSLocalizedString("Next", comment: "Next")
    )

    static let settingsPage = OnboardPage(
        title: "",
        imageName: "dreaming_of_settings",
        description: NSLocalizedString("Notifications 📱 (among other things) can now be configured in the Settings menu.\n\nTo open the Settings menu, click on the ⚙️ on the top-right of the map.", comment: "Settings Page Onboarding"),
        advanceButtonTitle: NSLocalizedString("Next", comment: "Next")
    )

    static let finish = OnboardPage(
        title: NSLocalizedString("Now Go Outside!", comment:"Finish Page Onbording"),
        imageName: "ob_free",
        description: NSLocalizedString("Did you know?\n\nmeteocool is completely free and open source. It's run and built by volunteers in their leisure time.\n\nIf you like our App, please tell your friends!", comment: "Finish Page Onbording"),
        advanceButtonTitle: NSLocalizedString("Done", comment: "Done")
    )

    static func getLocationNag(action: OnboardPageAction? = nil) -> OnboardPage {
        return OnboardPage(
            title: NSLocalizedString("Push Notifications", comment:"Location Nag Onbording"),
            imageName: "ob_bell",
            description: NSLocalizedString("Did you know? meteocool can inform you about upcoming rain up to 45 minutes ahead, even while you're not using the app.\n\nDon't worry, this won't drain your battery.", comment: "Location Nag Onbording"),
            advanceButtonTitle: NSLocalizedString("Use Without Notifications", comment: "Location Nag Onbording"),
            actionButtonTitle: NSLocalizedString("Enable Push Notifications", comment:"Location Nag Onbording"),
            action: action
        )
    }

    static let locationNagSorry = OnboardPage(
        title: NSLocalizedString("We'll shut up now.", comment: "Location Nag Sorry"),
        imageName: "ob_bell",
        description: NSLocalizedString("We won't ask you again about push notifications!\n\nIf you change your mind, you can always enable them in the ⚙️ Settings menu on the top-right.", comment:"Location Nag Sorry"),
        advanceButtonTitle: NSLocalizedString("Done", comment: "Done")
    )
    
    static let welcomeUpdate = OnboardPage(
        title: NSLocalizedString("Hallo again!", comment: "Welcome Update Onbording"),
        imageName: "ob_rain_sun",
        description: NSLocalizedString("We have developed new features for our App. You will see what we have done in the next pages.", comment:"Welcome Update Onbording"),
        advanceButtonTitle: NSLocalizedString("Next", comment: "Next"))
}
