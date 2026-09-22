//
//  CarPlaySceneDelegate.swift
//  meteocool
//
//  The CarPlay scene: one map, no templates on top of it.
//

import CarPlay
import UIKit

/// meteocool on the car's screen.
///
/// CarPlay splits a map app in two: the templates (`CPInterfaceController`),
/// which the system draws and which are the only thing the driver can touch,
/// and the map itself, an ordinary `UIViewController` in the `CPWindow`
/// underneath them. This app has nothing to put in a template yet, so the
/// root template is an empty `CPMapTemplate` and the whole screen is the radar.
///
/// Drawing into the `CPWindow` at all requires the `com.apple.developer.carplay-maps`
/// entitlement, which Apple grants per app on request — see CLAUDE.md.
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

        // An empty map template is what keeps the window visible: CarPlay
        // shows nothing until a root template is set, however ready the
        // window's view controller is.
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

        // The car screen was the only reason for the high-accuracy updates the
        // map controller asked for. If the phone is in front of the user its
        // own screen is driving them and they stay on.
        if UIApplication.shared.applicationState != .active {
            SharedLocationUpdater.stopAccurateLocationUpdates()
        }
    }
}
