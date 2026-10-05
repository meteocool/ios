import UIKit
import UIKit.UIGestureRecognizer
import WebKit
import CoreLocation

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
    private var recovery: MapRecovery!
    /// "Trying again" over the map while it keeps failing to load.
    /// Not a button: `MapRecovery` retries on its own.
    private let loadStatus = UIStackView()
    private var loadStatusBackdrop: UIView?

    /// Glass views that replace the flat blur and the `TribbleButton` artwork
    /// on iOS 26. Nil before iOS 26, where the storyboard blur and artwork stay.
    private var glassControls: UIVisualEffectView?
    private var glassLogo: UIVisualEffectView?

    /// Opens the AR storm view. Shown only where AR works and a storm is in
    /// range; see `refreshARButton`.
    let arButton = UIButton(type: .system)
    /// The AR button's own glass element (iOS 26) or blur disc (before), so
    /// hiding it leaves no empty backdrop.
    private var arButtonBackdrop: UIView?
    /// The storm selected on the map, from the page's `cloudSelected:` and
    /// `cellSelected:` messages: what the AR view looks for when opened.
    private var mapSelection: StormTarget?
    private var arStormsNearby = false
    private var arCheckedAt = Date.distantPast
    private var arCheck: Task<Void, Never>?
    
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
        webView?.configuration.userContentController.addUserScript(GeolocationBridge.userScript)
        webView?.configuration.userContentController.addUserScript(MapRecovery.graphicsWatch)
        // Declares the AR storm view to the page before it loads, so a storm's
        // panel offers "View in AR" and the page reports its selection
        // (core's lib/nativeAR.ts).
        if ARStormViewController.isAvailable {
            webView?.configuration.userContentController.addUserScript(WKUserScript(
                source: "window.nativeCapabilities = Object.assign(window.nativeCapabilities || {}, { ar: true });",
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        
        // Pinch and rotation also end follow mode, not only pan. While
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

        configureARButton()
        if #available(iOS 26.0, *) {
            applyLiquidGlass()
        } else {
            installClassicARButton()
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

        // disable scrolling & bouncing effects
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.delegate = self

        // The map URL carries the app version from the bundle
        // (`MeteocoolEnvironment`). The frontend reads it to decide which
        // native calls it may make. Do not hardcode it: a hardcoded "2.2"
        // stayed in the URL after the app version changed.
        webView.navigationDelegate = self
        installLoadStatus()
        recovery = MapRecovery(webView: webView, reload: { [weak self] in
            self?.loadMap()
        }, wentDown: { [weak self] in
            self?.mapWentDown()
        }, showStatus: { [weak self] visible in
            self?.loadStatusBackdrop?.isHidden = !visible
            self?.loadStatus.isHidden = !visible
        })
        loadMap()

        NotificationCenter.default.addObserver(self, selector: #selector(ViewController.injectSettings),
                                               name: NSNotification.Name("SettingsChanged"), object: nil)
        // Mode in Settings, or "Disable Demo Mode", switched the deployment:
        // load that deployment's map. No restart.
        NotificationCenter.default.addObserver(self, selector: #selector(loadMap),
                                               name: MeteocoolEnvironment.didChange, object: nil)
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
        guard webviewReady, locationStateMachine?.state == .off,
              status == .authorizedWhenInUse || status == .authorizedAlways else { return }
        if userDefaults?.bool(forKey: "autoZoom") == true {
            zoomOnce = true
        }
        locationStateMachine?.trigger(.buttonPress)
    }

    /// Loads the map page from scratch. `MapRecovery` calls it again until
    /// the page reports in with `requestSettings`.
    @objc private func loadMap() {
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
        setMapControlsHidden(false)
        setLogoHidden(false)
    }

    /// Every new page has to report in, including one the page loads itself
    /// (core's service worker reloads it after an update).
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        webviewReady = false
        layerSwitcherButton.isEnabled = false
        recovery.loadStarted()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // Cancelled means another load replaced this one.
        if (error as NSError).code != NSURLErrorCancelled { recovery.failed(.navigation) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        // A page that reported in runs, whatever happened to the rest of its load.
        if (error as NSError).code != NSURLErrorCancelled, !webviewReady { recovery.failed(.navigation) }
    }

    /// The web content process died: out of memory, or a GPU fault.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        recovery.failed(.crash)
    }

    @objc func willResignActive() {
        if webviewReady { webView.evaluateJavaScript("window.leaveForeground?.();") }
    }

    @objc func willEnterForeground() {
        guard webviewReady else { return }
        if userDefaults?.bool(forKey: "autoZoom") == true {
            zoomOnce = true
            autoFocusOnce = true
        }
        if locationStateMachine?.state != .off {
            SharedLocationUpdater.startAccurateLocationUpdates()
            SharedLocationUpdater.requestLocation(observer: self, explicit: false)
        }
    }

    @objc func didBecomeActive(){
        if webviewReady {
            self.webView.evaluateJavaScript("window.enterForeground?.();")
        }
        recovery.becameActive()
    }

    @IBAction func locationButton(sender: AnyObject){
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
        setMapControlsHidden(true)
        setLogoHidden(true)
        webView.evaluateJavaScript("window.openLayerswitcher();") { [weak self] _, error in
            if error != nil {
                self?.setMapControlsHidden(false)
                self?.setLogoHidden(false)
            }
        }
    }
    
    func notify(location: CLLocation) {
        refreshARButton(near: location)
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

            setMapControlsHidden(false)
            refreshARButton(near: SharedLocationUpdater.getCurrentLocation())
        }
        
        if action == "layerSwitcherOpened" {
            setMapControlsHidden(true)
            setLogoHidden(true)
        }

        if action == "layerSwitcherClosed" {
            setMapControlsHidden(false)
            setLogoHidden(false)
        }

        if action == "detailSheetExpanded" {
            setMapControlsHidden(true)
            setLogoHidden(true)
        }

        if action == "detailSheetCollapsed" {
            setMapControlsHidden(false)
            setLogoHidden(false)
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

    /// Replaces the `TribbleButton` slab and the three buttons on top of it
    /// with a glass container holding three interactive glass elements.
    /// The container makes them render as one pill shape. Glass cannot sample
    /// other glass, so ungrouped neighbours would each sample the map instead.
    @available(iOS 26.0, *)
    private func installGlassControls() {
        let controls = [layerSwitcherButton!, settingsButton!, positionButton!, arButton]

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
    /// onto a glass disc.
    /// The disc matches the glass control column on the other side of the
    /// screen. `TribbleButton` got the same change, because a painted slab
    /// next to real glass looks out of place.
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
        view.addSubview(glass)
        glassLogo = glass

        NSLayoutConstraint.activate([
            glass.widthAnchor.constraint(equalToConstant: 52),
            glass.heightAnchor.constraint(equalToConstant: 52),
            glass.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            glass.topAnchor.constraint(equalTo: blur.bottomAnchor, constant: 12),
            logo.centerXAnchor.constraint(equalTo: glass.contentView.centerXAnchor),
            logo.centerYAnchor.constraint(equalTo: glass.contentView.centerYAnchor),
            logo.widthAnchor.constraint(equalToConstant: 30),
            logo.heightAnchor.constraint(equalToConstant: 30),
        ])
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
            arButtonBackdrop?.alpha = hidden ? 0 : 1
        }
    }

    /// Shows or hides the logo together with its glass disc.
    /// Hiding only the logo would leave an empty glass disc over the map.
    func setLogoHidden(_ hidden: Bool) {
        logo.isHidden = hidden
        glassLogo?.isHidden = hidden
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
    /// handling, and switches from any other map (3D, satellite, lightning)
    /// to the radar, as picking it in the layer switcher does.
    /// A page that is down is retried at once instead, and one that has
    /// navigated away is replaced by the map.
    private func showRadarMap() {
        if let host = webView.url?.host, host != MeteocoolEnvironment.current.webURL.host {
            loadMap()
            return
        }
        guard webviewReady else {
            recovery.hurry()
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
    /// the AR button gets a blurred disc of its own underneath it.
    fileprivate func installClassicARButton() {
        let disc = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
        disc.layer.cornerRadius = 22
        disc.clipsToBounds = true
        disc.translatesAutoresizingMaskIntoConstraints = false
        arButton.translatesAutoresizingMaskIntoConstraints = false
        arButton.tintColor = .label
        disc.contentView.addSubview(arButton)
        view.addSubview(disc)
        NSLayoutConstraint.activate([
            disc.widthAnchor.constraint(equalToConstant: 44),
            disc.heightAnchor.constraint(equalToConstant: 44),
            disc.centerXAnchor.constraint(equalTo: trippleButton.centerXAnchor),
            disc.topAnchor.constraint(equalTo: trippleButton.bottomAnchor, constant: 10),
            arButton.leadingAnchor.constraint(equalTo: disc.contentView.leadingAnchor),
            arButton.trailingAnchor.constraint(equalTo: disc.contentView.trailingAnchor),
            arButton.topAnchor.constraint(equalTo: disc.contentView.topAnchor),
            arButton.bottomAnchor.constraint(equalTo: disc.contentView.bottomAnchor),
        ])
        disc.isHidden = true
        arButtonBackdrop = disc
    }

    private func setARButtonVisible(_ visible: Bool) {
        arButton.isHidden = !visible
        arButtonBackdrop?.isHidden = !visible
    }

    /// Offer the AR view where it can work and has something to show: ARKit
    /// (or the simulator's preview, in debug builds) and a storm within
    /// range. Asked at most every five minutes; the list is a few kilobytes.
    func refreshARButton(near location: CLLocation?) {
        guard ARStormViewController.isAvailable else { return setARButtonVisible(false) }
        #if DEBUG
        // Debug builds always offer it: the simulator's preview stands near a
        // storm wherever it is, and a test phone should open AR on a quiet
        // day too, where the view says no storm is in range.
        setARButtonVisible(true)
        return
        #else
        guard let location, location.horizontalAccuracy >= 0 else { return }
        guard Date().timeIntervalSince(arCheckedAt) > 300, arCheck == nil else { return }
        arCheckedAt = Date()
        arCheck = Task { [weak self] in
            let nearby = await StormFeed.anyStorm(nearLat: location.coordinate.latitude, lon: location.coordinate.longitude)
            guard let self else { return }
            self.arCheck = nil
            if let nearby { self.arStormsNearby = nearby }
            self.setARButtonVisible(self.arStormsNearby)
        }
        #endif
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

    func presentAR(target: StormTarget?) {
        guard presentedViewController == nil, ARStormViewController.isAvailable else { return }
        let ar = ARStormViewController(target: target)
        ar.onOpenOnMap = { [weak self] search in self?.openStormOnMap(search) }
        ar.onClose = { [weak self] in self?.arDidClose() }
        present(ar, animated: true)
    }

    /// Show the storm chosen in the AR view on the 3D map, without a reload.
    private func openStormOnMap(_ search: String) {
        guard webviewReady, let script = MapLink.openScript(search: search) else { return }
        webView.evaluateJavaScript(script)
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
