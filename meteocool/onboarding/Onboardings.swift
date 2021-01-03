import Foundation
import UIKit
import UIKit.UIGestureRecognizer
import WebKit
import CoreLocation
import OnboardKit


class OnboardingFactory {
    static let tintColor = UIColor(red: 137.0/255.0, green: 181.0/255.0, blue: 187.0/255.0, alpha: 1.00)
    let backgroundLight = UIColor(red: 0xf8/255.0, green: 0xf9/255.0, blue: 0xfa/255.0, alpha: 1.0)
    var accessibleFont =  UIFont.preferredFont(forTextStyle: .body)
    var appearanceConfiguration:OnboardViewController.AppearanceConfiguration
    
    init() {
        if (accessibleFont.pointSize < 18) {
            accessibleFont = accessibleFont.withSize(18)
        } else if (accessibleFont.pointSize > 21) {
            accessibleFont = accessibleFont.withSize(21)
        }
        self.appearanceConfiguration = OnboardViewController.AppearanceConfiguration(
            tintColor: OnboardingFactory.tintColor,
            backgroundColor: backgroundLight,
            textFont: accessibleFont)
    }
    
    public func getOnboarding(pages: [OnboardPage],  completion: (() -> Void)? = nil) -> OnboardViewController? {
        let ret = OnboardViewController(pageItems: pages, appearanceConfiguration: appearanceConfiguration, completion: completion)
        ret.modalPresentationStyle = .formSheet
        return ret
    }

    public func getInitialOnboardingPages(notificationAction: OnboardPageAction? = nil) -> [OnboardPage] {
        return [Pages.welcome, Pages.nowcastingExplanation, Pages.getNotificationExplanation(action: notificationAction)]
    }

    public func getBackgroundLocationOnboarding(locationAction: OnboardPageAction? = nil) -> [OnboardPage] {
        return [Pages.getBackgroundLocationPermission(action: locationAction), Pages.satelliteView, Pages.finish]
    }
    
    public func getWhileUsingOnboarding(locationAction: OnboardPageAction? = nil) -> [OnboardPage] {
        return [Pages.getWhileUsingLocationPermission(action: locationAction), Pages.satelliteView, Pages.finish]
    }
    
    public func getLocationNagOnboarding(locationAction: OnboardPageAction? = nil) -> [OnboardPage] {
        return [Pages.getLocationNag(action: locationAction), Pages.locationNagSorry]
    }
}

let obFactory = OnboardingFactory()