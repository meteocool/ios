import CarPlay
import CoreLocation
import UIKit

/// Driving Task apps use system templates; CPWindow and CPMapTemplate require Navigation approval.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, LocationObserver {
    private let template = CPInformationTemplate(title: "meteocool", layout: .leading,
                                                  items: CarPlayRainStatus.loading, actions: [])
    private var active = false
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var location: CLLocation?
    private var requestedLocation: CLLocation?
    private var lastRequest: Date?
    private var requestedSettings: CarPlayRainStatus.Settings?
    private var authorization: CLAuthorizationStatus?
    private var defaultsObserver: NSObjectProtocol?

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didConnect controller: CPInterfaceController) {
        SharedLocationUpdater.carPlayConnected = true
        SharedLocationUpdater.updateBackgroundMonitoring()
        template.actions = [CPTextButton(title: CarPlayRainStatus.text("carplay_refresh"), textStyle: .normal) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(force: true) }
        }]
        controller.setRootTemplate(template, animated: false) { success, error in
            if !success { NSLog("CarPlay template failed: %@", error?.localizedDescription ?? "Unknown error") }
        }
        start()
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didDisconnectInterfaceController controller: CPInterfaceController) {
        stop()
        location = nil
        SharedLocationUpdater.carPlayConnected = false
        SharedLocationUpdater.updateBackgroundMonitoring()
        if UIApplication.shared.applicationState != .active { SharedLocationUpdater.stopAccurateLocationUpdates() }
    }

    func sceneDidEnterBackground(_ scene: UIScene) { stop() }
    func sceneWillEnterForeground(_ scene: UIScene) { start() }

    private func start() {
        guard !active else { return }
        active = true
        SharedLocationUpdater.addObserver(observer: self)
        SharedLocationUpdater.startAccurateLocationUpdates(force: true)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: NSNotification.Name("SettingsChanged"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: MeteocoolEnvironment.didChange, object: nil)
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.active else { return }
                SharedLocationUpdater.requestLocation(observer: self, explicit: false)
                self.refresh()
            }
        }
        SharedLocationUpdater.requestLocation(observer: self, explicit: false)
        refresh()
    }

    private func stop() {
        active = false
        timer?.invalidate()
        timer = nil
        task?.cancel()
        task = nil
        lastRequest = nil
        requestedLocation = nil
        requestedSettings = nil
        authorization = nil
        NotificationCenter.default.removeObserver(self)
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = nil
    }

    @objc private func settingsChanged() {
        guard requestedSettings != CarPlayRainStatus.settings || authorization != SharedLocationUpdater.authorizationStatus else { return }
        refresh(force: true)
    }

    func notify(location: CLLocation) {
        guard active, self.location.map({ $0.timestamp <= location.timestamp }) ?? true else { return }
        self.location = location
        if let requestedLocation, location.distance(from: requestedLocation) > 500 {
            task?.cancel()
            task = nil
            self.requestedLocation = nil
            template.items = CarPlayRainStatus.loading
        }
        refresh()
    }

    private func refresh(force: Bool = false) {
        guard active else { return }
        let status = SharedLocationUpdater.authorizationStatus
        authorization = status
        guard status == .authorizedAlways || status == .authorizedWhenInUse, let location else {
            task?.cancel()
            task = nil
            requestedSettings = CarPlayRainStatus.settings
            template.items = CarPlayRainStatus.noLocation
            return
        }
        guard force || (lastRequest.map({ Date().timeIntervalSince($0) >= 30 }) ?? true) else { return }
        task?.cancel()
        if force || requestedLocation == nil { template.items = CarPlayRainStatus.loading }
        requestedLocation = location
        requestedSettings = CarPlayRainStatus.settings
        lastRequest = Date()
        task = Task { [weak self] in
            let items = await CarPlayRainStatus.load(at: location)
            guard !Task.isCancelled, let self, self.active else { return }
            self.task = nil
            guard self.requestedSettings == CarPlayRainStatus.settings else { self.refresh(force: true); return }
            // A response for a place the car has left must not describe the new location.
            guard let current = self.location, current.distance(from: location) <= 500 else { return }
            self.template.items = items
        }
    }
}
