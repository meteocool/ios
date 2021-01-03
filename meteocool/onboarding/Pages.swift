import Foundation
import OnboardKit

class Pages {
    static let welcome = OnboardPage(
        title: NSLocalizedString("Hi there!\n\n\n", comment:"Welcome title"),
        imageName: "ob_rain_sun",
        description: NSLocalizedString("The meteocool project is an ongoing effort to make freely available meteorological data useful to everyone.\n\nWe process and aggregate data from different sources and try to visualize them in an intuitive way.", comment: "Welcome description")
    )
    
    static let nowcastingExplanation = OnboardPage(
        title: NSLocalizedString("Nowcasting", comment:"Nowcasting title"),
        imageName: "ob_jacket",
        description: NSLocalizedString("We use a super-accurate forecast model (a so-called \"nowcast\") which predicts the path and extent of rain clouds based on factors like wind, air pressure and lightning activity.\n\nObviously, more distant time steps are less accurate. But in our experience, at least the first 45 minutes are pretty spot-on.", comment: "Nowcasting description")
    )
    
    static func getNotificationExplanation(action: OnboardPageAction? = nil) -> OnboardPage {
        return OnboardPage(
            title: NSLocalizedString("Notifications", comment:"Notifications title"),
            imageName: "ob_notifications",
            description: NSLocalizedString("Based on this data, do you want us to notify you ahead of rain at your location?\n\nWe put a lot of effort into making the notifications non-intrusive. They disappear as soon as it stops raining.", comment: "Notifications description"),
            advanceButtonTitle: NSLocalizedString("I Don't Want Notifications.", comment:"Later"),
            actionButtonTitle: NSLocalizedString("Tell Me Before It Rains!", comment:"Notifications actionButtonTitle"),
            action: action)
    }
    
    static func getBackgroundLocationPermission(action: OnboardPageAction? = nil) -> OnboardPage {
        return OnboardPage(
            title: NSLocalizedString("Location", comment:"Location"),
            imageName: "ob_location",
            description: NSLocalizedString("Nice! To notify you about incoming rain, you need to select \"Allow While Using App\" in the following pop-up.\n\nYour iPhone will then soon ask you to allow background location access. Don't worry, this won't drain your battery.", comment: "Location description"),
            advanceButtonTitle: NSLocalizedString("Later", comment:"Later"),
            actionButtonTitle: NSLocalizedString("Allow Location Access", comment:"Enable Location Services"),
            action: action)
    }
    
    static func getWhileUsingLocationPermission(action: OnboardPageAction? = nil) -> OnboardPage {
        return OnboardPage(
            title: NSLocalizedString("Location", comment:"Location"),
            imageName: "ob_location",
            description: NSLocalizedString("To show your current location on the weather and satellite map, we need your permission. We won't ever share or store your location data.", comment: "Location description"),
            advanceButtonTitle: NSLocalizedString("Later", comment:"Later"),
            actionButtonTitle: NSLocalizedString("Allow Location Access", comment:"Enable Location Services"),
            action: action)
    }
    
    
    static let satelliteView = OnboardPage(
        title: NSLocalizedString("New Live Satellite View", comment:"Satellite Onboarding"),
        imageName: "satellite_screenshot",
        description: NSLocalizedString("A new near-realtime satellite view is now available from the layer switcher menu on the top right!", comment: "Satellite Onboarding Body"),
        advanceButtonTitle: NSLocalizedString("Done", comment: "done")
    )
    

    static let finish = OnboardPage(
        title: NSLocalizedString("That's It! Now Go Outside!", comment:"Finish title"),
        imageName: "ob_free",
        description: NSLocalizedString("Did you know?\n\nmeteocool is completely free and open source. It's run and built by volunteers in their free time. If you like our App, tell your friends!", comment: "Finish description"),
        advanceButtonTitle: NSLocalizedString("Done", comment: "done")
    )
    
    static func getLocationNag(action: OnboardPageAction? = nil) -> OnboardPage {
        return OnboardPage(
            title: NSLocalizedString("Location", comment:"Location"),
            imageName: "ob_location",
            description: NSLocalizedString("meteocool is much better with location data! Choose \"Always\" in the permission pop-up if you also want notifications.\n\nDon't worry, this won't drain your battery.", comment: "with location"),
            advanceButtonTitle: "",
            actionButtonTitle: NSLocalizedString("Enable Location Services", comment:"Enable Location Services"),
            action: action
        )
    }
    
    static let locationNagSorry = OnboardPage(
        title: NSLocalizedString("We'll shut up now.", comment: "shut up"),
        imageName: "ob_location",
        description: NSLocalizedString("We won't ask you again about permissions!\n\nIf you change your mind, go to System Settings > Privacy > meteocool.", comment:"we won't ask again"),
        advanceButtonTitle: NSLocalizedString("Done", comment: "done")
    )
}
