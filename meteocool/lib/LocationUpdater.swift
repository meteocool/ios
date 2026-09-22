import UIKit
import CoreLocation

@MainActor protocol LocationObserver: AnyObject {
    func notify(location: CLLocation)
}

@MainActor let SharedLocationUpdater = LocationUpdater.init()

// CLLocationManager delivers its delegate callbacks on the queue the manager was
// created on — always main here — so the @preconcurrency conformance is sound.
@MainActor class LocationUpdater: NSObject, @preconcurrency CLLocationManagerDelegate {
    /// location manager instace we're wrapping
    private let locationManager: CLLocationManager
    /// pressure manager object
    private let pressure: PressureManager = PressureManager()
    private let observers = NSHashTable<AnyObject>.weakObjects()

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
    private var postTask: Task<Void, Never>?

    /// default accuracy for monitoring significant location changes
    private let backgroundAccuracy = kCLLocationAccuracyKilometer

    private var authorizationCallbacks: [(Bool, Error?) -> Void] = []

    /// constructor
    init(locationManager: CLLocationManager = CLLocationManager()) {
        self.locationManager = locationManager
        super.init()
        locationManager.delegate = self
        printAuthorizationStatus()
    }

    var authorizationStatus: CLAuthorizationStatus { locationManager.authorizationStatus }

    func printAuthorizationStatus() { updateBackgroundMonitoring() }

    func requestAuthorization(_ completion: @escaping (Bool, Error?) -> Void) {
        switch authorizationStatus {
        case .notDetermined:
            authorizationCallbacks.append(completion)
            if authorizationCallbacks.count == 1 { locationManager.requestWhenInUseAuthorization() }
        case .authorizedWhenInUse, .authorizedAlways:
            startAccurateLocationUpdates()
            completion(true, nil)
        default:
            completion(false, nil)
        }
    }

    func requestBackgroundAuthorization() {
        guard authorizationStatus == .authorizedWhenInUse else { return }
        locationManager.requestAlwaysAuthorization()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        guard status != .notDetermined else { return }
        let granted = status == .authorizedWhenInUse || status == .authorizedAlways
        let completions = authorizationCallbacks
        authorizationCallbacks.removeAll()
        if granted {
            startAccurateLocationUpdates()
        } else {
            locationManager.stopUpdatingLocation()
            lastPostedLocation = nil
            userDefaults?.set(false, forKey: "autoZoom")
        }
        updateBackgroundMonitoring()
        completions.forEach { $0(granted, nil) }
        if granted {
            refreshNotificationRegistration()
        } else {
            SharedNotificationManager.unregister()
        }
        NotificationCenter.default.post(name: NSNotification.Name("SettingsChanged"), object: nil)
    }

    func updateBackgroundMonitoring() {
        let enabled = userDefaults?.bool(forKey: "pushNotification") == true
        if enabled && authorizationStatus == .authorizedAlways {
            startSignificantChangeLocationUpdates()
        } else {
            locationManager.stopMonitoringSignificantLocationChanges()
            locationManager.allowsBackgroundLocationUpdates = carPlayConnected
        }
    }

    func refreshNotificationRegistration() {
        updateBackgroundMonitoring()
        guard SharedNotificationManager.canRegister else { return }
        if let location = getCurrentLocation() {
            postLocation(location: location, pressure: -1)
        } else if authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse {
            locationManager.requestLocation()
        }
    }

    // =============== Observer pattern ===========
    func addObserver(observer: LocationObserver) {
        observers.add(observer)
    }
    
    let userDefaults = UserDefaults.init(suiteName: "group.org.frcy.app.meteocool")

    // executed when the user taps the locate-me button
    func requestLocation(observer: LocationObserver, explicit: Bool) {
        if (explicit) {
            if (authorizationStatus == .notDetermined) {
                requestAuthorization({(_,_) in
                    if self.authorizationStatus == .authorizedAlways || self.authorizationStatus == .authorizedWhenInUse {
                        self.requestLocation(observer: observer, explicit: false)
                    }
                })
            }
            if (authorizationStatus == .denied || authorizationStatus == .restricted) {
                let alertController = UIAlertController(title: NSLocalizedString("location_permission_required",comment: "Alerts"), message: NSLocalizedString("location_permission_general",comment: "Alerts"), preferredStyle: .alert)
                alertController.addAction(UIAlertAction(title: NSLocalizedString("Change In Settings",comment: "Alerts"), style: .default, handler: {_ in
                    if let url = NSURL(string: UIApplication.openSettingsURLString) as URL? {
                        UIApplication.shared.open(url, options: [:], completionHandler: nil)
                    }
                }))
                userDefaults?.setValue(false, forKey: "autoZoom")
                alertController.addAction(UIAlertAction(title: NSLocalizedString("Dismiss",comment: "Alerts"), style: .default))

                let keyWindow = viewController?.view.window
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

        if let location = getCurrentLocation() {
            observer.notify(location: location)
        } else if authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse {
            locationManager.requestLocation()
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
        updateBackgroundMonitoring()
    }

    @objc func willEnterForeground() {
        updateBackgroundMonitoring()
        if (accurateLocationUpdatesEnabled) {
            startAccurateLocationUpdates()
        }
    }

    // setters to change between various location modes
    func startSignificantChangeLocationUpdates() {
        self.locationManager.allowsBackgroundLocationUpdates = true
        self.locationManager.startMonitoringSignificantLocationChanges()
    }

    /// - Parameter force: keep the updates coming even with the app in the
    ///   background. CarPlay needs that: with the phone locked the app is not
    ///   "active", and the car screen is still the thing the user is looking
    ///   at. Background delivery is already covered by the `location`
    ///   background mode and `allowsBackgroundLocationUpdates`.
    func startAccurateLocationUpdates(force: Bool = false) {
        guard authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse else { return }
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
        // The phone's location control must not stop the car's active stream.
        guard !carPlayConnected else { return }
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

        if let location = locations.last, location.horizontalAccuracy >= 0,
           abs(location.timestamp.timeIntervalSinceNow) < 300 {
            if SharedNotificationManager.canRegister && (background || decideSignificantChange(old: self.lastPostedLocation, new: location)) {
                // take pressure measurement and send json request
                pressure.getPressure(completion: {
                    pressure in self.postLocationDeferred(location: location, pressure: pressure)  })
                self.lastPostedLocation = location
            }

            UserDefaults.init(suiteName: "group.org.frcy.app.meteocool")?.setValue(location.coordinate.latitude, forKey: "lat")
            UserDefaults.init(suiteName: "group.org.frcy.app.meteocool")?.setValue(location.coordinate.longitude, forKey: "lon")
            UserDefaults.init(suiteName: "group.org.frcy.app.meteocool")?.setValue(location.horizontalAccuracy, forKey: "accuracy")

            // Observers are notified whatever the app's state: the CarPlay map
            // is an observer, and it is on screen exactly when the phone is
            // not. The phone's own map updating while it is in the background
            // costs one JS call that WebKit throttles anyway.
            for observer in observers.allObjects {
                (observer as? LocationObserver)?.notify(location: location)
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
        postLocation(location: location, pressure: pressure)
    }

    func postLocation(location: CLLocation, pressure: Float) {
        guard SharedNotificationManager.canRegister,
              let tokenValue = SharedNotificationManager.getToken(),
              authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse,
              location.horizontalAccuracy >= 0,
              abs(location.timestamp.timeIntervalSinceNow) < 300 else { return }

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
            "ahead": (min(max(userDefaults?.integer(forKey: "timeBeforeValue") ?? 2, 0), 8) + 1) * 5,
            "intensity": intensityDbzValues[min(max(userDefaults?.integer(forKey: "intensityValue") ?? 1, 0), 4)] ,
            "source": "ios",
            "experimental": MeteocoolEnvironment.current == .staging,
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

        let previous = postTask
        postTask = Task {
            await previous?.value
            guard SharedNotificationManager.canRegister,
                  SharedNotificationManager.getToken() == tokenValue,
                  abs(location.timestamp.timeIntervalSinceNow) < 300 else { return }
            SharedNotificationManager.registrationWillBegin()
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let success = NetworkHelper.checkResponse(data: data, response: response, error: nil) != nil
                if !success { self.lastPostedLocation = nil }
                SharedNotificationManager.registrationFinished(success: success)
            } catch {
                self.lastPostedLocation = nil
                SharedNotificationManager.registrationFinished(success: false)
            }
        }
    }

    func getCurrentLocation() -> CLLocation?{
        guard authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse,
              let location = locationManager.location, location.horizontalAccuracy >= 0,
              abs(location.timestamp.timeIntervalSinceNow) < 300 else { return nil }
        return location
    }
}
