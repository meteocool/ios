//
//  CarPlaySceneDelegate.swift
//  meteocool
//
//  The CarPlay scene: the radar map, the location button and zoom.
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
/// The root template is a `CPMapTemplate` with three map buttons: the
/// location button, and zoom in and out for cars whose screens take no
/// pinch. Its delegate hands pans and pinches on to the map.
///
/// Drawing into the `CPWindow` requires the `com.apple.developer.carplay-maps`
/// entitlement. Apple grants it per app on request.
class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPMapTemplateDelegate {
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

        let template = CPMapTemplate()
        template.mapDelegate = self
        let locate = Self.button(map.locationState.symbolName) { [weak map] in map?.locationButton() }
        map.onLocationState = { [weak locate] state in locate?.image = Self.symbol(state.symbolName) }
        map.onLocationDenied = { [weak self] in self?.showLocationDenied() }
        template.mapButtons = [
            Self.button("plus") { [weak map] in map?.zoom(by: 1) },
            Self.button("minus") { [weak map] in map?.zoom(by: -1) },
            locate,
        ]
        // CarPlay shows nothing until a root template is set, even when the
        // window's view controller is ready.
        interfaceController.setRootTemplate(template, animated: false, completion: nil)
        map.start()
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

    // Another app on the car's screen: nothing to keep live meanwhile.
    func sceneDidEnterBackground(_ scene: UIScene) {
        mapController?.stop()
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        mapController?.start()
    }

    /// Location access is off: the driver turns it on on the phone.
    private func showLocationDenied() {
        guard let interfaceController, interfaceController.presentedTemplate == nil else { return }
        let alert = CPAlertTemplate(titleVariants: [NSLocalizedString("location_permission_required", comment: "Alerts")], actions: [
            CPAlertAction(title: NSLocalizedString("Dismiss", comment: "Alerts"), style: .cancel) { [weak interfaceController] _ in
                interfaceController?.dismissTemplate(animated: true, completion: nil)
            },
        ])
        interfaceController.presentTemplate(alert, animated: true, completion: nil)
    }

    private static func button(_ symbol: String, _ action: @escaping @MainActor () -> Void) -> CPMapButton {
        let button = CPMapButton { _ in MainActor.assumeIsolated { action() } }
        button.image = Self.symbol(symbol)
        return button
    }

    private static func symbol(_ name: String) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold))
    }

    // MARK: - CPMapTemplateDelegate

    func mapTemplateDidBeginPanGesture(_ mapTemplate: CPMapTemplate) {
        mapController?.panBegan()
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, didUpdatePanGestureWithTranslation translation: CGPoint, velocity: CGPoint) {
        mapController?.pan(by: translation)
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, didEndPanGestureWithVelocity velocity: CGPoint) {
        mapController?.panEnded(velocity: velocity)
    }

    @available(iOS 26.0, *)
    func mapTemplateDidBeginZoomGesture(_ mapTemplate: CPMapTemplate) {
        mapController?.pinchBegan()
    }

    @available(iOS 26.0, *)
    func mapTemplate(_ mapTemplate: CPMapTemplate, didUpdateZoomGestureWithCenter center: CGPoint, scale: CGFloat, velocity: CGFloat) {
        mapController?.zoom(around: center, scale: scale)
    }

    @available(iOS 26.0, *)
    func mapTemplate(_ mapTemplate: CPMapTemplate, didEndZoomGestureWithVelocity velocity: CGFloat) {
        mapController?.pinchEnded()
    }
}
