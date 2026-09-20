import UIKit
import UIKit.UIGestureRecognizer
import WebKit
import CoreLocation
import OnboardKit

@MainActor var viewController: ViewController? = nil

@available(iOS 13.0, *)
class ViewController: UIViewController, WKUIDelegate, WKScriptMessageHandler, LocationObserver, UIScrollViewDelegate, UIGestureRecognizerDelegate{
    let buttonsize = 19.0 as CGFloat
    
    @IBOutlet weak var webView: WKWebView!
    @IBOutlet weak var slider_ring: UIImageView!
    @IBOutlet weak var slider_button: UIImageView!
    @IBOutlet weak var button: UIButton!
    @IBOutlet weak var settingsButton: UIButton!
    @IBOutlet weak var time: UILabel!
    @IBOutlet weak var activityIndicator: UIActivityIndicatorView!
    @IBOutlet weak var trippleButton: UIImageView!
    @IBOutlet weak var positionButton: UIButton!
    @IBOutlet weak var layerSwitcherButton: UIButton!
    @IBOutlet weak var blur: UIVisualEffectView!
    @IBOutlet weak var logo: UIImageView!
        
    var autoFocus = false
    var autoFocusOnce = false
    var zoomOnce = false
    var webviewReady = false

    enum DrawerStates {
        case CLOSED
        case LOADING
        case OPEN
    }
    
    var drawerState = DrawerStates.CLOSED

    /// Glass chrome that supersedes the flat blur and the `TribbleButton`
    /// artwork on iOS 26. Nil on older systems, which keep the shipped look.
    private var glassControls: UIVisualEffectView?
    private var glassForecastTime: UIVisualEffectView?
    private var glassLogo: UIVisualEffectView?
    var originalButtonPosition: CGRect!
    var prolongSplashScreen = true
    
    var currentdate = Date()
    let formatter = DateFormatter()
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
        webView?.configuration.userContentController.add(self, name: "timeHandler")
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
        self.view.addSubview(slider_ring!)
        self.view.addSubview(slider_button!)
        self.view.addSubview(button!)
        self.view.addSubview(time!)
        self.view.addSubview(activityIndicator!)
        self.view.addSubview(trippleButton!)
        self.view.addSubview(settingsButton!)
        self.view.addSubview(positionButton!)
        self.view.addSubview(layerSwitcherButton!)
        self.view.addSubview(logo!)
        self.view.addSubview(blur!)

        if #available(iOS 26.0, *) {
            applyLiquidGlass()
        }

        time.layer.masksToBounds = true
        time.layer.cornerRadius = 8.0
        setForecastTimeHidden(true)
        slider_ring.isHidden = true
        slider_button.isHidden = true

        setMapControlsHidden(true)
        
        formatter.locale = Locale(identifier: "de_De")
        formatter.dateFormat = "H:mm"

        let gesture = CustomGestureRecognizer(target: self, action: nil)
        gesture.setView(viewing: self)
        view.addGestureRecognizer(gesture)
        drawer_hide()

        print("Language: " + Locale.preferredLanguages[0].split(separator: "-")[0])
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
        let environment = MeteocoolEnvironment.current
        NSLog("Loading \(environment) frontend: \(environment.webURL)")
        webView.load(URLRequest(url: environment.webURL))

        NotificationCenter.default.addObserver(self, selector: #selector(ViewController.willEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(ViewController.willResignActive), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(ViewController.injectSettings),
                                               name: NSNotification.Name("SettingsChanged"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(ViewController.didBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
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

        let locationAction = {
            completion in
            SharedLocationUpdater.requestAuthorization(completion, notDetermined: true)
        }

        let notificationAction: OnboardPageAction
        notificationAction = {
            [weak self] completion in
            self?.userDefaults?.setValue(true, forKey: "pushNotification")
            SharedNotificationManager.registerForPushNotifications(completion)
        }

        var nagDone = false

        if (userDefaults?.bool(forKey: "onboardingDone") == true && (self.userDefaults?.integer(forKey: "versionNumber") == nil || (self.userDefaults?.integer(forKey: "versionNumber"))! < 21)){
            switch(CLLocationManager.authorizationStatus()) {
            case .denied:
                break;
            case .authorizedWhenInUse, .notDetermined:
                nagDone = true
                break;
            case .authorizedAlways:
                self.userDefaults?.setValue(true, forKey: "pushNotification")
                break;
            default:
                break;
            }
            
            let updateOnboarding = obFactory.getOnboarding(pages: obFactory.getUpdateOnboarding(),completion: {
                                                            if nagDone{self.userDefaults?.setValue(false, forKey: "nagDone")}
            })!
            
            updateOnboarding.presentFrom(self, animated: true)
            prolongSplashScreen = false

            self.userDefaults?.setValue(21, forKey: "versionNumber")
        }
        
        if let onboardingDone = userDefaults?.bool(forKey: "onboardingDone"), !onboardingDone {
            let ob = obFactory.getOnboarding(pages: obFactory.getInitialOnboardingPages(notificationAction: notificationAction), completion: {
                // Completion handler for first top-level onboarding
                self.userDefaults?.setValue(true, forKey: "onboardingDone")
                
                var secondStageOb: OnboardViewController
                if let pushNotifications = self.userDefaults?.bool(forKey: "pushNotification"), pushNotifications {
                    self.userDefaults?.setValue(true, forKey: "nagDone")
                    secondStageOb = obFactory.getOnboarding(pages: obFactory.getBackgroundLocationOnboarding(locationAction: locationAction))!
                } else {
                    secondStageOb = obFactory.getOnboarding(pages: obFactory.getWhileUsingOnboarding(locationAction: locationAction))!
                }
                secondStageOb.presentFrom(self, animated: true)
            })
            ob!.presentFrom(self, animated: true)
            prolongSplashScreen = false
            self.userDefaults?.setValue(21, forKey: "versionNumber")
        } else {
            if let nagDone = self.userDefaults?.bool(forKey: "nagDone"),
                    ((CLLocationManager.authorizationStatus() == .notDetermined ||
                    CLLocationManager.authorizationStatus() == .authorizedWhenInUse) && !nagDone) {
                obFactory.getOnboarding(pages: obFactory.getLocationNagOnboarding(notificationAction: notificationAction), completion: {
                    self.userDefaults?.setValue(true, forKey: "nagDone")
                    if let pushNotifications = self.userDefaults?.bool(forKey: "pushNotification"), pushNotifications {
                        obFactory.getOnboarding(pages: obFactory.getBackgroundLocationOnboarding(locationAction: locationAction, includeFeatureReview: false))!.presentFrom(self, animated: true)
                    }
                })?.presentFrom(self, animated: true)
                prolongSplashScreen = false
            }
        }

        if (!webviewReady && prolongSplashScreen) {
            performSegue(withIdentifier: "ShowLaunchScreen", sender: nil)
        }
    }

    func hideSplash() {
        if (!prolongSplashScreen) {
            return
        }

        let keyWindow = UIApplication.shared.windows.filter {$0.isKeyWindow}.first

        if var topController = keyWindow?.rootViewController {
            while let presentedViewController = topController.presentedViewController {
                topController = presentedViewController
            }

            topController.dismiss(animated: true)
        }
    }

    var alertWindow: UIWindow?

    @objc func willResignActive() {
        if webviewReady {
            self.webView.evaluateJavaScript("window.leaveForeground();")
        }
    }

    @objc func willEnterForeground() {
        if (webviewReady) {
            if (locationStateMachine?.state != .off) {
                SharedLocationUpdater.requestLocation(observer: self, explicit: true)
                SharedLocationUpdater.startAccurateLocationUpdates()
            }
            if ((userDefaults?.bool(forKey: "autoZoom")) ?? false) {
                // XXX deduplicate with code in userContentController
                if (locationStateMachine?.state == .off) {
                    self.zoomOnce = true
                    locationStateMachine?.trigger(.buttonPress)
                }
                if (locationStateMachine?.state == .active) {
                    // XXX this is kind of a hack to re-focus the location upon resume by cycling
                    // through the FSM.
                    locationStateMachine?.trigger(.buttonPress) // track
                    locationStateMachine?.trigger(.buttonPress) // off
                    self.zoomOnce = true
                    locationStateMachine?.trigger(.buttonPress) // active with updated location
                }
            }
        }

        if (userDefaults?.bool(forKey: "pushNotification") ?? false && CLLocationManager.authorizationStatus() != .authorizedAlways) {
            // Check if background location permissions were revoked while notifications enabled
            let alertController = UIAlertController(title: NSLocalizedString("notifications_not_working",comment: "Alerts"), message: NSLocalizedString("enable_background_location_alert",comment: "Alerts"), preferredStyle: UIAlertController.Style.alert)
            alertController.addAction(UIAlertAction(title: NSLocalizedString("Change in Settings",comment: "Alerts"), style: UIAlertAction.Style.default, handler: {_ in
                if let url = NSURL(string: UIApplication.openSettingsURLString) as URL? {
                    UIApplication.shared.open(url, options: [:], completionHandler: {_ in
                        self.userDefaults?.setValue(true, forKey: "pushNotification")
                        self.alertWindow = nil
                    })
                }
            }
            ))
            alertController.addAction(UIAlertAction(title: NSLocalizedString("disable_notifications",comment: "Alerts"), style: UIAlertAction.Style.default, handler: {_ in
                self.userDefaults?.setValue(false, forKey: "pushNotification")
                NotificationCenter.default.post(name: NSNotification.Name("SettingsChanged"), object: nil)
                self.alertWindow = nil
                
                if let token = SharedNotificationManager.getToken()  {
                    guard let request = NetworkHelper.createJSONPostRequest(dst: "unregister", dictionary: ["token": token] as [String: Any]) else{
                        return
                    }
                    URLSession.shared.dataTask(with: request) { data, response, error in
                        guard let data = NetworkHelper.checkResponse(data: data, response: response, error: error) else {
                            return
                        }

                        if let json = ((try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]) as [String : Any]??) {
                            if let errorMessage = json?["error"] as? String {
                                NSLog("ERROR: \(errorMessage)")
                            }
                        }
                    }
                }

                let reenableController = UIAlertController(title: NSLocalizedString("notifications_disabled",comment: "Alerts"), message: NSLocalizedString("notifications_disabled_text",comment: "Alerts"), preferredStyle: UIAlertController.Style.alert)
                reenableController.addAction(UIAlertAction(title: NSLocalizedString("Dismiss",comment: "Alerts"), style: UIAlertAction.Style.default, handler: {_ in
                    self.alertWindow = nil
                }))
                self.alertWindow = UIWindow(frame: UIScreen.main.bounds)
                self.alertWindow?.rootViewController = UIViewController()
                self.alertWindow?.windowLevel = UIWindow.Level.alert + 1;
                self.alertWindow?.makeKeyAndVisible()
                self.alertWindow?.rootViewController?.present(reenableController, animated: true)
            }
            ))
            alertWindow = UIWindow(frame: UIScreen.main.bounds)
            alertWindow?.rootViewController = UIViewController()
            alertWindow?.windowLevel = UIWindow.Level.alert + 1;
            alertWindow?.makeKeyAndVisible()
            alertWindow?.rootViewController?.present(alertController, animated: true)
        }
    }
    
    @objc func didBecomeActive(){
        if webviewReady {
            self.webView.evaluateJavaScript("window.enterForeground();")
        }
    }

    @IBAction func locationButton(sender: AnyObject){
        locationStateMachine?.trigger(.buttonPress)
    }
    
    @IBAction func layerSwitcher(sender: AnyObject){
        setMapControlsHidden(true)
        setLogoHidden(true)
        webView.evaluateJavaScript("window.openLayerswitcher();")
    }
    
    func drawer_show() {
        button.isHidden = false
    }
    
    func drawer_hide() {
        button.isHidden = true
    }
    
    func drawer_open() {
        if (drawerState == .CLOSED) {
            activityIndicator.startAnimating()
            button.alpha = 0.5
            move_slider_button(pointToMove: CGPoint.init(x: UIScreen.main.bounds.width, y: UIScreen.main.bounds.height-300-100+33))
            drawerState = .LOADING
            button.isEnabled = false
        }
        if (originalButtonPosition == nil) {
            originalButtonPosition = button.frame
        }
    }
    
    func drawer_open_finish() {
        if (drawerState == .LOADING) {
            slider_button.isHidden = false
            slider_ring.isHidden = false
            setForecastTimeHidden(false)
            button.alpha = 1
            button.frame = CGRect(x: button.frame.origin.x-(button.frame.width/2), y: button.frame.origin.y, width: button.frame.width*2, height: button.frame.height)
            setDrawerHandle(open: true)
            activityIndicator.stopAnimating()
            drawerState = .OPEN
            // XXX workaround until we tie the play button to the wheel
            webView.evaluateJavaScript("window.hidePlayButton();")
            button.isEnabled = true
        }
    }
    
    func drawer_close() {
        setForecastTimeHidden(true)
        slider_ring.isHidden = true
        slider_button.isHidden = true
        button.alpha = 1.0
        
        if (drawerState == .OPEN) {
            setDrawerHandle(open: false)
            button.frame = originalButtonPosition
        }
        activityIndicator.stopAnimating()
        drawerState = .CLOSED
        // XXX workaround until we tie the play button to the wheel
        webView.evaluateJavaScript("window.showPlayButton();")
    }
    
    @IBAction func slider_show_button(sender: AnyObject) {
        if (drawerState == .OPEN) {
            // hide drawer
            webView.evaluateJavaScript("window.resetLayers();")
            drawer_close()
        } else if (drawerState == .CLOSED) {
            // show drawer (in loading mode)
            drawer_open()
            
            let webkitFunction = """
window.downloadForecast(function() {
    window.forecastDownloaded = true;
    window.webkit.messageHandlers["scriptHandler"].postMessage("forecastDownloaded");
});
"""
            webView.evaluateJavaScript(webkitFunction)
        }
    }
    
    func move_slider_button(pointToMove: CGPoint) {
        let x_coordiante = (pointToMove.x)-(buttonsize/2)
        let y_coordinate = (pointToMove.y)-(buttonsize/2)
        
        slider_button.frame.origin = CGPoint(x: x_coordiante, y: y_coordinate)
    }
    
    func notify(location: CLLocation) {
        let jsCommand = "window.lm.updateLocation(\(location.coordinate.latitude), \(location.coordinate.longitude), \(location.horizontalAccuracy), \(zoomOnce), \(autoFocus || autoFocusOnce));"
        webView.evaluateJavaScript(jsCommand)
        // Same fix, in the shape the Geolocation API asks for: this is what
        // resolves a page-side getCurrentPosition and keeps watchers running.
        GeolocationBridge.deliver(location, to: webView)
        print(jsCommand)
        if (zoomOnce){
            zoomOnce = false
        }
        if (autoFocusOnce){
            autoFocusOnce = false
        }
    }

    @objc func injectSettings() {
        guard let command = WebSettings.injectionJS() else {
            print("Config parsing failed")
            return
        }
        webView.evaluateJavaScript(command)
        print(command)
    }


    /* called from javascript */
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let action = String(describing: message.body)

        if message.name == GeolocationBridge.handlerName {
            if action == GeolocationBridge.requestAction {
                serveGeolocationRequest()
            }
            return
        }

        // XXX convert to switch/case
        if message.name == "timeHandler" {
            self.currentdate = NSDate(timeIntervalSince1970: Double(action)!) as Date
        }

        if action == "forecastDownloaded" {
            time.text = formatter.string(from: Date())
            drawer_open_finish()
        }

        if action == "forecastInvalid" {
            drawer_close()
        }

        if action == "drawerHide" {
            drawer_hide()
        }

        if action == "drawerShow" {
            drawer_show()
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
            webviewReady = true
            injectSettings()

            if (userDefaults?.bool(forKey: "onboardingDone") ?? false) {
                if (locationStateMachine?.state == .off && (CLLocationManager.authorizationStatus() == .authorizedWhenInUse || CLLocationManager.authorizationStatus() == .authorizedAlways)) {
                    if ((userDefaults?.bool(forKey: "autoZoom")) ?? false) {
                        self.zoomOnce = true
                    }
                    locationStateMachine?.trigger(.buttonPress)
                }
            }

            setMapControlsHidden(false)
            hideSplash()
        }
        
        if action == "layerSwitcherClosed" {
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
        switch CLLocationManager.authorizationStatus() {
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
                switch CLLocationManager.authorizationStatus() {
                case .authorizedWhenInUse, .authorizedAlways:
                    self.serveGeolocationRequest()
                default:
                    GeolocationBridge.fail(.permissionDenied, message: "Location access was not granted", to: self.webView)
                }
            }, notDetermined: true)
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
        installGlassForecastTime()
        installGlassLogo()

        // The forecast drawer handle becomes a glass tab instead of a bitmap.
        var handle = UIButton.Configuration.glass()
        handle.cornerStyle = .capsule
        button.configuration = handle
        setDrawerHandle(open: false)
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
            control.removeFromSuperview()
            control.translatesAutoresizingMaskIntoConstraints = false
            control.tintColor = .label

            let glass = LiquidGlass.element()
            glass.contentView.addSubview(control)
            NSLayoutConstraint.activate([
                glass.widthAnchor.constraint(equalToConstant: 52),
                glass.heightAnchor.constraint(equalToConstant: 52),
                control.centerXAnchor.constraint(equalTo: glass.contentView.centerXAnchor),
                control.centerYAnchor.constraint(equalTo: glass.contentView.centerYAnchor),
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

    /// Puts the forecast timestamp on a glass pill instead of the hardcoded
    /// blue rectangle, which never had a dark mode.
    @available(iOS 26.0, *)
    private func installGlassForecastTime() {
        time.backgroundColor = .clear
        time.textColor = .label

        let glass = LiquidGlass.element(interactive: false)
        view.insertSubview(glass, belowSubview: time)
        glassForecastTime = glass

        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: time.leadingAnchor, constant: -16),
            glass.trailingAnchor.constraint(equalTo: time.trailingAnchor, constant: 16),
            glass.topAnchor.constraint(equalTo: time.topAnchor, constant: -9),
            glass.bottomAnchor.constraint(equalTo: time.bottomAnchor, constant: 9),
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

    func setForecastTimeHidden(_ hidden: Bool) {
        time.isHidden = hidden
        glassForecastTime?.isHidden = hidden
    }

    /// The logo, hidden as one unit with the glass disc it sits on — hiding
    /// only the mark would leave an empty puck floating over the map.
    func setLogoHidden(_ hidden: Bool) {
        logo.isHidden = hidden
        glassLogo?.isHidden = hidden
    }

    func setDrawerHandle(open: Bool) {
        if button.configuration != nil {
            button.configuration?.image = UIImage(systemName: open ? "chevron.compact.right" : "chevron.compact.left")
        } else {
            button.setImage(UIImage(named: open ? "Slider_Handle_open" : "Slider_Handle"), for: [])
        }
    }
}
