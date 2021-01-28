import UIKit
import UIKit.UIGestureRecognizer
import WebKit
import CoreLocation
import OnboardKit

var viewController: ViewController? = nil

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
    var appIsAlreadyRunning = false

    enum DrawerStates {
        case CLOSED
        case LOADING
        case OPEN
    }
    
    var drawerState = DrawerStates.CLOSED
    var originalButtonPosition: CGRect!
    
    var currentdate = Date()
    let formatter = DateFormatter()
    let userDefaults = UserDefaults.init(suiteName: "group.org.frcy.app.meteocool")

    enum LocationState {
        case off
        case active
        case tracking
    }
    
    ///Represents all the triggers a Turnstile can perform
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
        //print("action")
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
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        
        //let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(self.tapOrPan))
        let panRecognizer = UIPanGestureRecognizer(target: self, action: #selector(self.tapOrPan))

        //tapRecognizer.numberOfTapsRequired = 1
        //tapRecognizer.delegate = self
        //view.addGestureRecognizer(tapRecognizer)
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

        time.isHidden = true
        time.layer.masksToBounds = true
        time.layer.cornerRadius = 8.0
        slider_ring.isHidden = true
        slider_button.isHidden = true

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
                self.zoomOnce = true // gets reset to false automatically after the zoom operation
                SharedLocationUpdater.requestLocation(observer: self, explicit: true)
                self.positionButton.setImage(UIImage(systemName: "location.fill",withConfiguration: UIImage.SymbolConfiguration(scale: .large)),for: .normal)
            case .tracking:
                self.autoFocus = true // gets reset to false automatically after the zoom operation
                SharedLocationUpdater.requestLocation(observer: self, explicit: true)
                self.positionButton.setImage(UIImage(systemName: "location.fill.viewfinder",withConfiguration: UIImage.SymbolConfiguration(scale: .large)),for: .normal)
            }
        }

        // disable scrolling & bouncing effects
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.delegate = self

        if let url = URL(string: "https://app.ng.meteocool.com/ios.html"/*"http://127.0.0.1:8080/ios.html"*/) {
            let request = URLRequest(url: url)
            webView.load(request)
        }
        
        NotificationCenter.default.addObserver(self, selector: #selector(ViewController.willEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(ViewController.injectSettings),
                                               name: NSNotification.Name("SettingsChanged"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(ViewController.didBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        SharedLocationUpdater.addObserver(observer: self)
        self.willEnterForeground()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

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
        
        var negDone = false;
        
        if (userDefaults?.bool(forKey: "onboardingDone") == true && (self.userDefaults?.integer(forKey: "versionNumber") == nil || (self.userDefaults?.integer(forKey: "versionNumber"))! < 21)){
            switch(CLLocationManager.authorizationStatus()) {
            case .denied:
                break;
            case .authorizedWhenInUse, .notDetermined:
                negDone = true
                break;
            case .authorizedAlways:
                self.userDefaults?.setValue(true, forKey: "pushNotification")
                break;
            default:
                break;
            }
            
            let updateOnboarding = obFactory.getOnboarding(pages: obFactory.getUpdateOnboarding(),completion: {
                                                            if negDone{self.userDefaults?.setValue(false, forKey: "nagDone")}
            })!
            
            updateOnboarding.presentFrom(self, animated: true)
            
            self.userDefaults?.setValue(21, forKey: "versionNumber")
        }
        
        if let onboardingDone = userDefaults?.bool(forKey: "onboardingDone"), !onboardingDone {
            let ob = obFactory.getOnboarding(pages: obFactory.getInitialOnboardingPages(notificationAction: notificationAction), completion: {
                // Completion handler for first top-level onboarding
                self.userDefaults?.setValue(true, forKey: "onboardingDone")
                
                var secondStageOb: OnboardViewController
                if let pushNotifications = self.userDefaults?.bool(forKey: "pushNotification"), pushNotifications {
                    secondStageOb = obFactory.getOnboarding(pages: obFactory.getBackgroundLocationOnboarding(locationAction: locationAction))!
                } else {
                    secondStageOb = obFactory.getOnboarding(pages: obFactory.getWhileUsingOnboarding(locationAction: locationAction))!
                }
                secondStageOb.presentFrom(self, animated: true)
            })
            ob!.presentFrom(self, animated: true)
            self.userDefaults?.setValue(21, forKey: "versionNumber")
        } else {
            if let nagDone = self.userDefaults?.bool(forKey: "nagDone"),
                    ((CLLocationManager.authorizationStatus() == .notDetermined ||
                    CLLocationManager.authorizationStatus() == .authorizedWhenInUse) && !nagDone) {
                obFactory.getOnboarding(pages: obFactory.getLocationNagOnboarding(notificationAction: notificationAction), completion: {
                    self.userDefaults?.setValue(true, forKey: "nagDone")
                    if let pushNotifications = self.userDefaults?.bool(forKey: "pushNotification"), pushNotifications {
                        obFactory.getOnboarding(pages: obFactory.getBackgroundLocationOnboarding(locationAction: locationAction))!.presentFrom(self, animated: true)
                    }
                })?.presentFrom(self, animated: true)
            }
        }
    }

    var alertWindow: UIWindow?

    @objc func willEnterForeground() {
        if ((userDefaults?.bool(forKey: "autoZoom")) ?? false){
            if (locationStateMachine?.state == .off) {
                locationStateMachine?.trigger(.buttonPress)
            }
            if (locationStateMachine?.state == .active) {
                locationStateMachine?.trigger(.buttonPress)
            }
        }

        if (userDefaults?.bool(forKey: "pushNotification") ?? false && CLLocationManager.authorizationStatus() != .authorizedAlways) {
            // Check if background location permissions were revoked while notifications enabled
            let alertController = UIAlertController(title: NSLocalizedString("Notifications Not Working",comment: "Alerts"), message: NSLocalizedString("In order to check your current location for upcoming rain while you're not using the app, background location access is required.\n\nIf you want to continue receiving notifications, go to Settings > Privacy > Location > meteocool and change \"Location\" to \"Always\".",comment: "Alerts"), preferredStyle: UIAlertController.Style.alert)
            alertController.addAction(UIAlertAction(title: NSLocalizedString("Change in Settings",comment: "Alerts"), style: UIAlertAction.Style.default, handler: {_ in
                if let url = NSURL(string: UIApplication.openSettingsURLString) as URL? {
                    UIApplication.shared.open(url, options: [:], completionHandler: {_ in
                        self.userDefaults?.setValue(true, forKey: "pushNotification")
                        self.alertWindow = nil
                    })
                }
            }
            ))
            alertController.addAction(UIAlertAction(title: NSLocalizedString("Disable Notifications",comment: "Alerts"), style: UIAlertAction.Style.default, handler: {_ in
                self.userDefaults?.setValue(false, forKey: "pushNotification")
                NotificationCenter.default.post(name: NSNotification.Name("SettingsChanged"), object: nil)
                self.alertWindow = nil
                
                guard let request = NetworkHelper.createJSONPostRequest(dst: "unregister", dictionary: ["token": SharedNotificationManager.getToken() ?? "anon"] as [String: Any]) else{
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

                let reenableController = UIAlertController(title: NSLocalizedString("Notifications Disabled",comment: "Alerts"), message: NSLocalizedString("If you change your mind, you can re-enable rain and snow notifications in the app's ⚙️ Settings on the top-right.",comment: "Alerts"), preferredStyle: UIAlertController.Style.alert)
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
        if appIsAlreadyRunning{
            self.webView.evaluateJavaScript("window.enterForeground();")
        }
        else{
            appIsAlreadyRunning = true
        }
    }

    @IBAction func locationButton(sender: AnyObject){
        locationStateMachine?.trigger(.buttonPress)
    }
    
    @IBAction func layerSwitcher(sender: AnyObject){
        trippleButton.isHidden = true
        settingsButton.isHidden = true
        layerSwitcherButton.isHidden = true
        positionButton.isHidden = true
        logo.isHidden = true
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
            time.isHidden = false
            button.alpha = 1
            button.frame = CGRect(x: button.frame.origin.x-(button.frame.width/2), y: button.frame.origin.y, width: button.frame.width*2, height: button.frame.height)
            button.setImage(UIImage(named: "Slider_Handle_open"), for: [])
            activityIndicator.stopAnimating()
            drawerState = .OPEN
            // XXX workaround until we tie the play button to the wheel
            webView.evaluateJavaScript("window.hidePlayButton();")
            button.isEnabled = true
        }
    }
    
    func drawer_close() {
        time.isHidden = true
        slider_ring.isHidden = true
        slider_button.isHidden = true
        button.alpha = 1.0
        
        if (drawerState == .OPEN) {
            button.setImage(UIImage(named: "Slider_Handle"), for: [])
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
        print(jsCommand)
        if (zoomOnce){
            zoomOnce = false
        }
        if (autoFocusOnce){
            autoFocusOnce = false
        }
    }

    @objc func injectSettings() {
        let config = [
            "mapRotation": userDefaults?.value(forKey: "mapRotation"),
            "radarColorMapping": userDefaults?.value(forKey: "radarColorMapping"),
            "mapBaseLayer": userDefaults?.value(forKey: "baseLayer"),
        ]
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: config, options: .withoutEscapingSlashes)
            let jsonText = String(data: jsonData, encoding: .utf8) ?? "{}"
            let command = "window.settings.injectSettings(\(jsonText));"
            webView.evaluateJavaScript(command)
            print(command)
        } catch {
            print("Config parsing failed")
        }
    }

    /* called from javascript */
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let action = String(describing: message.body)

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
        
        if action == "requestSettings" {
            injectSettings()
            
            if (locationStateMachine?.state == .off) {
                if (userDefaults?.bool(forKey: "autoZoom") ?? false && userDefaults?.bool(forKey: "onboardingDone") ?? false){
                    locationStateMachine?.trigger(.buttonPress)
                }
            }
        }
        
        if action == "layerSwitcherClosed" {
            trippleButton.isHidden = false
            settingsButton.isHidden = false
            layerSwitcherButton.isHidden = false
            positionButton.isHidden = false
            logo.isHidden = false
        }
    }
}
