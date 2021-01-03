import UIKit
import UIKit.UIGestureRecognizer
import WebKit
import CoreLocation
import OnboardKit

var viewController: ViewController? = nil

@available(iOS 13.0, *)
class ViewController: UIViewController, WKUIDelegate, WKScriptMessageHandler, LocationObserver, UIScrollViewDelegate{
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
    
    var onboardingOnThisRun = false
    
    var focusOn = false
    var zoomOn = false
    
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
        webView.evaluateJavaScript("window.lm.updateLocation(\(location.coordinate.latitude), \(location.coordinate.longitude), \(location.horizontalAccuracy), \(zoomOn) ,\(focusOn));")
        print(("window.lm.updateLocation(\(location.coordinate.latitude), \(location.coordinate.longitude), \(location.horizontalAccuracy), \(zoomOn) ,\(focusOn));"))
        if (zoomOn){
            zoomOn = !zoomOn
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
        
        if action == "startMonitoringLocationExplicit" {
            SharedLocationUpdater.requestLocation(observer: self, explicit: true)
            SharedLocationUpdater.startAccurateLocationUpdates()
        }
        
        if action == "startMonitoringLocationImplicit" {
            SharedLocationUpdater.requestLocation(observer: self, explicit: false)
            SharedLocationUpdater.startAccurateLocationUpdates()
        }
        
        if action == "stopMonitoringLocation" {
            SharedLocationUpdater.stopAccurateLocationUpdates()
        }
        
        if action == "forecastDownloaded" {
            time.text = formatter.string(from: Date())
            drawer_open_finish()
        }
        
        if action == "forecastInvalid" {
            drawer_close()
        }
        
        if action == "enableScrolling" {
            webView.scrollView.isScrollEnabled = true
            webView.scrollView.bounces = true
        }
        
        if action == "disableScrolling" {
            webView.scrollView.isScrollEnabled = false
            webView.scrollView.bounces = false
        }
        
        if action == "drawerHide" {
            drawer_hide()
        }
        
        if action == "drawerShow" {
            drawer_show()
        }
        
        if action == "requestSettings" {
            injectSettings()
            
            if (userDefaults?.bool(forKey: "autoZoom") ?? false && userDefaults?.bool(forKey: "onboardingDone") ?? false){
                zoomOn = (userDefaults?.bool(forKey: "autoZoom"))!
                focusOn = (userDefaults?.bool(forKey: "autoZoom"))!
                zoomAndFocusLocation()
            }
        }
        
        if action == "layerSwitcherClosed" {
            trippleButton.isHidden = false
            settingsButton.isHidden = false
            layerSwitcherButton.isHidden = false
            positionButton.isHidden = false
        }
        
        if action == "mapMoveEnd"{
            SharedLocationUpdater.stopAccurateLocationUpdates()
            positionButton.setImage(UIImage(systemName: "location",withConfiguration: UIImage.SymbolConfiguration(scale: .large)),for: .normal)
        }
    }
    
    override func loadView() {
        super.loadView()
        viewController = self
        
        webView?.configuration.userContentController.add(self, name: "scriptHandler")
        webView?.configuration.userContentController.add(self, name: "timeHandler")
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        
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
        self.view.addSubview(blur!)
        self.view.addSubview(logo!)
        
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
        SharedLocationUpdater.addObserver(observer: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        let locationAction = {
            completion in
            SharedLocationUpdater.requestAuthorization(completion, notDetermined: true)
        }
        
        if let onboardingDone = userDefaults?.bool(forKey: "onboardingDone"), !onboardingDone {
            let ob = obFactory.getOnboarding(pages: obFactory.getInitialOnboardingPages(notificationAction: {
                [weak self] completion in
                self?.userDefaults?.setValue(true, forKey: "pushNotification")
                self?.userDefaults?.setValue(true, forKey: "onboardingDone")
                self?.onboardingOnThisRun = true
                SharedNotificationManager.registerForPushNotifications(completion)
            }), completion: {
                var secondStageOb: OnboardViewController
                if let pushNotifications = self.userDefaults?.bool(forKey: "pushNotification"), pushNotifications {
                    secondStageOb = obFactory.getOnboarding(pages: obFactory.getBackgroundLocationOnboarding(locationAction: locationAction))!
                } else {
                    secondStageOb = obFactory.getOnboarding(pages: obFactory.getWhileUsingOnboarding(locationAction: locationAction))!
                }
                secondStageOb.presentFrom(self, animated: true)
            })
            ob!.presentFrom(self, animated: true)
        } else {
            if (!self.onboardingOnThisRun && CLLocationManager.authorizationStatus() == .notDetermined) {
                obFactory.getOnboarding(pages: obFactory.getLocationNagOnboarding(locationAction: locationAction))?.presentFrom(self, animated: true)
                userDefaults?.setValue(true, forKey: "nagDone")
            }
        }
    }
    
    @objc func willEnterForeground() {
        // reload tiles if app resumes from background
        //webView.evaluateJavaScript("window.ios.refresh();")
        if ((userDefaults?.bool(forKey: "autoZoom"))!){
            zoomOn = (userDefaults?.bool(forKey: "autoZoom"))!
            focusOn = (userDefaults?.bool(forKey: "autoZoom"))!
            zoomAndFocusLocation()
        }
    }
    
    @IBAction func locationButton(sender: AnyObject){
        if (focusOn == false){
            focusOn = true
            zoomOn = true
            zoomAndFocusLocation()
        } else{
            positionButton.setImage(UIImage(systemName: "location",withConfiguration: UIImage.SymbolConfiguration(scale: .large)),for: .normal)
            focusOn = false
        }
    }
    
    @IBAction func layerSwitcher(sender: AnyObject){
        webView.evaluateJavaScript("window.openLayerswitcher();")
        trippleButton.isHidden = true
        settingsButton.isHidden = true
        layerSwitcherButton.isHidden = true
        positionButton.isHidden = true
    }
    
    private func zoomAndFocusLocation(){
        SharedLocationUpdater.requestLocation(observer: self, explicit: true)
        SharedLocationUpdater.startAccurateLocationUpdates()
        positionButton.setImage(UIImage(systemName: "location.fill",withConfiguration: UIImage.SymbolConfiguration(scale: .large)),for: .normal)
    }
}
