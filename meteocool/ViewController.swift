import UIKit
import UIKit.UIGestureRecognizer
import WebKit
import CoreLocation
import LinkPresentation

@MainActor var viewController: ViewController? = nil

class ViewController: UIViewController, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler, LocationObserver, UIScrollViewDelegate, UIGestureRecognizerDelegate{
    
    @IBOutlet weak var webView: WKWebView!
    @IBOutlet weak var settingsButton: UIButton!
    @IBOutlet weak var trippleButton: UIImageView!
    @IBOutlet weak var positionButton: UIButton!
    @IBOutlet weak var layerSwitcherButton: UIButton!
    @IBOutlet weak var blur: UIVisualEffectView!
    @IBOutlet weak var logo: UIImageView!
        
    var autoFocus = false
    var autoFocusOnce = false
    var zoomOnce = false
    var webviewReady = false
    /// The MapKit map shown in place of the web view while `nativeMap` is on
    /// in Settings; nil while the web map is shown.
    private(set) var nativeMap: NativeMapView?
    /// Whether the map on screen can take the host's calls.
    private var mapReady: Bool { nativeMap != nil || webviewReady }
    /// What the share sheet's popover points at and screenshots show.
    private var mapSurface: UIView { nativeMap ?? webView }
    private var recovery: MapRecovery!
    /// "Trying again" over the map while it keeps failing to load.
    /// Not a button: `MapRecovery` retries on its own.
    private let loadStatus = UIStackView()
    private var loadStatusBackdrop: UIView?

    /// Glass views that replace the flat blur and the `TribbleButton` artwork
    /// on iOS 26. Nil before iOS 26, where the storyboard blur and artwork stay.
    private var glassControls: UIVisualEffectView?
    private var glassLogo: UIVisualEffectView?

    /// Opens the AR storm view. Shown only where AR works and while the
    /// `HiddenFeatures` are on; see `refreshARButton`.
    let arButton = UIButton(type: .system)
    /// The AR button's own glass element (iOS 26) or blur disc (before), so
    /// hiding it leaves no empty backdrop.
    private var arButtonBackdrop: UIView?
    /// Sends a link to what the map shows; see `shareMap`.
    let shareButton = UIButton(type: .system)
    /// Opens the storm log, the storms that passed the phone: a pill beside the logo.
    let stormLogButton = UIButton(type: .system)
    /// The pill's glass element (iOS 26) or blur capsule (before), hidden with the logo.
    private var stormLogBackdrop: UIView?
    /// Opens the past alerts, the rain alerts this phone received: the bell beside the logbook.
    let alertsButton = UIButton(type: .system)
    private var alertsBackdrop: UIView?
    /// The share button's blur disc before iOS 26. On iOS 26 it is one of the
    /// glass column's elements, hidden with the rest of it.
    private var shareButtonBackdrop: UIView?
    /// What hides the controls and the logo; see `setCovered`.
    private var covers = Set<Cover>()
    /// The storm selected on the map, from the page's `cloudSelected:` and
    /// `cellSelected:` messages: what the AR view looks for when opened.
    private var mapSelection: StormTarget?
    /// A shared link's search, held until the page reports in with
    /// `requestSettings`.
    private var pendingLink: String?
    /// A link opened during this visit to the foreground says where the map
    /// looks, so coming back to the foreground does not centre on the user.
    /// UIKit may hand over the link before or after `willEnterForeground`.
    private var linkPlacedView = false

    let userDefaults = UserDefaults.init(suiteName: "group.org.frcy.app.meteocool")

    enum LocationState {
        case off
        case active
        case tracking
    }
    
    enum LocationTrigger {
        case buttonPress
        case mapMove
    }
    
    private typealias LocationFSM = SwiftFSMSchema<LocationState, LocationTrigger>
    private var LocationFSMSchema = LocationFSM(initialState: .off) { (presentState, trigger) -> ViewController.LocationState in
        var toState: LocationState

        switch presentState {
        case .off:
            switch trigger {
            case .buttonPress:
                toState = .active
            case .mapMove:
                toState = .off
            }
        case .active:
            switch trigger {
            case .buttonPress:
                toState = .tracking
            case .mapMove:
                toState = .active
            }
        case .tracking:
            switch trigger {
            case .buttonPress:
                toState = .off
            case .mapMove:
                toState = .active
            }
        }
        return toState
    }
    
    private var locationStateMachine: SwiftFSM<LocationFSM>?
    
    /// Ends follow mode when a gesture moves the map.
    /// Only `.began` triggers a transition. The recognizers also fire on every
    /// `.changed`, and the state machine needs one transition per gesture.
    @objc func mapGesture(_ recognizer: UIGestureRecognizer) {
        if let pinch = recognizer as? UIPinchGestureRecognizer, let webView, nativeMap == nil {
            TrackpadBridge.pinch(pinch, in: webView)
        }
        if let rotation = recognizer as? UIRotationGestureRecognizer, let webView, nativeMap == nil {
            TrackpadBridge.rotate(rotation, in: webView)
        }
        guard recognizer.state == .began, locationStateMachine?.state == .tracking else { return }
        locationStateMachine?.trigger(.mapMove)
    }
    
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
      return true
    }
    
    override func loadView() {
        super.loadView()
        viewController = self

        webView?.configuration.userContentController.add(self, name: "scriptHandler")
        // Registered before the page loads. The shim must exist before the
        // first script that reads navigator.geolocation.
        webView?.configuration.userContentController.add(self, name: GeolocationBridge.handlerName)
        installUserScripts()
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        
        // Pinch and rotation end follow mode as well as pan. While
        // following, every fix re-centres the map, and that animation would
        // conflict with a zoom or a rotation.
        let recognizers: [UIGestureRecognizer] = [
            UIPanGestureRecognizer(target: self, action: #selector(mapGesture(_:))),
            UIPinchGestureRecognizer(target: self, action: #selector(mapGesture(_:))),
            UIRotationGestureRecognizer(target: self, action: #selector(mapGesture(_:))),
        ]
        for recognizer in recognizers {
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            view.addGestureRecognizer(recognizer)
        }
        
        self.view.addSubview(webView!)
        self.view.addSubview(trippleButton!)
        self.view.addSubview(settingsButton!)
        self.view.addSubview(positionButton!)
        self.view.addSubview(layerSwitcherButton!)
        self.view.addSubview(logo!)
        self.view.addSubview(blur!)

        configureShareButton()
        configureARButton()
        configureStormLogButton()
        configureAlertsButton()
        if #available(iOS 26.0, *) {
            applyLiquidGlass()
        } else {
            installClassicShareButton()
            installClassicARButton()
            installClassicStormLogButton()
        }
        configureLogo()

        setMapControlsHidden(false)
        settingsButton.accessibilityLabel = NSLocalizedString("Settings", comment: "")
        settingsButton.accessibilityIdentifier = "map.settings"
        positionButton.accessibilityLabel = NSLocalizedString("Location Access", comment: "")
        positionButton.accessibilityIdentifier = "map.location"
        layerSwitcherButton.accessibilityLabel = NSLocalizedString("map_layers", comment: "")
        layerSwitcherButton.accessibilityIdentifier = "map.layers"
        layerSwitcherButton.isEnabled = false
    }

    /// The map is laid out for portrait on a phone; only the AR view turns.
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait
    }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        scrollView.pinchGestureRecognizer?.isEnabled = false
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        locationStateMachine = SwiftFSM(schema: LocationFSMSchema)
        locationStateMachine?.logging = .logging({(log: String) -> () in
            print(log) //Use any logging method you choose in this closure
        })
        locationStateMachine?.machineDidTransitState = { (_ fromState: LocationState, _ trigger: LocationTrigger, _ toState: LocationState) -> () in
            switch(toState) {
            case .off:
                self.autoFocus = false
                self.autoFocusOnce = false
                self.zoomOnce = false
                SharedLocationUpdater.stopAccurateLocationUpdates()
                self.positionButton.setImage(UIImage(systemName: "location",withConfiguration: UIImage.SymbolConfiguration(scale: .large)),for: .normal)
                self.webView.evaluateJavaScript("window.lm.updateLocation(-1, -1, -1, false, false);")
                self.nativeMap?.showLocation(nil, zoom: false, focus: false)
            case .active where trigger == .mapMove:
                // The user moved the map while following. Stop following and
                // keep the map where the user moved it.
                self.autoFocus = false
                self.autoFocusOnce = false
                self.zoomOnce = false
                self.positionButton.setImage(UIImage(systemName: "location.fill",withConfiguration: UIImage.SymbolConfiguration(scale: .large)),for: .normal)
            case .active:
                SharedLocationUpdater.startAccurateLocationUpdates()
                self.autoFocus = false
                self.autoFocusOnce = true
                SharedLocationUpdater.requestLocation(observer: self, explicit: true)
                self.positionButton.setImage(UIImage(systemName: "location.fill",withConfiguration: UIImage.SymbolConfiguration(scale: .large)),for: .normal)
            case .tracking:
                self.autoFocus = true // gets reset to false automatically after the zoom operation
                self.zoomOnce = true // gets reset to false automatically after the zoom operation
                SharedLocationUpdater.requestLocation(observer: self, explicit: true)
                self.positionButton.setImage(UIImage(systemName: "location.fill.viewfinder",withConfiguration: UIImage.SymbolConfiguration(scale: .large)),for: .normal)
            }
        }

        // disable scrolling & bouncing effects. On a Mac, WebKit hands the
        // page a trackpad's two-finger scroll as `wheel` events only while
        // scrolling is enabled; the page fills the view, so nothing scrolls.
        webView.scrollView.isScrollEnabled = TrackpadBridge.isNeeded
        webView.scrollView.bounces = false
        webView.scrollView.delegate = self

        // The map URL carries the app version from the bundle
        // (`MeteocoolEnvironment`). The frontend reads it to decide which
        // native calls it may make. Do not hardcode it: a hardcoded "2.2"
        // stayed in the URL after the app version changed.
        webView.navigationDelegate = self
        installLoadStatus()
        recovery = MapRecovery(webView: webView, reload: { [weak self] view in
            self?.loadMap()
            // The view the page died with, unless a shared link waits to be opened.
            if let view, self?.pendingLink == nil { self?.openLink(search: view) }
        }, wentDown: { [weak self] in
            self?.mapWentDown()
        }, showStatus: { [weak self] visible in
            self?.loadStatusBackdrop?.isHidden = !visible
            self?.loadStatus.isHidden = !visible
        })
        applyMapSurface()
        if nativeMap == nil { loadMap() }

        NotificationCenter.default.addObserver(self, selector: #selector(ViewController.settingsChanged),
                                               name: NSNotification.Name("SettingsChanged"), object: nil)
        // Mode in Settings, or "Disable Demo Mode", switched the deployment:
        // load that deployment's map without a restart.
        NotificationCenter.default.addObserver(self, selector: #selector(loadMap),
                                               name: MeteocoolEnvironment.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(hiddenFeaturesChanged),
                                               name: HiddenFeatures.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenshotTaken),
                                               name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        SharedLocationUpdater.addObserver(observer: self)
        self.willEnterForeground()
    }

    var feedbackLight: UIImpactFeedbackGenerator?
    var feedbackMedium: UIImpactFeedbackGenerator?
    var feedbackHeavy: UIImpactFeedbackGenerator?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        feedbackLight = UIImpactFeedbackGenerator(style: .light)
        feedbackLight?.prepare()
        feedbackMedium = UIImpactFeedbackGenerator(style: .medium)
        feedbackMedium?.prepare()
        feedbackHeavy = UIImpactFeedbackGenerator(style: .heavy)
        feedbackHeavy?.prepare()

        presentDemoNoticeIfNeeded()

        guard userDefaults?.bool(forKey: "onboardingDone") != true,
              presentedViewController == nil, !onboardingPresented else { return }
        onboardingPresented = true
        let notifications: OnboardingAction = { completion in
            SharedNotificationManager.registerForPushNotifications { _, _ in
                // Onboarding continues when the user denies permission.
                completion(true, nil)
            }
        }
        let location: OnboardingAction = { completion in
            SharedLocationUpdater.requestAuthorization({ _, _ in
                completion(true, nil)
            })
        }
        let pages = [Pages.welcome, Pages.location(action: location), Pages.notifications(action: notifications)]
        let onboarding = OnboardingViewController(pages: pages) { [weak self] in
            guard let self else { return }
            self.userDefaults?.set(true, forKey: "onboardingDone")
            self.onboardingPresented = false
            self.activateLocationIfAuthorized()
            if SharedNotificationManager.enabled {
                SharedLocationUpdater.requestBackgroundAuthorization()
                SharedLocationUpdater.refreshNotificationRegistration()
            }
        }
        present(onboarding, animated: true)
    }

    private var onboardingPresented = false

    /// Shows a demo mode alert once per launch.
    /// The map shows a recorded storm as if it were happening now. A user who
    /// forgot that demo mode is on must not take it for real weather.
    /// Not shown over onboarding: demo mode is only in Settings, which the
    /// user reaches after onboarding.
    private func presentDemoNoticeIfNeeded() {
        guard MeteocoolEnvironment.current == .demo, !demoNoticeShown,
              userDefaults?.bool(forKey: "onboardingDone") == true,
              presentedViewController == nil else { return }
        demoNoticeShown = true
        let alert = UIAlertController(title: NSLocalizedString("demo_notice_title", comment: ""),
                                      message: NSLocalizedString("demo_notice_message", comment: ""),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("demo_notice_disable", comment: ""), style: .destructive) { _ in
            // Reloads the map and moves the push registration (`didChange`).
            MeteocoolEnvironment.select(.app)
        })
        let proceed = UIAlertAction(title: NSLocalizedString("demo_notice_continue", comment: ""), style: .default)
        alert.addAction(proceed)
        alert.preferredAction = proceed
        present(alert, animated: true)
    }

    private var demoNoticeShown = false

    /// Shows the user's position without a tap when the map has loaded and
    /// location permission is already granted.
    /// Called when the map finishes loading and when onboarding ends.
    private func activateLocationIfAuthorized() {
        let status = SharedLocationUpdater.authorizationStatus
        guard mapReady, locationStateMachine?.state == .off,
              status == .authorizedWhenInUse || status == .authorizedAlways else { return }
        if userDefaults?.bool(forKey: "autoZoom") == true {
            zoomOnce = true
        }
        locationStateMachine?.trigger(.buttonPress)
    }

    /// Loads the map page from scratch. `MapRecovery` calls it again until
    /// the page reports in with `requestSettings`.
    @objc private func loadMap() {
        // The native map reads the deployment and features itself.
        if let nativeMap {
            nativeMap.applySettings()
            return
        }
        // The storyboard's web view cannot be given an application name, so
        // the first load waits for WebKit's own user agent to append the
        // app's to it, as CarPlay's configuration does.
        guard webView.customUserAgent != nil else {
            webView.evaluateJavaScript("navigator.userAgent") { [weak self] agent, _ in
                guard let self, self.webView.customUserAgent == nil else { return }
                self.webView.customUserAgent = [agent as? String, UserAgent.value].compactMap { $0 }.joined(separator: " ")
                self.loadMap()
            }
            return
        }
        webviewReady = false
        layerSwitcherButton.isEnabled = false
        webView.load(URLRequest(url: MeteocoolEnvironment.current.webURL))
        recovery.loadStarted()
    }

    /// The page stopped working. The native controls stay usable while
    /// `MapRecovery` brings it back; the controls that drive the page wait.
    private func mapWentDown() {
        webviewReady = false
        layerSwitcherButton.isEnabled = false
        clearCovers()
    }

    /// Every new page has to report in, including one the page loads itself
    /// (core's service worker reloads it after an update).
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard nativeMap == nil else { return }
        webviewReady = false
        layerSwitcherButton.isEnabled = false
        recovery.loadStarted()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // Cancelled means another load replaced this one.
        if (error as NSError).code != NSURLErrorCancelled, nativeMap == nil { recovery.failed(.navigation) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        // A page that reported in runs, whatever happened to the rest of its load.
        if (error as NSError).code != NSURLErrorCancelled, !webviewReady, nativeMap == nil { recovery.failed(.navigation) }
    }

    /// The web content process died: out of memory, or a GPU fault.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard nativeMap == nil else { return }
        recovery.failed(.crash)
    }

    @objc func willResignActive() {
        linkPlacedView = false
        nativeMap?.player.leftForeground()
        if webviewReady { webView.evaluateJavaScript("window.leaveForeground?.();") }
    }

    @objc func willEnterForeground() {
        guard mapReady else { return }
        if userDefaults?.bool(forKey: "autoZoom") == true, !linkPlacedView {
            zoomOnce = true
            autoFocusOnce = true
        }
        if locationStateMachine?.state != .off {
            SharedLocationUpdater.startAccurateLocationUpdates()
            SharedLocationUpdater.requestLocation(observer: self, explicit: false)
        }
    }

    @objc func didBecomeActive(){
        refreshAlertsBadge()
        if let nativeMap {
            nativeMap.start()
            return
        }
        if webviewReady {
            self.webView.evaluateJavaScript("window.enterForeground?.();")
        }
        recovery.becameActive()
    }

    @IBAction func locationButton(sender: AnyObject){
        // Locating clears a long-pressed point, as core's locate button does.
        nativeMap?.clearPoint()
        let status = SharedLocationUpdater.authorizationStatus
        if status == .notDetermined {
            SharedLocationUpdater.requestAuthorization({ [weak self] granted, _ in
                if granted { self?.locationStateMachine?.trigger(.buttonPress) }
            })
            return
        }
        guard status == .authorizedAlways || status == .authorizedWhenInUse else {
            SharedLocationUpdater.requestLocation(observer: self, explicit: true)
            return
        }
        locationStateMachine?.trigger(.buttonPress)
    }
    
    @IBAction func layerSwitcher(sender: AnyObject){
        if let nativeMap {
            nativeMap.openLayers()
            return
        }
        setCovered(.layerSwitcher, true)
        webView.evaluateJavaScript("window.openLayerswitcher();") { [weak self] _, error in
            if error != nil {
                self?.setCovered(.layerSwitcher, false)
            }
        }
    }
    
    func notify(location: CLLocation) {
        if let nativeMap {
            guard locationStateMachine?.state != .off else { return }
            nativeMap.showLocation(location, zoom: zoomOnce, focus: autoFocus || autoFocusOnce)
            zoomOnce = false
            autoFocusOnce = false
            return
        }
        guard webviewReady else { return }
        // Pass the same fix to the geolocation shim. This resolves pending
        // getCurrentPosition calls in the page and updates its watchers.
        GeolocationBridge.deliver(location, to: webView)
        // Fixes still arrive while the location button is off
        // (significant-change monitoring for alerts, CarPlay). They must not
        // show the location dot again.
        guard locationStateMachine?.state != .off else { return }
        let jsCommand = "window.lm.updateLocation(\(location.coordinate.latitude), \(location.coordinate.longitude), \(location.horizontalAccuracy), \(zoomOnce), \(autoFocus || autoFocusOnce));"
        webView.evaluateJavaScript(jsCommand)
        if (zoomOnce){
            zoomOnce = false
        }
        if (autoFocusOnce){
            autoFocusOnce = false
        }
    }

    /// Settings changed: which map is shown, and what it shows.
    @objc func settingsChanged() {
        applyMapSurface()
        nativeMap?.applySettings()
        injectSettings()
    }

    /// Shows the native map or the web map, as `nativeMap` in Settings says.
    /// The web view stays in place under the native map, blank, so its
    /// handlers and scripts are ready when the web map comes back.
    private func applyMapSurface() {
        let native = userDefaults?.bool(forKey: NativeMapView.settingKey) == true
        if native, nativeMap == nil {
            recovery.stop()
            webviewReady = false
            webView.stopLoading()
            webView.loadHTMLString("", baseURL: nil)
            webView.isHidden = true
            clearCovers()

            let map = NativeMapView()
            map.host = self
            map.translatesAutoresizingMaskIntoConstraints = false
            view.insertSubview(map, aboveSubview: webView)
            NSLayoutConstraint.activate([
                map.topAnchor.constraint(equalTo: view.topAnchor),
                map.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                map.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                map.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
            nativeMap = map
            layerSwitcherButton.isEnabled = true
            map.start()
            // The location button may already be on: the dot from the last fix, without moving the map.
            if locationStateMachine?.state != .off, let location = SharedLocationUpdater.getCurrentLocation() {
                map.showLocation(location, zoom: false, focus: false)
            }
            if userDefaults?.bool(forKey: "onboardingDone") == true { activateLocationIfAuthorized() }
            if let link = pendingLink { openLink(search: link) }
        } else if !native, let map = nativeMap {
            map.stop()
            map.removeFromSuperview()
            nativeMap = nil
            webView.isHidden = false
            loadMap()
        }
    }

    @objc func injectSettings() {
        guard webviewReady else { return }
        guard let command = WebSettings.injectionJS() else {
            print("Config parsing failed")
            return
        }
        webView.evaluateJavaScript(command)
        print(command)
    }


    /* called from javascript */
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.host == MeteocoolEnvironment.current.webURL.host else { return }
        let action = String(describing: message.body)

        if message.name == "scriptHandler", handleStormMessage(action) { return }
        if message.name == "scriptHandler", action.hasPrefix("share:") {
            if let share = MapShare(json: String(action.dropFirst("share:".count)), mapHost: MeteocoolEnvironment.current.webURL.host) {
                presentShare(share)
            }
            return
        }

        if message.name == GeolocationBridge.handlerName {
            if action == GeolocationBridge.requestAction {
                serveGeolocationRequest()
            }
            return
        }

        if action == "impactLight" {
            feedbackLight?.impactOccurred()
        }

        if action == "impactMedium" {
            feedbackMedium?.impactOccurred()
        }

        if action == "impactHeavy" {
            feedbackHeavy?.impactOccurred()
        }

        if action == "mapGraphicsLost" {
            recovery.failed(.graphics)
        }

        if action == "requestSettings" {
            recovery.loadSucceeded()
            webviewReady = true
            layerSwitcherButton.isEnabled = true
            injectSettings()

            if (userDefaults?.bool(forKey: "onboardingDone") ?? false) {
                activateLocationIfAuthorized()
            }

            clearCovers()

            // After the location button, so the link wins over its centring.
            if let link = pendingLink { openLink(search: link) }
        }
        
        switch action {
        case "layerSwitcherOpened": setCovered(.layerSwitcher, true)
        case "layerSwitcherClosed": setCovered(.layerSwitcher, false)
        case "detailSheetExpanded": setCovered(.expandedSheet, true)
        case "detailSheetCollapsed": setCovered(.expandedSheet, false)
        case "hideControls": setCovered(.popup, true)
        case "showControls": setCovered(.popup, false)
        default: break
        }
    }
}

// MARK: - Geolocation

extension ViewController {
    /// Answers a `navigator.geolocation` request from the page with a
    /// CoreLocation fix.
    ///
    /// The page reaches this only through the `GeolocationBridge` shim, so the
    /// app's own location permission applies. WebKit's per-origin location
    /// alert does not appear. A user who granted location once is not asked
    /// again by the web view.
    fileprivate func serveGeolocationRequest() {
        switch SharedLocationUpdater.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            if let location = SharedLocationUpdater.getCurrentLocation() {
                GeolocationBridge.deliver(location, to: webView)
            } else {
                // No cached fix yet. The next fix arrives in
                // notify(location:), which passes it to the shim.
                SharedLocationUpdater.startAccurateLocationUpdates()
            }
        case .notDetermined:
            // Show the app's own prompt, with the app's purpose string,
            // instead of WebKit's. The prompt appears here only because the
            // page asked for a position.
            SharedLocationUpdater.requestAuthorization({ [weak self] _, _ in
                guard let self else { return }
                switch SharedLocationUpdater.authorizationStatus {
                case .authorizedWhenInUse, .authorizedAlways:
                    self.serveGeolocationRequest()
                default:
                    GeolocationBridge.fail(.permissionDenied, message: "Location access was not granted", to: self.webView)
                }
            })
        case .denied, .restricted:
            GeolocationBridge.fail(.permissionDenied, message: "Location access for meteocool is turned off", to: webView)
        @unknown default:
            GeolocationBridge.fail(.positionUnavailable, message: "Location is unavailable", to: webView)
        }
    }
}

// MARK: - Liquid Glass

extension ViewController {
    /// Replaces the flat map controls and status bar backdrop with glass.
    /// The radar map underneath is content and gets no glass.
    @available(iOS 26.0, *)
    fileprivate func applyLiquidGlass() {
        // Status bar backdrop. Remove the 2pt vibrancy view the storyboard
        // nests here: vibrancy cannot be placed inside glass. The view has
        // not been visible for years, so removing it changes nothing.
        blur.contentView.subviews.forEach { $0.removeFromSuperview() }
        blur.effect = UIGlassEffect(style: .regular)

        installGlassControls()
        installGlassLogo()

    }

    /// Replaces the `TribbleButton` slab and the three buttons on top of it,
    /// with the share and AR buttons below them, by a glass container holding
    /// one interactive glass element each.
    /// The container makes them render as one pill shape. Glass cannot sample
    /// other glass, so ungrouped neighbours would each sample the map instead.
    @available(iOS 26.0, *)
    private func installGlassControls() {
        let controls = [layerSwitcherButton!, settingsButton!, positionButton!, shareButton, arButton]

        // The buttons are constrained to the artwork and to each other.
        // Reparenting them would leave those constraints pointing across the
        // hierarchy.
        LiquidGlass.dropConstraints(on: view, referencing: controls + [trippleButton])
        trippleButton.removeFromSuperview()

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        for control in controls {
            NSLayoutConstraint.deactivate(control.constraints)
            control.removeFromSuperview()
            control.translatesAutoresizingMaskIntoConstraints = false
            control.tintColor = .label

            let glass = LiquidGlass.element()
            glass.contentView.addSubview(control)
            NSLayoutConstraint.activate([
                glass.widthAnchor.constraint(equalToConstant: 52),
                glass.heightAnchor.constraint(equalToConstant: 52),
                control.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor),
                control.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor),
                control.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
                control.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
            ])
            stack.addArrangedSubview(glass)
            if control === arButton {
                arButtonBackdrop = glass
                glass.isHidden = arButton.isHidden
            }
        }

        let container = LiquidGlass.container(spacing: 10)
        container.contentView.addSubview(stack)
        view.addSubview(container)
        glassControls = container

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.contentView.trailingAnchor),
            view.safeAreaLayoutGuide.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: 12),
            container.topAnchor.constraint(equalTo: blur.bottomAnchor, constant: 12),
        ])
    }

    /// Moves the logo off the opaque plate in the `Logo Button` artwork and
    /// onto a glass disc, with the storm log's pill beside it.
    /// The disc matches the glass control column on the other side of the
    /// screen. `TribbleButton` got the same change, because a painted slab
    /// next to real glass looks out of place. The disc and the pill share a
    /// container, as the column's elements do: glass cannot sample glass.
    @available(iOS 26.0, *)
    private func installGlassLogo() {
        // Remove the storyboard constraints: they pin the logo to the safe
        // area and size it for the old artwork.
        LiquidGlass.dropConstraints(on: view, referencing: [logo])
        NSLayoutConstraint.deactivate(logo.constraints)
        logo.removeFromSuperview()

        logo.image = UIImage(named: "Logo")
        logo.contentMode = .scaleAspectFit
        logo.translatesAutoresizingMaskIntoConstraints = false

        // Interactive: the logo takes the user back to the radar (`logoTapped`).
        let glass = LiquidGlass.element()
        glass.contentView.addSubview(logo)
        glassLogo = glass

        let pill = LiquidGlass.element()
        stormLogButton.translatesAutoresizingMaskIntoConstraints = false
        stormLogButton.tintColor = .label
        pill.contentView.addSubview(stormLogButton)
        stormLogBackdrop = pill

        let bell = LiquidGlass.element()
        alertsButton.translatesAutoresizingMaskIntoConstraints = false
        alertsButton.tintColor = .label
        bell.contentView.addSubview(alertsButton)
        alertsBackdrop = bell

        let row = UIStackView(arrangedSubviews: [glass, pill, bell])
        row.axis = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        let container = LiquidGlass.container(spacing: 10)
        container.contentView.addSubview(row)
        view.addSubview(container)

        NSLayoutConstraint.activate([
            glass.widthAnchor.constraint(equalToConstant: 52),
            glass.heightAnchor.constraint(equalToConstant: 52),
            pill.widthAnchor.constraint(equalToConstant: 52),
            pill.heightAnchor.constraint(equalToConstant: 52),
            row.topAnchor.constraint(equalTo: container.contentView.topAnchor),
            row.bottomAnchor.constraint(equalTo: container.contentView.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: container.contentView.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: container.contentView.trailingAnchor),
            container.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            container.topAnchor.constraint(equalTo: blur.bottomAnchor, constant: 12),
            logo.centerXAnchor.constraint(equalTo: glass.contentView.centerXAnchor),
            logo.centerYAnchor.constraint(equalTo: glass.contentView.centerYAnchor),
            logo.widthAnchor.constraint(equalToConstant: 30),
            logo.heightAnchor.constraint(equalToConstant: 30),
            stormLogButton.leadingAnchor.constraint(equalTo: pill.contentView.leadingAnchor),
            stormLogButton.trailingAnchor.constraint(equalTo: pill.contentView.trailingAnchor),
            stormLogButton.topAnchor.constraint(equalTo: pill.contentView.topAnchor),
            stormLogButton.bottomAnchor.constraint(equalTo: pill.contentView.bottomAnchor),
            bell.widthAnchor.constraint(equalToConstant: 52),
            bell.heightAnchor.constraint(equalToConstant: 52),
            alertsButton.leadingAnchor.constraint(equalTo: bell.contentView.leadingAnchor),
            alertsButton.trailingAnchor.constraint(equalTo: bell.contentView.trailingAnchor),
            alertsButton.topAnchor.constraint(equalTo: bell.contentView.topAnchor),
            alertsButton.bottomAnchor.constraint(equalTo: bell.contentView.bottomAnchor),
        ])
    }

    /// What the page has drawn over the controls' corners. The controls and
    /// the logo stay hidden while any of these is open, so closing one over
    /// another does not bring them back on top of it. `popup` is the page's
    /// own `hideControls`, for a menu it places where they float.
    enum Cover { case layerSwitcher, expandedSheet, popup }

    func setCovered(_ cover: Cover, _ covered: Bool) {
        if covered { covers.insert(cover) } else { covers.remove(cover) }
        refreshCovers()
    }

    /// A new page, or none: nothing it drew is open any more.
    func clearCovers() {
        covers.removeAll()
        refreshCovers()
    }

    private func refreshCovers() {
        setMapControlsHidden(!covers.isEmpty)
        setLogoHidden(!covers.isEmpty)
    }

    /// Shows or hides the floating map controls as one unit.
    /// On iOS 26 and later the unit is the glass container. Before iOS 26 it
    /// is the `TribbleButton` artwork and the three buttons.
    func setMapControlsHidden(_ hidden: Bool) {
        if let glassControls {
            glassControls.isHidden = hidden
        } else {
            trippleButton.isHidden = hidden
            settingsButton.isHidden = hidden
            layerSwitcherButton.isHidden = hidden
            positionButton.isHidden = hidden
            shareButtonBackdrop?.isHidden = hidden
            arButtonBackdrop?.alpha = hidden ? 0 : 1
        }
    }

    /// Shows or hides the logo together with its glass disc.
    /// Hiding only the logo would leave an empty glass disc over the map.
    func setLogoHidden(_ hidden: Bool) {
        logo.isHidden = hidden
        glassLogo?.isHidden = hidden
        stormLogBackdrop?.isHidden = hidden
        alertsBackdrop?.isHidden = hidden
    }

}

// MARK: - Loading status

extension ViewController {
    /// A spinner and "trying again" in the middle of the map, on a backdrop
    /// that keeps it legible over a blank or half-drawn page. It takes no
    /// touches: the map behind stays usable, and nothing looks like a button
    /// that does nothing.
    fileprivate func installLoadStatus() {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        let label = UILabel()
        label.text = NSLocalizedString("map_load_failed", comment: "")
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.accessibilityIdentifier = "map.status"
        loadStatus.addArrangedSubview(spinner)
        loadStatus.addArrangedSubview(label)
        loadStatus.spacing = 10
        loadStatus.alignment = .center
        loadStatus.translatesAutoresizingMaskIntoConstraints = false

        let backdrop: UIVisualEffectView
        if #available(iOS 26.0, *) {
            backdrop = LiquidGlass.element(interactive: false)
            backdrop.cornerConfiguration = .uniformCorners(radius: .fixed(20))
        } else {
            backdrop = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
            backdrop.layer.cornerRadius = 20
            backdrop.clipsToBounds = true
            backdrop.translatesAutoresizingMaskIntoConstraints = false
        }
        backdrop.isUserInteractionEnabled = false
        backdrop.contentView.addSubview(loadStatus)
        view.addSubview(backdrop)
        NSLayoutConstraint.activate([
            loadStatus.topAnchor.constraint(equalTo: backdrop.contentView.topAnchor, constant: 14),
            loadStatus.bottomAnchor.constraint(equalTo: backdrop.contentView.bottomAnchor, constant: -14),
            loadStatus.leadingAnchor.constraint(equalTo: backdrop.contentView.leadingAnchor, constant: 18),
            loadStatus.trailingAnchor.constraint(equalTo: backdrop.contentView.trailingAnchor, constant: -18),
            backdrop.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            backdrop.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            backdrop.widthAnchor.constraint(lessThanOrEqualTo: view.readableContentGuide.widthAnchor),
        ])
        backdrop.isHidden = true
        loadStatus.isHidden = true
        loadStatusBackdrop = backdrop
    }
}

// MARK: - Logo

extension ViewController {
    /// The logo is the way home: a tap brings back the radar map. Five taps
    /// in a row show or hide the `HiddenFeatures`.
    fileprivate func configureLogo() {
        // On iOS 26 the glass disc around the logo is the larger target.
        let target: UIView = glassLogo ?? logo
        target.isUserInteractionEnabled = true
        target.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(logoTapped)))
        target.isAccessibilityElement = true
        target.accessibilityLabel = "meteocool"
        target.accessibilityHint = NSLocalizedString("show_radar_hint", comment: "")
        target.accessibilityTraits = .button
        target.accessibilityIdentifier = "map.logo"
    }

    @objc private func logoTapped() {
        if HiddenFeatures.logoTapped() {
            feedbackHeavy?.impactOccurred()
        }
        showRadarMap()
    }

    /// Leaves whatever the page shows for the radar map: closes the panels on
    /// top (About, a storm's panel, the point menu) through their own Escape
    /// handling, and switches from any other map (3D, lightning)
    /// to the radar, as picking it in the layer switcher does.
    /// A page that is down is retried at once instead, and one that has
    /// navigated away is replaced by the map.
    private func showRadarMap() {
        if let nativeMap {
            nativeMap.showLive()
            return
        }
        if let host = webView.url?.host, host != MeteocoolEnvironment.current.webURL.host {
            loadMap()
            return
        }
        guard webviewReady else {
            recovery.hurry(restoringView: false)
            return
        }
        webView.evaluateJavaScript("""
            (() => {
              window.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape" }));
              const lm = window.lm;
              if (lm && lm.currentCap !== "radar" && lm.getCapability?.("radar")) lm.setTarget("radar", "map");
            })();
            """)
    }
}

// MARK: - Storm log

extension ViewController {
    /// The pill beside the logo: a logbook, opening the storms that passed the phone.
    fileprivate func configureStormLogButton() {
        stormLogButton.setImage(UIImage(systemName: "book", withConfiguration: UIImage.SymbolConfiguration(scale: .large)), for: .normal)
        stormLogButton.accessibilityLabel = NSLocalizedString("storm_log_title", value: "Storm Log", comment: "")
        stormLogButton.accessibilityIdentifier = "map.stormLog"
        stormLogButton.addAction(UIAction { [weak self] _ in self?.openStormLog() }, for: .touchUpInside)
    }

    /// Before iOS 26 the logbook and the bell are blurred discs beside the logo artwork.
    fileprivate func installClassicStormLogButton() {
        stormLogBackdrop = classicDisc(for: stormLogButton, rightOf: logo)
        alertsBackdrop = classicDisc(for: alertsButton, rightOf: stormLogBackdrop!)
    }

    private func classicDisc(for button: UIButton, rightOf anchor: UIView) -> UIView {
        let disc = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
        disc.layer.cornerRadius = 22
        disc.clipsToBounds = true
        disc.translatesAutoresizingMaskIntoConstraints = false
        button.translatesAutoresizingMaskIntoConstraints = false
        button.tintColor = .label
        disc.contentView.addSubview(button)
        view.addSubview(disc)
        NSLayoutConstraint.activate([
            disc.widthAnchor.constraint(equalToConstant: 44),
            disc.heightAnchor.constraint(equalToConstant: 44),
            disc.leadingAnchor.constraint(equalTo: anchor.trailingAnchor, constant: 8),
            disc.centerYAnchor.constraint(equalTo: logo.centerYAnchor),
            button.leadingAnchor.constraint(equalTo: disc.contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: disc.contentView.trailingAnchor),
            button.topAnchor.constraint(equalTo: disc.contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: disc.contentView.bottomAnchor),
        ])
        return disc
    }

    func openStormLog() {
        StormLogViewController.open(from: self)
    }

    /// The bell: a red dot on it for alerts since the list was last opened,
    /// as Better Rain Alarm's bell shows them.
    fileprivate func configureAlertsButton() {
        alertsButton.accessibilityLabel = NSLocalizedString("past_alerts_title", value: "Past Alerts", comment: "")
        alertsButton.accessibilityIdentifier = "map.alerts"
        alertsButton.addAction(UIAction { [weak self] _ in self?.openPastAlerts() }, for: .touchUpInside)
        showAlertsBadge(false)
    }

    private func showAlertsBadge(_ unseen: Bool) {
        let large = UIImage.SymbolConfiguration(scale: .large)
        let image = unseen
            ? UIImage(systemName: "bell.badge", withConfiguration: large.applying(UIImage.SymbolConfiguration(paletteColors: [.systemRed, .label])))
            : UIImage(systemName: "bell", withConfiguration: large)
        alertsButton.setImage(image, for: .normal)
        alertsButton.accessibilityValue = unseen ? NSLocalizedString("past_alerts_new", value: "New", comment: "") : nil
    }

    /// Reads the list again, with the delivered alerts, and draws the dot.
    func refreshAlertsBadge() {
        Task { [weak self] in
            let unseen = await PastAlertsViewController.unseen()
            self?.showAlertsBadge(unseen > 0)
        }
    }

    func openPastAlerts() {
        let list = UINavigationController(rootViewController: PastAlertsViewController())
        list.presentationController?.delegate = self
        present(list, animated: true)
    }
}

extension ViewController: UIAdaptivePresentationControllerDelegate {
    /// The list marks the alerts seen; the dot goes once it is put away.
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        refreshAlertsBadge()
    }
}

// MARK: - AR storm view

extension ViewController {
    fileprivate func configureARButton() {
        arButton.setImage(UIImage(systemName: "arkit", withConfiguration: UIImage.SymbolConfiguration(scale: .large)), for: .normal)
        arButton.accessibilityLabel = NSLocalizedString("map_ar", comment: "")
        arButton.accessibilityIdentifier = "map.ar"
        arButton.addAction(UIAction { [weak self] _ in self?.presentAR(target: self?.mapSelection) }, for: .touchUpInside)
        arButton.isHidden = true
    }

    /// Before iOS 26 the three buttons are painted onto one slab of artwork;
    /// the AR button gets a blurred disc of its own underneath the share one.
    fileprivate func installClassicARButton() {
        let disc = classicDisc(for: arButton, below: shareButtonBackdrop ?? trippleButton)
        disc.isHidden = true
        arButtonBackdrop = disc
    }

    /// A blurred disc for a button below the `TribbleButton` slab, the way
    /// the controls looked before iOS 26.
    fileprivate func classicDisc(for button: UIButton, below anchor: UIView) -> UIView {
        let disc = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
        disc.layer.cornerRadius = 22
        disc.clipsToBounds = true
        disc.translatesAutoresizingMaskIntoConstraints = false
        button.translatesAutoresizingMaskIntoConstraints = false
        button.tintColor = .label
        disc.contentView.addSubview(button)
        view.addSubview(disc)
        NSLayoutConstraint.activate([
            disc.widthAnchor.constraint(equalToConstant: 44),
            disc.heightAnchor.constraint(equalToConstant: 44),
            disc.centerXAnchor.constraint(equalTo: trippleButton.centerXAnchor),
            disc.topAnchor.constraint(equalTo: anchor.bottomAnchor, constant: 10),
            button.leadingAnchor.constraint(equalTo: disc.contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: disc.contentView.trailingAnchor),
            button.topAnchor.constraint(equalTo: disc.contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: disc.contentView.bottomAnchor),
        ])
        return disc
    }

    private func setARButtonVisible(_ visible: Bool) {
        arButton.isHidden = !visible
        arButtonBackdrop?.isHidden = !visible
    }

    /// Offers the AR view only while the `HiddenFeatures` are on (five taps
    /// on the logo), and only where it can work: ARKit, or the simulator's
    /// preview in debug builds. Whoever turned it on asked for it, so it is
    /// offered on a quiet day too, where the view says no storm is in range.
    func refreshARButton() {
        setARButtonVisible(HiddenFeatures.unlocked && ARStormViewController.isAvailable)
    }

    /// The page learns about the AR view only from a script that runs before
    /// it loads, so turning the hidden features on or off reloads the map:
    /// a storm's panel then offers "View in AR", or stops offering it.
    @objc fileprivate func hiddenFeaturesChanged() {
        refreshARButton()
        installUserScripts()
        loadMap()
    }

    /// The scripts that run before the page: the geolocation shim, the
    /// graphics watch, and what the app can do for the page
    /// (`window.nativeCapabilities`): the share sheet, which makes the page
    /// show its share buttons (core's lib/share.ts), and, while the AR view is
    /// offered, AR, so a storm's panel offers "View in AR" and the page reports
    /// its selection (core's lib/nativeAR.ts).
    fileprivate func installUserScripts() {
        guard let controller = webView?.configuration.userContentController else { return }
        controller.removeAllUserScripts()
        controller.addUserScript(GeolocationBridge.userScript)
        controller.addUserScript(MapRecovery.graphicsWatch)
        let capabilities = HiddenFeatures.unlocked && ARStormViewController.isAvailable ? "{ share: true, ar: true }" : "{ share: true }"
        controller.addUserScript(WKUserScript(
            source: "window.nativeCapabilities = Object.assign(window.nativeCapabilities || {}, \(capabilities));",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    /// The page's storm messages: `openAR:<volume path or cell code>` from a
    /// storm's panel, and the selection as it changes. True when handled.
    /// The page is the app's own, but its strings are still checked before use.
    fileprivate func handleStormMessage(_ action: String) -> Bool {
        func target(_ value: Substring) -> StormTarget? {
            let value = String(value)
            if MapLink.isCellCode(value) { return .cell(value) }
            if MapLink.isVolumePath(value) { return .volume(value) }
            return nil
        }
        if action.hasPrefix("openAR:") {
            presentAR(target: target(action.dropFirst("openAR:".count)) ?? mapSelection)
            return true
        }
        if action.hasPrefix("cloudSelected:") || action.hasPrefix("cellSelected:") {
            mapSelection = action.split(separator: ":", maxSplits: 1).last.flatMap(target)
            return true
        }
        if action == "selectionCleared" {
            mapSelection = nil
            return true
        }
        return false
    }

    func presentAR(target: StormTarget?, marker: ARMarker? = nil) {
        guard presentedViewController == nil, HiddenFeatures.unlocked, ARStormViewController.isAvailable else { return }
        let ar = ARStormViewController(target: target, marker: marker)
        ar.onOpenOnMap = { [weak self] search in self?.openLink(search: search) }
        ar.onClose = { [weak self] in self?.arDidClose() }
        present(ar, animated: true)
    }

    /// Opens a link's search in the map without reloading it: a shared link
    /// (`SceneDelegate`), or the storm chosen in the AR view. Held until the
    /// page reports in if it is still loading.
    ///
    /// The link says where to look, so it wins over the user's position, as
    /// it does on the web (core's `linkPlacesView`): the next fix moves the
    /// dot without centring on it, and following stops as if the map had
    /// been dragged.
    func openLink(search: String) {
        linkPlacedView = true
        if let nativeMap {
            pendingLink = nil
            nativeMap.open(search: search)
        } else {
            guard webviewReady else {
                pendingLink = search
                return
            }
            pendingLink = nil
            guard let script = MapLink.openScript(search: search) else { return }
            webView.evaluateJavaScript(script)
        }
        autoFocusOnce = false
        zoomOnce = false
        if locationStateMachine?.state == .tracking {
            locationStateMachine?.trigger(.mapMove)
        }
    }

    private func arDidClose() {
        // The AR view started accurate updates; the map keeps them only if
        // its own location button wants them.
        if locationStateMachine?.state == .off {
            SharedLocationUpdater.stopAccurateLocationUpdates()
        }
        setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}

// MARK: - Sharing

extension ViewController {
    /// The system share sheet for a link to the map, from one of the page's
    /// share buttons, the map's own (`shareMap`) or a screenshot
    /// (`screenshotTaken`). `image` is the map as it was, offered beside the
    /// link for a screenshot. `source` is a native control an iPad's popover
    /// points at, in place of the page's rect.
    func presentShare(_ share: MapShare, image: UIImage? = nil, from source: UIView? = nil, over presenter: UIViewController? = nil) {
        let presenter = presenter ?? self
        guard presenter.presentedViewController == nil else { return }
        var items: [Any] = [MapLinkItem(share: share, image: image)]
        if let image { items.append(image) }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = mapSurface
            if let source {
                popover.sourceView = source
                popover.sourceRect = source.bounds
            } else if let rect = share.sourceRect?.intersection(mapSurface.bounds), !rect.isNull {
                popover.sourceRect = rect
            } else {
                // Nothing on the page to point at: the middle of the map, no arrow.
                popover.sourceRect = CGRect(x: mapSurface.bounds.midX, y: mapSurface.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
        }
        sheet.view.accessibilityIdentifier = "map.share"
        presenter.present(sheet, animated: true)
    }

    /// The reader just took a screenshot of the map: most likely to send it
    /// to someone. Offer the share sheet with a link to the same view beside
    /// the picture, so whoever gets it can open the map where it was.
    ///
    /// Only over the map itself, with nothing on top (settings, onboarding,
    /// the AR view, a share sheet already up), and only once the page can say
    /// what it shows: a page from before sharing has no `window.shareLink`.
    @objc fileprivate func screenshotTaken() {
        guard mapReady, presentedViewController == nil, view.window != nil,
              UIApplication.shared.applicationState == .active else { return }
        if let nativeMap {
            if let share = nativeMap.share() { presentShare(share, image: nativeMap.snapshot()) }
            return
        }
        currentShareLink { [weak self] share in
            self?.webView.takeSnapshot(with: nil) { [weak self] image, _ in
                self?.presentShare(share, image: image)
            }
        }
    }

    /// The map's own share button, under the location button: a link to
    /// what is on screen, whichever map it is and whatever frame it is on.
    /// The page's player no longer carries one (core's lib/ShareControl.ts).
    fileprivate func configureShareButton() {
        shareButton.setImage(UIImage(systemName: "square.and.arrow.up", withConfiguration: UIImage.SymbolConfiguration(scale: .large)), for: .normal)
        // The symbol sits low in its frame; centred as drawn it looks dropped in its disc.
        shareButton.imageView?.transform = CGAffineTransform(translationX: 0, y: -6)
        shareButton.accessibilityLabel = NSLocalizedString("map_share", comment: "")
        shareButton.accessibilityIdentifier = "map.share.button"
        shareButton.addAction(UIAction { [weak self] _ in self?.shareMap() }, for: .touchUpInside)
    }

    fileprivate func shareMap() {
        guard mapReady, presentedViewController == nil else { return }
        currentShareLink { [weak self] share in
            guard let self else { return }
            self.presentShare(share, from: self.shareButtonBackdrop ?? self.shareButton)
        }
    }

    /// Before iOS 26: a blurred disc of its own under the `TribbleButton`.
    fileprivate func installClassicShareButton() {
        shareButtonBackdrop = classicDisc(for: shareButton, below: trippleButton)
    }

    /// What the page says a link to the map should be. Nothing from a page
    /// that predates sharing, which has no `window.shareLink`.
    private func currentShareLink(_ handler: @escaping (MapShare) -> Void) {
        if let share = nativeMap?.share() {
            handler(share)
            return
        }
        webView.evaluateJavaScript("JSON.stringify(window.shareLink ? window.shareLink() : null)") { result, _ in
            guard let json = result as? String,
                  let share = MapShare(json: json, mapHost: MeteocoolEnvironment.current.webURL.host) else { return }
            handler(share)
        }
    }
}

/// The link in a share sheet: the URL itself for every destination, with a
/// title for the sheet's header and a mail's subject, and the map's picture
/// (or the logo) as the header's preview.
private final class MapLinkItem: NSObject, UIActivityItemSource {
    private let share: MapShare
    private let image: UIImage?

    init(share: MapShare, image: UIImage?) {
        self.share = share
        self.image = image
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        share.url
    }

    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        share.url
    }

    func activityViewController(_ activityViewController: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
        share.title
    }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.originalURL = share.url
        metadata.url = share.url
        metadata.title = share.title
        if let image {
            metadata.imageProvider = NSItemProvider(object: image)
        } else if let logo = UIImage(named: "Logo") {
            metadata.iconProvider = NSItemProvider(object: logo)
        }
        return metadata
    }
}

// MARK: - Native map

extension ViewController: NativeMapHost {
    @discardableResult
    func presentOverMap(_ controller: UIViewController) -> Bool {
        guard presentedViewController == nil else { return false }
        present(controller, animated: true)
        return true
    }

    func mapCovered(_ covered: Bool, by owner: String) {
        setCovered(.expandedSheet, covered)
    }

    func openAR(_ target: StormTarget?) {
        presentAR(target: target)
    }

    func openAR(marking marker: ARMarker) {
        presentAR(target: nil, marker: marker)
    }

    func shareFromMap(_ share: MapShare, source: UIView?) {
        // Over a sheet of the map's own (a storm's) when one is up.
        presentShare(share, from: source, over: presentedViewController)
    }

    var arAvailable: Bool { HiddenFeatures.unlocked && ARStormViewController.isAvailable }
}
