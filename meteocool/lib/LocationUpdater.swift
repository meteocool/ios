import UIKit
import CoreLocation

protocol LocationObserver: AnyObject {
    func notify(location: CLLocation)
}

@MainActor let SharedLocationUpdater = LocationUpdater(settings: .shared)

// XXX is there a way to make this class not instanciable? it should be a singleton (FUCKING JAVA BROKE ME)
@MainActor
class LocationUpdater: NSObject {
    /// location manager instace we're wrapping
    private let locationManager: CLLocationManager = CLLocationManager()
    /// pressure manager object
    private let pressure: PressureManager = PressureManager()
    /// Location observers (only notified if app is active and a new location update becomes available)
    private var observers = [LocationObserver]()

    private let postRetryDelays: [TimeInterval] = [2, 5, 10]
    private var postRetryAttempt: Int = 0
    private var postRetryWorkItem: DispatchWorkItem?
    private var activePostId: UUID = UUID()

    // accurate location updates are/were enabled before suspend
    private var accurateLocationUpdatesEnabled: Bool = false

    // the last location reported to the backend
    private var lastPostedLocation: CLLocation?
    // the last received location (might not have been reported to the backend)
    private var lastReceivedLocation: CLLocation?
    // Forces a one-off backend registration sync on the next location fix.
    private var pendingForcedSyncPost: Bool = false

    /// default accuracy for monitoring significant location changes
    private let backgroundAccuracy = kCLLocationAccuracyKilometer

    /// populated with the completion handler from the onboarding thing
    var authCompletionHandler: ((Bool, Error?) -> Void)?

    private let settings: SettingsStore

    /// constructor
    init(settings: SettingsStore = .shared) {
        self.settings = settings
        super.init()
        locationManager.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(LocationUpdater.willEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(LocationUpdater.willResignActive), name: UIApplication.willResignActiveNotification, object: nil)
        printAuthorizationStatus()
    }

    var authorizationStatus: CLAuthorizationStatus {
        locationManager.authorizationStatus
    }

    func printAuthorizationStatus() {
        if CLLocationManager.locationServicesEnabled() {
            let status = locationManager.authorizationStatus
            switch status {
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

    var isAuthorized: Bool {
        let status = locationManager.authorizationStatus
        return status == .authorizedAlways || status == .authorizedWhenInUse
    }

    func requestAuthorization(_ completion: @escaping (_ success: Bool, _ error: Error?) -> Void, notDetermined: Bool) {
        authCompletionHandler = completion
        if settings.notificationsEnabled {
            locationManager.requestAlwaysAuthorization()
        } else {
            locationManager.requestWhenInUseAuthorization()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        if let authCompletionHandler = authCompletionHandler {
            switch status {
            case .notDetermined:
                // Still waiting for user decision, don't call completion yet
                return
            case .authorizedWhenInUse:
                locationManager.startUpdatingLocation()
                authCompletionHandler(true, nil)
            case .authorizedAlways:
                locationManager.startUpdatingLocation()
                startSignificantChangeLocationUpdates()
                authCompletionHandler(true, nil)
            case .restricted, .denied:
                authCompletionHandler(false, nil)
            @unknown default:
                authCompletionHandler(false, nil)
            }
            self.authCompletionHandler = nil
        }
    }

    // =============== Observer pattern ===========
    func addObserver(observer: LocationObserver) {
        if observers.contains(where: { $0 === observer }) {
            return
        }
        observers.append(observer)
    }

    // executed when the user taps the locate-me button
    func requestLocation(observer: LocationObserver, explicit: Bool) {
        addObserver(observer: observer)
        let status = locationManager.authorizationStatus

        if (explicit) {
            switch status {
            case .notDetermined:
                requestAuthorization({(_,_) in
                    if self.locationManager.authorizationStatus == .authorizedAlways || self.locationManager.authorizationStatus == .authorizedWhenInUse {
                        self.requestLocation(observer: observer, explicit: false)
                    }
                }, notDetermined: true)
            case .denied, .restricted:
                let alertController = UIAlertController(title: NSLocalizedString("location_permission_required",comment: "Alerts"), message: NSLocalizedString("location_permission_general",comment: "Alerts"), preferredStyle: .alert)
                alertController.addAction(UIAlertAction(title: NSLocalizedString("Change in Settings",comment: "Alerts"), style: .default, handler: {_ in
                    if let url = NSURL(string: UIApplication.openSettingsURLString) as URL? {
                        UIApplication.shared.open(url, options: [:], completionHandler: nil)
                    }
                }))
                settings.autoZoom = false
                alertController.addAction(UIAlertAction(title: NSLocalizedString("Dismiss",comment: "Alerts"), style: .default))

                let keyWindow = UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .flatMap { $0.windows }
                    .first { $0.isKeyWindow }
                var rootViewController = keyWindow?.rootViewController
                if let navigationController = rootViewController as? UINavigationController {
                    rootViewController = navigationController.viewControllers.first
                }
                if let tabBarController = rootViewController as? UITabBarController {
                    rootViewController = tabBarController.selectedViewController
                }
                rootViewController?.present(alertController, animated: true, completion: nil)
            case .authorizedAlways, .authorizedWhenInUse:
                locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
                locationManager.requestLocation()
            @unknown default:
                break
            }
        } else {
            switch status {
            case .authorizedAlways, .authorizedWhenInUse:
                locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
                locationManager.requestLocation()
            default:
                break
            }
        }

        if let location = self.lastReceivedLocation {
            observer.notify(location: location)
        } else if explicit {
            NSLog("location requested by observer, but none cached!")
        }
    }

    // =============== Notification center callbacks ==========
    @objc func willResignActive() {
        if (accurateLocationUpdatesEnabled) {
            self.locationManager.stopUpdatingLocation()
        }
        if isAuthorized {
            locationManager.desiredAccuracy = backgroundAccuracy
            startSignificantChangeLocationUpdates()
        }
    }

    @objc func willEnterForeground() {
        if (accurateLocationUpdatesEnabled) {
            startAccurateLocationUpdates()
        }
    }

    // setters to change between various location modes
    func startSignificantChangeLocationUpdates() {
        guard locationManager.authorizationStatus == .authorizedAlways else {
            NSLog("Location: skipping background updates (not authorizedAlways)")
            return
        }
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

    func startAccurateLocationUpdates() {
        if UIApplication.shared.applicationState != .active {
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
            let forcePost = pendingForcedSyncPost
            if forcePost {
                pendingForcedSyncPost = false
            }
            if (forcePost || background || decideSignificantChange(old: self.lastPostedLocation, new: location)) {
                if settings.motionSharingEnabled {
                    // take pressure measurement and send json request
                    pressure.getPressure(completion: {
                        pressure in self.postLocationDeferred(location: location, pressure: pressure)  })
                } else {
                    postLocationDeferred(location: location, pressure: -1)
                }
                self.lastPostedLocation = location
            }

            let defaults = UserDefaults.init(suiteName: "group.org.frcy.app.meteocool")
            defaults?.setValue(location.coordinate.latitude, forKey: "lat")
            defaults?.setValue(location.coordinate.longitude, forKey: "lon")
            defaults?.setValue(location.horizontalAccuracy, forKey: "accuracy")

            // XXX decide if new location is better than the previous one. does apple guarantee this??
            // XXX apparently not
            self.lastReceivedLocation = location
            if (!background) {
                for observer in observers {
                    observer.notify(location: location)
                }

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

    func postLocation(location: CLLocation, pressure: Float, isRetry: Bool = false, postId: UUID? = nil) {
        let currentPostId: UUID
        if isRetry, let postId {
            currentPostId = postId
        } else {
            resetPostRetryState()
            currentPostId = UUID()
            activePostId = currentPostId
        }
        let tokenValue = SharedNotificationManager.getToken() ?? "anon"

        let preferredLanguage = Locale.preferredLanguages.first ?? "en"
        let lang = preferredLanguage.split(separator: "-").first.map(String.init) ?? preferredLanguage
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
            "ahead": (settings.notificationTimeBefore + 1) * 5,
            "intensity": intensityDbzValues[max(0, min(settings.notificationIntensity, intensityDbzValues.count - 1))],
            "source": "ios",
            "experimental": settings.experimentalFeatures,
            "details": settings.notificationShowDbz,
            "token": tokenValue,
            ] as [String: Any]

        guard let request = NetworkHelper.createJSONPostRequest(dst: "post_location", dictionary: locationDict) else {
            schedulePostLocationRetry(location: location, pressure: pressure, postId: currentPostId)
            return
        }

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = NetworkHelper.checkResponse(data: data, response: response, error: error) else {
                Task { @MainActor in
                    self.schedulePostLocationRetry(location: location, pressure: pressure, postId: currentPostId)
                }
                return
            }

            if let json = ((try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]) as [String : Any]??) {
                if let errorMessage = json?["error"] as? String {
                    NSLog("ERROR: \(errorMessage)")
                }
            }
            Task { @MainActor in
                guard self.activePostId == currentPostId else { return }
                self.resetPostRetryState()
            }
        }
        task.resume()
    }

    func getCurrentLocation() -> CLLocation? {
        return locationManager.location
    }

    func syncNotificationRegistrationNow() {
        if let location = lastReceivedLocation ?? locationManager.location {
            postLocation(location: location, pressure: -1)
            return
        }

        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            pendingForcedSyncPost = true
            locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            locationManager.requestLocation()
        default:
            NSLog("Skipping immediate backend sync: location permission not granted")
        }
    }

    private func schedulePostLocationRetry(location: CLLocation, pressure: Float, postId: UUID) {
        guard activePostId == postId else { return }
        guard postRetryAttempt < postRetryDelays.count else {
            resetPostRetryState()
            return
        }

        let baseDelay = postRetryDelays[postRetryAttempt]
        postRetryAttempt += 1
        let jitter = Double.random(in: -0.3...0.3)
        let delay = max(0, baseDelay + jitter)

        postRetryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.activePostId == postId else { return }
                self.postLocation(location: location, pressure: pressure, isRetry: true, postId: postId)
            }
        }
        postRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func resetPostRetryState() {
        postRetryWorkItem?.cancel()
        postRetryWorkItem = nil
        postRetryAttempt = 0
    }
}

extension LocationUpdater: @MainActor CLLocationManagerDelegate {}
