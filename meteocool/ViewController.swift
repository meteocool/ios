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
    private var loadTimeout: Task<Void, Never>?
    private let retryButton = UIButton(type: .system)

    /// Glass chrome that supersedes the flat blur and the `TribbleButton`
    /// artwork on iOS 26. Nil on older systems, which keep the shipped look.
    private var glassControls: UIVisualEffectView?
    private var glassLogo: UIVisualEffectView?
    
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
    
    @objc func tapOrPan() {
        if (locationStateMachine?.state == .tracking) {
            locationStateMachine?.trigger(.mapMove)
        }
    }
    
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
      return true
    }
    
    override func loadView() {
        super.loadView()
        viewController = self

        webView?.configuration.userContentController.add(self, name: "scriptHandler")
        // Before the page loads: the shim has to be in place for the first
        // script that might touch navigator.geolocation.
        webView?.configuration.userContentController.add(self, name: GeolocationBridge.handlerName)
        webView?.configuration.userContentController.addUserScript(GeolocationBridge.userScript)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        
        let panRecognizer = UIPanGestureRecognizer(target: self, action: #selector(self.tapOrPan))

        panRecognizer.minimumNumberOfTouches = 1
        panRecognizer.maximumNumberOfTouches = 1
        panRecognizer.delegate = self
        view.addGestureRecognizer(panRecognizer)
        
        self.view.addSubview(webView!)
        self.view.addSubview(trippleButton!)
        self.view.addSubview(settingsButton!)
        self.view.addSubview(positionButton!)
        self.view.addSubview(layerSwitcherButton!)
        self.view.addSubview(logo!)
        self.view.addSubview(blur!)

        if #available(iOS 26.0, *) {
            applyLiquidGlass()
        }

        setMapControlsHidden(false)
        settingsButton.accessibilityLabel = NSLocalizedString("Settings", comment: "")
        settingsButton.accessibilityIdentifier = "map.settings"
        positionButton.accessibilityLabel = NSLocalizedString("Location Access", comment: "")
        positionButton.accessibilityIdentifier = "map.location"
        layerSwitcherButton.accessibilityLabel = NSLocalizedString("map_layers", comment: "")
        layerSwitcherButton.accessibilityIdentifier = "map.layers"
        layerSwitcherButton.isEnabled = false
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
                SharedLocationUpdater.stopAccurateLocationUpdates()
                self.positionButton.setImage(UIImage(systemName: "location",withConfiguration: UIImage.SymbolConfiguration(scale: .large)),for: .normal)
                self.webView.evaluateJavaScript("window.lm.updateLocation(-1, -1, -1, false, false);")
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

        // The version is read from the bundle rather than written out here,
        // which had drifted: the app was 2.2 in the URL long after the build
        // had moved on, and the frontend reads it to decide what it may call.
        webView.navigationDelegate = self
        retryButton.setTitle(NSLocalizedString("map_load_failed", comment: "") + "\n" + NSLocalizedString("retry", comment: ""), for: .normal)
        retryButton.titleLabel?.numberOfLines = 0
        retryButton.titleLabel?.textAlignment = .center
        retryButton.configuration = .filled()
        retryButton.accessibilityIdentifier = "map.retry"
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.addTarget(self, action: #selector(loadMap), for: .touchUpInside)
        view.addSubview(retryButton)
        NSLayoutConstraint.activate([
            retryButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            retryButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            retryButton.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.8),
        ])
        loadMap()

        NotificationCenter.default.addObserver(self, selector: #selector(ViewController.injectSettings),
                                               name: NSNotification.Name("SettingsChanged"), object: nil)
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

        guard userDefaults?.bool(forKey: "onboardingDone") != true,
              presentedViewController == nil, !onboardingPresented else { return }
        onboardingPresented = true
        let notifications: OnboardingAction = { completion in
            SharedNotificationManager.registerForPushNotifications { _, _ in
                // Permission denial is a valid choice, so onboarding proceeds.
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
            if SharedNotificationManager.enabled {
                SharedLocationUpdater.requestBackgroundAuthorization()
                SharedLocationUpdater.refreshNotificationRegistration()
            }
        }
        present(onboarding, animated: true)
    }

    private var onboardingPresented = false

    @objc private func loadMap() {
        loadTimeout?.cancel()
        retryButton.isHidden = true
        webviewReady = false
        layerSwitcherButton.isEnabled = false
        webView.load(URLRequest(url: MeteocoolEnvironment.current.webURL))
        loadTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            self?.mapFailed()
        }
    }

    private func mapFailed() {
        loadTimeout?.cancel()
        webviewReady = false
        layerSwitcherButton.isEnabled = false
        retryButton.isHidden = false
        setMapControlsHidden(false)
        setLogoHidden(false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { mapFailed() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        mapFailed()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        mapFailed()
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
        guard webviewReady else { return }
        let jsCommand = "window.lm.updateLocation(\(location.coordinate.latitude), \(location.coordinate.longitude), \(location.horizontalAccuracy), \(zoomOnce), \(autoFocus || autoFocusOnce));"
        webView.evaluateJavaScript(jsCommand)
        // Same fix, in the shape the Geolocation API asks for: this is what
        // resolves a page-side getCurrentPosition and keeps watchers running.
        GeolocationBridge.deliver(location, to: webView)
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

        if action == "requestSettings" {
            loadTimeout?.cancel()
            retryButton.isHidden = true
            webviewReady = true
            layerSwitcherButton.isEnabled = true
            injectSettings()

            if (userDefaults?.bool(forKey: "onboardingDone") ?? false) {
                if (locationStateMachine?.state == .off && (SharedLocationUpdater.authorizationStatus == .authorizedWhenInUse || SharedLocationUpdater.authorizationStatus == .authorizedAlways)) {
                    if ((userDefaults?.bool(forKey: "autoZoom")) ?? false) {
                        self.zoomOnce = true
                    }
                    locationStateMachine?.trigger(.buttonPress)
                }
            }

            setMapControlsHidden(false)
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
    /// Answers `navigator.geolocation` out of CoreLocation.
    ///
    /// The page reaches this only through `GeolocationBridge`'s shim, so the
    /// permission in play is the app's own — WebKit's per-origin location
    /// alert never comes up, and a user who granted location once is not asked
    /// a second time by the web view.
    fileprivate func serveGeolocationRequest() {
        switch SharedLocationUpdater.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            if let location = SharedLocationUpdater.getCurrentLocation() {
                GeolocationBridge.deliver(location, to: webView)
            } else {
                // Nothing cached yet. The fix lands in notify(location:),
                // which hands it to the shim.
                SharedLocationUpdater.startAccurateLocationUpdates()
            }
        case .notDetermined:
            // The app's own prompt, with the app's purpose string, instead of
            // WebKit's — and only because the page asked for a position.
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
    /// Swaps the flat map chrome for glass. Only the navigation layer is
    /// touched — the radar map underneath is content and stays untreated.
    @available(iOS 26.0, *)
    fileprivate func applyLiquidGlass() {
        // Status bar backdrop. The storyboard nests a 2pt vibrancy sliver in
        // here; vibrancy cannot live inside glass, and it has not been visible
        // for years anyway.
        blur.contentView.subviews.forEach { $0.removeFromSuperview() }
        blur.effect = UIGlassEffect(style: .regular)

        installGlassControls()
        installGlassLogo()

    }

    /// Replaces the `TribbleButton` slab, and the three buttons glued on top of
    /// it, with a glass container holding three interactive glass elements.
    /// The container is what makes them read as one pill: glass cannot sample
    /// other glass, so ungrouped neighbours each sample the map instead.
    @available(iOS 26.0, *)
    private func installGlassControls() {
        let controls = [layerSwitcherButton!, settingsButton!, positionButton!]

        // These were pinned to the artwork and to each other; reparenting them
        // leaves those constraints dangling across the hierarchy.
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

    /// Lifts the logo off the opaque plate baked into the `Logo Button`
    /// artwork and onto a glass disc that mirrors the control column on the
    /// other edge of the screen — the same swap `TribbleButton` got, since a
    /// painted-on slab next to real glass reads as a sticker.
    @available(iOS 26.0, *)
    private func installGlassLogo() {
        // Pinned to the safe area and sized for the artwork; both go with it.
        LiquidGlass.dropConstraints(on: view, referencing: [logo])
        NSLayoutConstraint.deactivate(logo.constraints)
        logo.removeFromSuperview()

        logo.image = UIImage(named: "Logo")
        logo.contentMode = .scaleAspectFit
        logo.translatesAutoresizingMaskIntoConstraints = false

        let glass = LiquidGlass.element(interactive: false)
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

    /// The floating map controls, shown and hidden as one unit — which side of
    /// the iOS 26 divide we are on decides what that unit actually is.
    func setMapControlsHidden(_ hidden: Bool) {
        if let glassControls {
            glassControls.isHidden = hidden
        } else {
            trippleButton.isHidden = hidden
            settingsButton.isHidden = hidden
            layerSwitcherButton.isHidden = hidden
            positionButton.isHidden = hidden
        }
    }

    /// The logo, hidden as one unit with the glass disc it sits on — hiding
    /// only the mark would leave an empty puck floating over the map.
    func setLogoHidden(_ hidden: Bool) {
        logo.isHidden = hidden
        glassLogo?.isHidden = hidden
    }

}
