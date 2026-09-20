import UIKit
import CoreLocation

@MainActor protocol LocationObserver {
    func notify(location: CLLocation)
}

@MainActor let SharedLocationUpdater = LocationUpdater.init()

// XXX is there a way to make this class not instanciable? it should be a singleton (FUCKING JAVA BROKE ME)
// CLLocationManager delivers its delegate callbacks on the queue the manager was
// created on — always main here — so the @preconcurrency conformance is sound.
@MainActor class LocationUpdater: NSObject, @preconcurrency CLLocationManagerDelegate {
    /// location manager instace we're wrapping
    private let locationManager: CLLocationManager = CLLocationManager()
    /// device identifier (currently unused...)
    private let deviceID: String = UIDevice.current.identifierForVendor!.uuidString
    /// pressure manager object
    private let pressure: PressureManager = PressureManager()
    /// Location observers (only notified if app is active and a new location update becomes available)
    private var observers = [LocationObserver]()

    // accurate location updates are/were enabled before suspend
    private var accurateLocationUpdatesEnabled: Bool = false

    /// Set while the car screen is up (`CarPlaySceneDelegate`).
    ///
    /// The phone leaving the foreground is normally the cue to fall back to
    /// significant-change updates, which move the map about once a kilometre.
    /// With CarPlay connected the phone is in a pocket and the dashboard is
    /// the screen being watched, so the accurate updates have to survive it.
    var carPlayConnected: Bool = false

    // the last location reported to the backend
    private var lastPostedLocation: CLLocation?
    // the last received location (might not have been reported to the backend)
    private var lastReceivedLocation: CLLocation?

    /// default accuracy for monitoring significant location changes
    private let backgroundAccuracy = kCLLocationAccuracyKilometer

    /// populated with the completion handler from the onboarding thing
    var authCompletionHandler: ((Bool, Error?) -> Void)?

    /// constructor
    override init() {
        super.init()
        locationManager.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(LocationUpdater.willEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(LocationUpdater.willResignActive), name: UIApplication.willResignActiveNotification, object: nil)
        printAuthorizationStatus()
    }

    func printAuthorizationStatus() {
        if CLLocationManager.locationServicesEnabled() {
            switch CLLocationManager.authorizationStatus() {
            case .notDetermined, .restricted, .denied:
                NSLog("Location: No access")
            case .authorizedWhenInUse:
                NSLog("Location: WhenInUse")
            case .authorizedAlways:
                NSLog("Location: Always")
                startSignificantChangeLocationUpdates()
            @unknown default:
                NSLog("Location: unknown case")
            }
        } else {
            NSLog("Location services are not enabled")
        }
    }

    func requestAuthorization(_ completion: @escaping (_ success: Bool, _ error: Error?) -> Void, notDetermined: Bool) {
        authCompletionHandler = completion
        if let enabled = userDefaults?.bool(forKey: "pushNotification"), enabled {
            locationManager.requestAlwaysAuthorization()
        } else {
            locationManager.requestWhenInUseAuthorization()
        }
        if (!notDetermined) {
            // XXX this crap needs to go into the completion handler by the ONLY caller that ever sets this awfully named
            // second parameter to false. WTF WAS I THINKING
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(1), execute: {
                print("completing lost completion handler")
                if let authCompletionHandler = self.authCompletionHandler {
                    authCompletionHandler(true, nil)
                }
                self.authCompletionHandler = nil
            })
        }
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        if let authCompletionHandler = authCompletionHandler {
            switch status {
            case .notDetermined:
                if let enabled = userDefaults?.bool(forKey: "pushNotification"), enabled {
                    locationManager.requestAlwaysAuthorization()
                } else {
                    locationManager.requestWhenInUseAuthorization()
                }
                break
            case .authorizedWhenInUse:
                locationManager.startUpdatingLocation()
                break
            case .authorizedAlways:
                locationManager.startUpdatingLocation()
                SharedNotificationManager.registerForPushNotifications({(_,_) in })
                break
            case .restricted:
                break
            case .denied:
                break
            default:
                break
            }
            authCompletionHandler(true, nil)
        }
        authCompletionHandler = nil
    }

    // =============== Observer pattern ===========
    func addObserver(observer: LocationObserver) {
        observers.append(observer)
    }
    
    let userDefaults = UserDefaults.init(suiteName: "group.org.frcy.app.meteocool")

    // executed when the user taps the locate-me button
    func requestLocation(observer: LocationObserver, explicit: Bool) {
        if (explicit) {
            if (CLLocationManager.authorizationStatus() == .notDetermined) {
                requestAuthorization({(_,_) in
                    if CLLocationManager.authorizationStatus() == .authorizedAlways || CLLocationManager.authorizationStatus() == .authorizedWhenInUse {
                        self.requestLocation(observer: observer, explicit: false)
                    }
                }, notDetermined: true)
            }
            if (CLLocationManager.authorizationStatus() == .denied) {
                let alertController = UIAlertController(title: NSLocalizedString("location_permission_required",comment: "Alerts"), message: NSLocalizedString("location_permission_general",comment: "Alerts"), preferredStyle: .alert)
                alertController.addAction(UIAlertAction(title: NSLocalizedString("Change In Settings",comment: "Alerts"), style: .default, handler: {_ in
                    if let url = NSURL(string: UIApplication.openSettingsURLString) as URL? {
                        UIApplication.shared.open(url, options: [:], completionHandler: nil)
                    }
                }))
                userDefaults?.setValue(false, forKey: "autoZoom")
                alertController.addAction(UIAlertAction(title: NSLocalizedString("Dismiss",comment: "Alerts"), style: .default))

                let keyWindow = UIApplication.shared.windows.filter {$0.isKeyWindow}.first
                var rootViewController = keyWindow?.rootViewController
                if let navigationController = rootViewController as? UINavigationController {
                    rootViewController = navigationController.viewControllers.first
                }
                if let tabBarController = rootViewController as? UITabBarController {
                    rootViewController = tabBarController.selectedViewController
                }
                rootViewController?.present(alertController, animated: true, completion: nil)
            }
        }

        if let location = self.lastReceivedLocation {
            observer.notify(location: location)
        } else {
            NSLog("location requested by observer, but none cached!")
        }
    }

    // =============== Notification center callbacks ==========
    @objc func willResignActive() {
        if carPlayConnected {
            return
        }
        if (accurateLocationUpdatesEnabled) {
            self.locationManager.stopUpdatingLocation()
        }
        locationManager.desiredAccuracy = backgroundAccuracy
        startSignificantChangeLocationUpdates()
    }

    @objc func willEnterForeground() {
        if (accurateLocationUpdatesEnabled) {
            startAccurateLocationUpdates()
        }
    }

    // setters to change between various location modes
    func startSignificantChangeLocationUpdates() {
        self.locationManager.allowsBackgroundLocationUpdates = true
        self.locationManager.startMonitoringSignificantLocationChanges()
    }

    /* unused */
    /*func startBackgroundLocationUpdates() {
        self.locationManager.allowsBackgroundLocationUpdates = true
        self.locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
        self.locationManager.pausesLocationUpdatesAutomatically = true
        self.locationManager.activityType = CLActivityType.other
        self.locationManager.startUpdatingLocation()
    }*/

    /// - Parameter force: keep the updates coming even with the app in the
    ///   background. CarPlay needs that: with the phone locked the app is not
    ///   "active", and the car screen is still the thing the user is looking
    ///   at. Background delivery is already covered by the `location`
    ///   background mode and `allowsBackgroundLocationUpdates`.
    func startAccurateLocationUpdates(force: Bool = false) {
        if !force && UIApplication.shared.applicationState != .active {
            return
        }

        self.locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        self.locationManager.pausesLocationUpdatesAutomatically = true
        self.locationManager.activityType = CLActivityType.other
        self.locationManager.startUpdatingLocation()
        accurateLocationUpdatesEnabled = true
    }

    func stopAccurateLocationUpdates() {
        self.locationManager.stopUpdatingLocation()
        accurateLocationUpdatesEnabled = false
    }

    // helper method to decide whether a new location is significant enough to be reported
    // to the backend.
    private func decideSignificantChange(old: CLLocation?, new: CLLocation?) -> Bool {
        if let old = old, let new = new {
            if new.horizontalAccuracy < old.horizontalAccuracy {
                return true
            }
            if new.verticalAccuracy + 1 < old.verticalAccuracy {
                return true
            }
            if new.distance(from: old) > 500 && new.timestamp.timeIntervalSince(old.timestamp) >= 60{
                return true
            }
            return false
        } else {
            return true
        }
    }

    // delegate method called when new location events are available (background and foreground location)
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        var background = true
        if UIApplication.shared.applicationState == .active {
            background = false
        }

        if let location = locations.last {
            if (background || decideSignificantChange(old: self.lastPostedLocation, new: location)) {
                // take pressure measurement and send json request
                pressure.getPressure(completion: {
                    pressure in self.postLocationDeferred(location: location, pressure: pressure)  })
                self.lastPostedLocation = location
            }

            UserDefaults.init(suiteName: "group.org.frcy.app.meteocool")?.setValue(location.coordinate.latitude, forKey: "lat")
            UserDefaults.init(suiteName: "group.org.frcy.app.meteocool")?.setValue(location.coordinate.longitude, forKey: "lon")
            UserDefaults.init(suiteName: "group.org.frcy.app.meteocool")?.setValue(location.coordinate.longitude, forKey: "accuracy")

            // XXX decide if new location is better than the previous one. does apple guarantee this??
            // XXX apparently not
            self.lastReceivedLocation = location

            // Observers are notified whatever the app's state: the CarPlay map
            // is an observer, and it is on screen exactly when the phone is
            // not. The phone's own map updating while it is in the background
            // costs one JS call that WebKit throttles anyway.
            for observer in observers {
                observer.notify(location: location)
            }

            if (!background) {
                if location.horizontalAccuracy <= 20 {
                    locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
                }
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        NSLog("CLLocationManager error: \(error)")
    }

    // interface methods to the backend
    func postLocationDeferred(location: CLLocation, pressure: Float) {
        // XXX not sure we need this hack... if there is no token, don't use background location stuff
        if SharedNotificationManager.getToken() != nil {
            postLocation(location: location, pressure: pressure)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(4), execute: {
                self.postLocation(location: location, pressure: pressure)
            })
        }
    }

    func postLocation(location: CLLocation, pressure: Float) {
        let tokenValue = SharedNotificationManager.getToken() ?? "anon"

        // The backend's `lang` is an enum of de/en. Anything else (a device set
        // to French, say) fails validation there, and the legacy endpoint turns
        // that into `success: false` — silently dropping the push registration
        // and the barometric reading along with it. Clamp here instead.
        let preferredLanguage = Locale.preferredLanguages.first?.split(separator: "-").first.map(String.init)
        let lang = preferredLanguage == "de" ? "de" : "en"
        /*if let bundle_lang = Bundle.main.preferredLocalizations.first {
            lang = bundle_lang
        }*/
        
        let intensityDbzValues = [14,20,26,36,41]

        let locationDict = [
            "lat": location.coordinate.latitude as Double,
            "lon": location.coordinate.longitude as Double,
            "lang": lang,
            "altitude": location.altitude as Double,
            "accuracy": location.horizontalAccuracy as Double,
            "verticalAccuracy": location.verticalAccuracy as Double,
            "speed": location.speed as Double,
            "course": location.course as Double,
            "pressure": pressure,
            "timestamp": location.timestamp.timeIntervalSince1970 as Double,
            // The slider is zero-based and its label reads (index + 1) * 5 min,
            // so the lead time sent here was one step short of what the user
            // picked — and at the lowest setting it was 0, which the backend
            // rejects outright (`ahead` must be > 0), taking the whole update
            // with it. `?? 3+1` parsed as `?? 4`, not `(?? 3) + 1`.
            "ahead": ((userDefaults?.integer(forKey: "timeBeforeValue") ?? 1) + 1) * 5,
            "intensity": intensityDbzValues[userDefaults?.integer(forKey: "intensityValue") ?? 1] ,
            "source": "ios",
            "experimental": userDefaults?.bool(forKey: "experimentalFeatures") ?? false,
            // `details` is what the old backend reads, `withDBZ` what the v4 one
            // does. Both are sent because the app talks to either deployment
            // depending on the environment, and each ignores the other's key.
            "details": userDefaults?.bool(forKey: "withDBZ") ?? false,
            "withDBZ": userDefaults?.bool(forKey: "withDBZ") ?? false,
            "token": tokenValue,
            ] as [String: Any]

        guard let request = NetworkHelper.createJSONPostRequest(dst: "post_location", dictionary: locationDict) else {
            return
        }

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = NetworkHelper.checkResponse(data: data, response: response, error: error) else {
                return
            }

            if let json = ((try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]) as [String : Any]??) {
                if let errorMessage = json?["error"] as? String {
                    NSLog("ERROR: \(errorMessage)")
                }
            }
        }
        task.resume()
    }
    
    func getCurrentLocation() -> CLLocation?{
        return SharedLocationUpdater.locationManager.location ?? nil
    }
}
