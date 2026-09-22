//
//  CarPlayMapViewController.swift
//  meteocool
//
//  The radar, drawn on the car's screen.
//

import CoreLocation
import UIKit
import WebKit

/// The live radar map, for the `CPWindow`.
///
/// Same web map as the phone, loaded from `carPlayURL` so it comes up without
/// the toolbar or the forecast strip — in a car there is nothing to tap and
/// nothing to read, only the radar around the car.
///
/// It runs its own `WKWebView` rather than sharing the phone's: a view can only
/// live in one window, and the phone's map keeps its own camera, which the
/// driver is not looking at.
@MainActor
final class CarPlayMapViewController: UIViewController, WKScriptMessageHandler, LocationObserver {
    private var webView: WKWebView!

    /// Set once the page has mounted and asked for its settings. Before that
    /// `window.lm` does not exist and an injected location is dropped.
    private var webviewReady = false

    /// The last fix that arrived before the page was ready, replayed on mount.
    private var pendingLocation: CLLocation?

    /// The first fix zooms the map in to driving range; later ones only keep
    /// the car centred, so the view does not re-animate every few seconds.
    private var hasZoomed = false

    override func loadView() {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.userContentController.add(self, name: "scriptHandler")
        // Without this the page's `postMessage("requestSettings")` throws on a
        // missing handler, and the throw takes the rest of the mount with it.
        configuration.userContentController.add(self, name: GeolocationBridge.handlerName)
        configuration.userContentController.addUserScript(GeolocationBridge.userScript)

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let environment = MeteocoolEnvironment.current
        NSLog("CarPlay: loading \(environment) frontend: \(environment.carPlayURL)")
        webView.load(URLRequest(url: environment.carPlayURL))

        SharedLocationUpdater.addObserver(observer: self)
        NotificationCenter.default.addObserver(self, selector: #selector(injectSettings), name: NSNotification.Name("SettingsChanged"), object: nil)
        // The driver's position is the whole point of the car screen, so this
        // asks for updates whether or not the phone's own UI is in front —
        // with the phone locked the app is not "active" and the ordinary
        // entry point would decline.
        SharedLocationUpdater.startAccurateLocationUpdates(force: true)
        SharedLocationUpdater.requestLocation(observer: self, explicit: false)
    }

    // MARK: - LocationObserver

    func disconnect() {
        NotificationCenter.default.removeObserver(self)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "scriptHandler")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: GeolocationBridge.handlerName)
        webView.stopLoading()
    }

    @objc private func injectSettings() {
        guard webviewReady, let command = WebSettings.injectionJS() else { return }
        webView.evaluateJavaScript(command)
    }

    func notify(location: CLLocation) {
        guard webviewReady else {
            pendingLocation = location
            return
        }

        let zoom = !hasZoomed
        hasZoomed = true
        webView.evaluateJavaScript("window.lm.updateLocation(\(location.coordinate.latitude), \(location.coordinate.longitude), \(location.horizontalAccuracy), \(zoom), true);")
        GeolocationBridge.deliver(location, to: webView)
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.host == MeteocoolEnvironment.current.carPlayURL.host else { return }
        let action = String(describing: message.body)

        if message.name == GeolocationBridge.handlerName {
            if action == GeolocationBridge.requestAction {
                if let location = SharedLocationUpdater.getCurrentLocation() {
                    GeolocationBridge.deliver(location, to: webView)
                } else if SharedLocationUpdater.authorizationStatus == .authorizedAlways || SharedLocationUpdater.authorizationStatus == .authorizedWhenInUse {
                    SharedLocationUpdater.startAccurateLocationUpdates(force: true)
                } else {
                    GeolocationBridge.fail(.permissionDenied, message: "Enable location access on your iPhone", to: webView)
                }
            }
            return
        }

        // Everything else the page posts is chrome the car screen does not
        // have — the drawer, the layer switcher, haptics. `requestSettings` is
        // the one message that matters here: it means the map is up.
        if action == "requestSettings" {
            webviewReady = true
            injectSettings()
            if let pendingLocation {
                self.pendingLocation = nil
                notify(location: pendingLocation)
            }
        }
    }
}
