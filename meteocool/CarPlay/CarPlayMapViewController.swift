//
//  CarPlayMapViewController.swift
//  meteocool
//
//  The radar, drawn on the car's screen.
//

import CoreLocation
import MapKit
import UIKit

/// The live radar map shown in the `CPWindow`.
///
/// The native map's radar (`RadarEngine`) on Apple's muted base map, always,
/// whether or not the phone shows the native map. Nothing else of the
/// phone's map: no storms, no tray, no sheets. The driver has the location
/// button and zoom, which `CarPlaySceneDelegate` puts on the map template.
///
/// The car's screen takes no touches of its own: pans and pinches reach the
/// map through the template's delegate (`pan(by:)`, `zoom(around:scale:)`).
@MainActor
final class CarPlayMapViewController: UIViewController, MKMapViewDelegate, LocationObserver {
    /// The location button's states, as the phone's (`ViewController.LocationState`):
    /// off, the dot shown, the map following the car.
    enum LocationState {
        case off
        case active
        case tracking

        /// The button's symbol in each state, as on the phone.
        var symbolName: String {
            switch self {
            case .off: "location"
            case .active: "location.fill"
            case .tracking: "location.fill.viewfinder"
            }
        }
    }

    private let mapView = MKMapView()
    private let radar: RadarEngine
    private let socket: RadarSocket
    private var endpoints = NativeMapEndpoints.of(.current)
    private let defaults = UserDefaults(suiteName: "group.org.frcy.app.meteocool")
    private var ticker: Timer?
    private var running = false

    /// The car follows itself from the start: a driver has no hand free to
    /// find their position on the map.
    private(set) var locationState = LocationState.tracking {
        didSet { onLocationState?(locationState) }
    }
    /// Called when the location button's state changes, for its symbol.
    var onLocationState: ((LocationState) -> Void)?
    /// The next fix zooms in to it (the button's tracking press, and the
    /// first fix after connecting).
    private var zoomOnce = true
    /// The next fix centres the map once (the button's first press).
    private var focusOnce = false
    private var lastLocation: CLLocation?
    /// The pan gesture's translation so far, to move by what is new.
    private var panned = CGPoint.zero
    /// The view when a pinch began; the pinch's scale is against it.
    private var pinchStart: MKMapRect?

    init() {
        radar = RadarEngine(mapView: mapView, endpoints: endpoints,
                            palette: UserDefaults(suiteName: "group.org.frcy.app.meteocool")?.string(forKey: "radarColorMapping") ?? "classic")
        socket = RadarSocket(host: endpoints.api)
        super.init(nibName: nil, bundle: nil)
        radar.onSeries = { [weak self] _ in self?.radar.stale = false }
        socket.onEvent = { [weak self] name, data in self?.radar.socketEvent(name, data) }
        socket.onReconnect = { [weak self] in self?.wake() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        mapView.delegate = self
        mapView.isPitchEnabled = false
        mapView.isRotateEnabled = false
        mapView.showsCompass = false
        mapView.showsScale = false
        let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        configuration.pointOfInterestFilter = .excludingAll
        mapView.preferredConfiguration = configuration
        // Labels and roads' names above the radar, as on the phone.
        mapView.addOverlay(radar.overlay, level: .aboveRoads)
        view = mapView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        applySettings()
        SharedLocationUpdater.addObserver(observer: self)
        NotificationCenter.default.addObserver(self, selector: #selector(applySettings), name: NSNotification.Name("SettingsChanged"), object: nil)
        // Mode changed on the phone: the car shows the same deployment.
        NotificationCenter.default.addObserver(self, selector: #selector(applySettings), name: MeteocoolEnvironment.didChange, object: nil)
        // Request high-accuracy updates even when the phone UI is not in
        // front (`force: true`). The car screen needs the driver's position.
        // With the phone locked the app is not active, and the call without
        // `force` would not start updates.
        SharedLocationUpdater.startAccurateLocationUpdates(force: true)
        SharedLocationUpdater.requestLocation(observer: self, explicit: false)
    }

    private var placed = false

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Where the phone's map opens, until the first fix.
        if !placed, mapView.bounds.width > 0 {
            placed = true
            mapView.place(lastLocation.map(Self.link) ?? NativeMapView.defaultView, animated: false)
        }
    }

    // MARK: - Lifecycle

    /// Loads and listens: the map is on the car's screen.
    func start() {
        radar.player.returnedToForeground()
        guard !running else { return }
        running = true
        radar.start()
        socket.start()
        wake()
        ticker = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.radar.tick() }
        }
    }

    /// Stops the socket and the timer: another app is on the car's screen.
    func stop() {
        guard running else { return }
        running = false
        radar.player.leftForeground()
        radar.stop()
        socket.stop()
        ticker?.invalidate()
        ticker = nil
    }

    /// The car's screen was disconnected.
    func disconnect() {
        stop()
        NotificationCenter.default.removeObserver(self)
    }

    private func wake() {
        // Out of date until a new series lands, as the phone's map judges it.
        let now = Int(Date().timeIntervalSince1970)
        if ConnectionRules.outdated(newestObservation: radar.player.timeline.now, period: radar.processedTimes.cadence, now: now) {
            radar.stale = true
        }
        radar.wake()
    }

    /// The phone's palette, radar product and deployment.
    @objc private func applySettings() {
        radar.setPalette(defaults?.string(forKey: "radarColorMapping") ?? "classic")
        radar.product = RadarProduct(setting: defaults?.string(forKey: "nativeMap.radarProduct"))
        let next = NativeMapEndpoints.of(.current)
        if next != endpoints {
            endpoints = next
            radar.setEndpoints(next)
            socket.setHost(next.api)
        }
    }

    // MARK: - Controls

    /// The location button, as the phone's: shows the position, then
    /// follows it, then hides it.
    func locationButton() {
        let status = SharedLocationUpdater.authorizationStatus
        if status == .notDetermined {
            SharedLocationUpdater.requestAuthorization { [weak self] granted, _ in
                if granted { self?.press() }
            }
            return
        }
        guard status == .authorizedAlways || status == .authorizedWhenInUse else {
            onLocationDenied?()
            return
        }
        press()
    }

    /// Called when the location button is pressed without location access.
    var onLocationDenied: (() -> Void)?

    private func press() {
        switch locationState {
        case .off:
            locationState = .active
            focusOnce = true
        case .active:
            locationState = .tracking
            zoomOnce = true
        case .tracking:
            locationState = .off
            focusOnce = false
            zoomOnce = false
            mapView.showsUserLocation = false
            return
        }
        SharedLocationUpdater.startAccurateLocationUpdates(force: true)
        SharedLocationUpdater.requestLocation(observer: self, explicit: false)
    }

    /// The map was moved by hand: it stops following, as on the phone.
    private func mapMoved() {
        guard locationState == .tracking else { return }
        locationState = .active
        focusOnce = false
        zoomOnce = false
    }

    /// One zoom level in (`1`) or out (`-1`); a followed car stays centred.
    func zoom(by levels: Double) {
        guard let level = mapView.zoomLevel else { return }
        let center = locationState == .tracking ? lastLocation?.coordinate ?? mapView.centerCoordinate : mapView.centerCoordinate
        let zoom = min(max(level + levels, 3), 18)
        mapView.place(NativeMapLink(latitude: center.latitude, longitude: center.longitude, zoom: zoom), animated: true)
    }

    // MARK: - Gestures from the map template

    func panBegan() {
        panned = .zero
        mapMoved()
    }

    func pan(by translation: CGPoint) {
        let step = CGPoint(x: translation.x - panned.x, y: translation.y - panned.y)
        panned = translation
        let middle = CGPoint(x: mapView.bounds.midX - step.x, y: mapView.bounds.midY - step.y)
        mapView.setCenter(mapView.convert(middle, toCoordinateFrom: mapView), animated: false)
    }

    /// The map glides on a little after a flick.
    func panEnded(velocity: CGPoint) {
        let glide = 0.2
        let middle = CGPoint(x: mapView.bounds.midX - velocity.x * glide, y: mapView.bounds.midY - velocity.y * glide)
        mapView.setCenter(mapView.convert(middle, toCoordinateFrom: mapView), animated: true)
    }

    func pinchBegan() {
        pinchStart = mapView.visibleMapRect
        mapMoved()
    }

    /// Zooms by `scale` against the view the pinch began on, keeping the
    /// map under `center` where it is.
    func zoom(around center: CGPoint, scale: CGFloat) {
        guard let start = pinchStart, scale > 0, mapView.bounds.width > 0, mapView.bounds.height > 0 else { return }
        let x = Double(center.x / mapView.bounds.width)
        let y = Double(center.y / mapView.bounds.height)
        let focus = MKMapPoint(x: start.minX + x * start.width, y: start.minY + y * start.height)
        let width = start.width / Double(scale)
        let height = start.height / Double(scale)
        // Not past the world nor closer than the radar's pixels.
        guard width < MKMapSize.world.width, width * 256 / Double(mapView.bounds.width) > 1 else { return }
        mapView.setVisibleMapRect(MKMapRect(x: focus.x - x * width, y: focus.y - y * height, width: width, height: height),
                                  animated: false)
    }

    func pinchEnded() {
        pinchStart = nil
    }

    // MARK: - LocationObserver

    func notify(location: CLLocation) {
        lastLocation = location
        // Fixes still arrive while the button is off (CarPlay keeps them
        // running): they must not show the dot again.
        guard locationState != .off else { return }
        mapView.showsUserLocation = true
        radar.point = location.coordinate
        guard placed, locationState == .tracking || focusOnce else { return }
        if zoomOnce {
            mapView.place(Self.link(location), animated: true)
        } else {
            mapView.setCenter(location.coordinate, animated: true)
        }
        zoomOnce = false
        focusOnce = false
    }

    /// The view the location button zooms in to.
    private static func link(_ location: CLLocation) -> NativeMapLink {
        NativeMapLink(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                      zoom: NativeMapView.locationZoom(accuracy: location.horizontalAccuracy))
    }

    // MARK: - MKMapViewDelegate

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        overlay === radar.overlay ? radar.makeRenderer() : MKOverlayRenderer(overlay: overlay)
    }

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        radar.regionDidChange()
    }
}
