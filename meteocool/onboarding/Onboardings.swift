import Foundation
import UIKit
import UIKit.UIGestureRecognizer
import WebKit
import CoreLocation
import OnboardKit


class OnboardingFactory {
    static let tintColor = UIColor(red: 137.0/255.0, green: 181.0/255.0, blue: 187.0/255.0, alpha: 1.00)
    let backgroundLight = UIColor(red: 0xf8/255.0, green: 0xf9/255.0, blue: 0xfa/255.0, alpha: 1.0)
    var appearanceConfiguration:OnboardViewController.AppearanceConfiguration
    var actionButtonStyling = UIButton()

    init() {
        var accessibleFont =  UIFont.preferredFont(forTextStyle: .body)

        if (accessibleFont.pointSize < 18) {
            accessibleFont = accessibleFont.withSize(18)
        } else if (accessibleFont.pointSize > 20.5) {
            accessibleFont = accessibleFont.withSize(20.5)
        }
        
        self.appearanceConfiguration = OnboardViewController.AppearanceConfiguration(
            tintColor: OnboardingFactory.tintColor,
            backgroundColor: backgroundLight,
            imageContentMode: .scaleAspectFit,
            textFont: accessibleFont,
            advanceButtonStyling: {button in
                button.titleLabel?.font = UIFont.preferredFont(forTextStyle: .title2)
                button.setTitleColor(OnboardingFactory.tintColor, for: .normal)
            })
    }
    
    public func getOnboarding(pages: [OnboardPage], completion: (() -> Void)? = nil) -> OnboardViewController? {
        let ret = OnboardViewController(pageItems: pages, appearanceConfiguration: appearanceConfiguration, completion: completion)
        ret.modalPresentationStyle = .formSheet
        return ret
    }

    public func getInitialOnboardingPages(notificationAction: OnboardPageAction? = nil) -> [OnboardPage] {
        return [Pages.welcome, Pages.nowcastingExplanation, Pages.getNotificationExplanation(action: notificationAction)]
    }

    public func getBackgroundLocationOnboarding(locationAction: OnboardPageAction? = nil, includeFeatureReview: Bool = true) -> [OnboardPage] {
        var reviewPages = [OnboardPage]()
        if (includeFeatureReview) {
            reviewPages = [Pages.settingsPage]
        }
        return [Pages.getBackgroundLocationPermission(action: locationAction)] + reviewPages + [Pages.finish]
    }
    
    public func getWhileUsingOnboarding(locationAction: OnboardPageAction? = nil) -> [OnboardPage] {
        return [Pages.getWhileUsingLocationPermission(action: locationAction), Pages.settingsPage, Pages.finish]
    }
    
    public func getLocationNagOnboarding(notificationAction: OnboardPageAction? = nil) -> [OnboardPage] {
        return [Pages.getLocationNag(action: notificationAction)]
    }
    
    public func getUpdateOnboarding() -> [OnboardPage]{
        return [Pages.welcomeUpdate, Pages.settingsPage, Pages.finish]
    }
}

let obFactory = OnboardingFactory()
