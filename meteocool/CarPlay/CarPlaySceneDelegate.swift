//
//  CarPlaySceneDelegate.swift
//  meteocool
//
//  The CarPlay scene: one map, no templates on top of it.
//

import CarPlay
import UIKit

/// Scene delegate for the CarPlay screen.
///
/// CarPlay splits a map app in two parts:
/// - templates (`CPInterfaceController`): drawn by the system, and the only
///   part the driver can touch;
/// - the map: an ordinary `UIViewController` in the `CPWindow` under the
///   templates.
/// The app has nothing to put in a template yet. The root template is an
/// empty `CPMapTemplate`, and the radar fills the screen.
///
/// Drawing into the `CPWindow` requires the `com.apple.developer.carplay-maps`
/// entitlement. Apple grants it per app on request.
class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var mapController: CarPlayMapViewController?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController,
                                  to window: CPWindow) {
        self.interfaceController = interfaceController
        SharedLocationUpdater.carPlayConnected = true
        SharedLocationUpdater.updateBackgroundMonitoring()

        let map = CarPlayMapViewController()
        window.rootViewController = map
        mapController = map

        // Set an empty map template as root. CarPlay shows nothing until a
        // root template is set, even when the window's view controller is
        // ready.
        interfaceController.setRootTemplate(CPMapTemplate(), animated: false, completion: nil)
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController,
                                  from window: CPWindow) {
        self.interfaceController = nil
        mapController?.disconnect()
        window.rootViewController = nil
        mapController = nil
        SharedLocationUpdater.carPlayConnected = false
        SharedLocationUpdater.updateBackgroundMonitoring()

        // Stop the high-accuracy updates the CarPlay map requested. If the
        // phone app is active, its own map uses those updates, so they stay
        // on.
        if UIApplication.shared.applicationState != .active {
            SharedLocationUpdater.stopAccurateLocationUpdates()
        }
    }
}
