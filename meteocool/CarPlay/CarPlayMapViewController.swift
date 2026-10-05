//
//  CarPlayMapViewController.swift
//  meteocool
//
//  The radar, drawn on the car's screen.
//

import CoreLocation
import UIKit
import WebKit

/// The live radar map shown in the `CPWindow`.
///
/// Loads the phone's web map from `carPlayURL`, which hides the toolbar and
/// the forecast strip. The car screen shows only the radar around the car,
/// with nothing to tap and nothing to read.
///
/// Uses its own `WKWebView` instead of the phone's:
/// - a view can be in only one window;
/// - the phone's map keeps its own camera position, which the driver does
///   not see.
@MainActor
final class CarPlayMapViewController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate, LocationObserver {
    private var webView: WKWebView!

    /// Set when the page has mounted and requested its settings. Before that,
    /// `window.lm` does not exist and an injected location is dropped.
    private var webviewReady = false

    /// The last fix that arrived before the page was ready, replayed on mount.
    private var pendingLocation: CLLocation?

    /// The first fix zooms the map in to driving range. Later fixes only keep
    /// the car centred, so the map does not repeat the zoom animation every
    /// few seconds.
    private var hasZoomed = false

    override func loadView() {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.userContentController.add(self, name: "scriptHandler")
        // `scriptHandler` above is required. Without it the page's
        // `postMessage("requestSettings")` throws on a missing handler, and
        // the exception aborts the rest of the page mount.
        configuration.userContentController.add(self, name: GeolocationBridge.handlerName)
        configuration.userContentController.addUserScript(GeolocationBridge.userScript)

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.navigationDelegate = self
        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        loadMap()

        SharedLocationUpdater.addObserver(observer: self)
        NotificationCenter.default.addObserver(self, selector: #selector(injectSettings), name: NSNotification.Name("SettingsChanged"), object: nil)
        // Mode changed on the phone: the car shows the same deployment.
        NotificationCenter.default.addObserver(self, selector: #selector(loadMap), name: MeteocoolEnvironment.didChange, object: nil)
        // Request high-accuracy updates even when the phone UI is not in
        // front (`force: true`). The car screen needs the driver's position.
        // With the phone locked the app is not active, and the call without
        // `force` would not start updates.
        SharedLocationUpdater.startAccurateLocationUpdates(force: true)
        SharedLocationUpdater.requestLocation(observer: self, explicit: false)
    }

    @objc private func loadMap() {
        webviewReady = false
        hasZoomed = false
        let environment = MeteocoolEnvironment.current
        NSLog("CarPlay: loading \(environment) frontend: \(environment.carPlayURL)")
        webView.load(URLRequest(url: environment.carPlayURL))
    }

    /// Out of memory or a GPU fault: nobody can tap anything on the car
    /// screen, so the map comes back on its own. The pause keeps a page that
    /// crashes on load from reloading in a tight loop.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webviewReady = false
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.loadMap()
        }
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

        // Ignore every other page message. They are for UI the car screen
        // does not have (drawer, layer switcher, haptics).
        // `requestSettings` means the map has loaded.
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
