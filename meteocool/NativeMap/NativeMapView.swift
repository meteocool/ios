//
//  NativeMapView.swift
//  meteocool
//
//  The radar map drawn with MapKit instead of core's web map.
//

import Combine
import MapKit
import SwiftUI
import UIKit

/// core's flat radar map, native: Apple's base map, the radar composite
/// with its five-minute steps from two hours back to two ahead, and the
/// parts drawn over it (`NativeMapFeature`), kept live over core's socket.
///
/// `ViewController` keeps its controls, location button and sheets, and
/// shows this in place of the web view while the native map is on
/// (`nativeMap` in Settings).
@MainActor
final class NativeMapView: UIView, MKMapViewDelegate, NativeMapContext, UIGestureRecognizerDelegate {
    /// Where the map opens without a link or a location (core's `latLonZ` default).
    static let defaultView = NativeMapLink(latitude: 49.0, longitude: 11.0, zoom: 6)
    /// The stored switch that puts this map in place of the web view.
    static let settingKey = "nativeMap"

    let mapView = MKMapView()
    let model = NativeMapModel()
    let radar: RadarEngine
    var player: RadarPlayer { radar.player }
    private(set) var endpoints = NativeMapEndpoints.of(.current)
    weak var host: NativeMapHost?

    private let socket: RadarSocket
    private(set) var features: [NativeMapFeature] = []
    private var chrome: [UIView] = []
    private var bottomChrome: UIView?
    private let defaults = UserDefaults(suiteName: "group.org.frcy.app.meteocool")
    private var ticker: Timer?
    private var started = false
    private var placed = false
    private var pendingView: NativeMapLink?
    private var lastRotation: Bool?
    private var observers = Set<AnyCancellable>()

    init() {
        radar = RadarEngine(mapView: mapView, endpoints: endpoints,
                            palette: UserDefaults(suiteName: "group.org.frcy.app.meteocool")?.string(forKey: "radarColorMapping") ?? "classic")
        socket = RadarSocket(host: endpoints.api)
        super.init(frame: .zero)
        configureMap()
        configureChrome()
        configureGestures()

        radar.onStep = { [weak self] _ in self?.stepChanged() }
        radar.onSeries = { [weak self] series in
            self?.model.serverTime = Date(timeIntervalSince1970: TimeInterval(series.serverTime))
        }
        socket.onEvent = { [weak self] name, data in self?.socketEvent(name, data) }
        socket.onReconnect = { [weak self] in self?.wake() }
        socket.onConnection = { [weak self] connected in self?.model.connected = connected }

        for feature in Self.makeFeatures() { add(feature) }
        applySettings()
        #if DEBUG && targetEnvironment(simulator)
        // A view and frame to open at, to hold the map against core's:
        // `MC_NATIVE_MAP_LINK='?latLonZ=45.8,4.6,7'`.
        if let search = ProcessInfo.processInfo.environment["MC_NATIVE_MAP_LINK"] { open(search: search) }
        #endif
        // Nothing to keep live in the background; `ViewController` starts
        // it again when the app is active.
        NotificationCenter.default.addObserver(self, selector: #selector(enteredBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        model.$covers
            .sink { [weak self] covers in self?.host?.mapCovered(!covers.isEmpty, by: "nativeMap") }
            .store(in: &observers)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The parts of the map, bottom to top.
    private static func makeFeatures() -> [NativeMapFeature] {
        [LightningMarks(), MesocycloneMarks(), StormMarks()]
    }

    /// Adds a part; it is attached at once.
    func add(_ feature: NativeMapFeature) {
        features.append(feature)
        feature.attach(to: self)
    }

    @objc private func enteredBackground() {
        stop()
    }

    private func configureMap() {
        mapView.translatesAutoresizingMaskIntoConstraints = false
        mapView.delegate = self
        mapView.isPitchEnabled = false
        mapView.showsScale = false
        mapView.showsCompass = true
        mapView.pointOfInterestFilter = .excludingAll
        mapView.accessibilityIdentifier = "nativeMap"
        // Labels and roads' names above the radar, as core raises them.
        mapView.addOverlay(radar.overlay, level: .aboveRoads)
        addSubview(mapView)
        NSLayoutConstraint.activate([
            mapView.topAnchor.constraint(equalTo: topAnchor),
            mapView.bottomAnchor.constraint(equalTo: bottomAnchor),
            mapView.leadingAnchor.constraint(equalTo: leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    /// The SwiftUI controls over the map, each in its own host so the map
    /// keeps every touch that misses them.
    private func configureChrome() {
        let bottom = addChrome(RadarTimelineBar(player: player, model: model))
        NSLayoutConstraint.activate([
            bottom.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ])
        bottomChrome = bottom
    }

    /// Hosts a SwiftUI view over the map, sized to fit; the caller places it.
    @discardableResult
    func addChrome<Content: View>(_ content: Content) -> UIView {
        let host = UIHostingController(rootView: content)
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.sizingOptions = .intrinsicContentSize
        addSubview(host.view)
        chrome.append(host.view)
        return host.view
    }

    private func configureGestures() {
        let press = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        press.delegate = self
        mapView.addGestureRecognizer(press)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.delegate = self
        mapView.addGestureRecognizer(tap)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Taps on marks are the map's own (`didSelect`).
        var view = touch.view
        while let current = view, current !== mapView {
            if current is MKAnnotationView { return false }
            view = current.superview
        }
        return true
    }

    @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        let point = recognizer.location(in: mapView)
        let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        _ = features.first { $0.didLongPress(at: coordinate) }
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: mapView)
        let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
        _ = features.first { $0.didTap(at: coordinate, point: point) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Keep Apple's logo and legal link clear of the controls at the bottom.
        if let bottom = bottomChrome {
            let covered = bounds.maxY - bottom.frame.minY - safeAreaInsets.bottom + 8
            if abs(mapView.layoutMargins.bottom - covered) > 1 {
                mapView.layoutMargins = UIEdgeInsets(top: 0, left: 0, bottom: max(covered, 0), right: 0)
            }
        }
        if !placed, mapView.bounds.width > 0 {
            placed = true
            place(pendingView ?? Self.defaultView, animated: false)
            pendingView = nil
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        let dark = traitCollection.userInterfaceStyle == .dark
        if dark != model.isDark {
            model.isDark = dark
            for feature in features { feature.settingsDidChange() }
        }
    }

    // MARK: - Lifecycle

    /// Starts loading and listening; the map is on screen.
    func start() {
        guard !started else { return }
        started = true
        radar.start()
        socket.start()
        wake()
        ticker = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Stops the socket and the timers; the map is off screen or the app in the background.
    func stop() {
        guard started else { return }
        started = false
        radar.stop()
        socket.stop()
        ticker?.invalidate()
        ticker = nil
        for feature in features { feature.stop() }
    }

    /// Everything again: the app came back, or the socket did (core's wake).
    private func wake() {
        radar.wake()
        for feature in features { feature.wake() }
    }

    private func tick() {
        radar.tick()
        for feature in features { feature.tick() }
        updateCredits()
    }

    private func stepChanged() {
        let step = RadarStep(time: player.step, isLive: player.step != nil && player.step == player.timeline.now,
                             isForecast: player.step.map(player.timeline.isForecast) ?? false)
        for feature in features { feature.stepDidChange(step) }
        updateCredits()
    }

    private func socketEvent(_ name: String, _ data: Data) {
        radar.socketEvent(name, data)
        for feature in features { feature.socketEvent(name, data) }
    }

    // MARK: - Settings

    func isOn(_ layer: NativeMapLayer) -> Bool {
        defaults?.object(forKey: "nativeMap.\(layer.rawValue)") as? Bool ?? layer.defaultOn
    }

    func setOn(_ layer: NativeMapLayer, _ on: Bool) {
        defaults?.set(on, forKey: "nativeMap.\(layer.rawValue)")
        applySettings()
    }

    /// The layers button's menu: what the native map draws over the radar.
    func layerMenu() -> UIMenu {
        let layers: [NativeMapLayer] = [.lightning, .mesocyclones, .storms, .nowcast]
        return UIMenu(title: NSLocalizedString("map_layers", comment: ""), children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                guard let self else { return completion([]) }
                completion(layers.map { layer in
                    UIAction(title: Self.title(layer), image: UIImage(systemName: Self.symbol(layer)),
                             state: self.isOn(layer) ? .on : .off) { [weak self] _ in
                        guard let self else { return }
                        self.setOn(layer, !self.isOn(layer))
                    }
                })
            },
        ])
    }

    private static func title(_ layer: NativeMapLayer) -> String {
        NSLocalizedString("native_map_layer_\(layer.rawValue)", comment: "")
    }

    private static func symbol(_ layer: NativeMapLayer) -> String {
        switch layer {
        case .lightning: return "bolt.fill"
        case .mesocyclones: return "tornado"
        case .storms: return "cloud.bolt.rain.fill"
        case .nowcast: return "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .snow: return "snowflake"
        case .cells3d: return "cube"
        case .terrain3d: return "mountain.2"
        }
    }

    /// Reads the stored settings: palette, base map, rotation, deployment,
    /// layer switches.
    func applySettings() {
        radar.setPalette(defaults?.string(forKey: "radarColorMapping") ?? "classic")
        applyBaseMap(defaults?.string(forKey: "baseLayer") ?? "system")

        let rotation = defaults?.bool(forKey: "mapRotation") ?? false
        mapView.isRotateEnabled = rotation
        if !rotation, lastRotation == true, mapView.camera.heading != 0 {
            let camera = mapView.camera.copy() as! MKMapCamera
            camera.heading = 0
            mapView.setCamera(camera, animated: true)
        }
        lastRotation = rotation

        let next = NativeMapEndpoints.of(.current)
        if next != endpoints {
            endpoints = next
            radar.setEndpoints(next)
            socket.setHost(next.api)
        }
        radar.nowcast = isOn(.nowcast)
        for feature in features { feature.settingsDidChange() }
        updateCredits()
    }

    /// Apple's map kept muted under the radar, as core's own base maps are.
    /// `osm` and `cyclosm` were the busier maps: Apple's full map stands in.
    private func applyBaseMap(_ layer: String) {
        let busy = layer == "osm" || layer == "cyclosm"
        let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: busy ? .default : .muted)
        configuration.pointOfInterestFilter = layer == "cyclosm"
            ? MKPointOfInterestFilter(including: [.park, .nationalPark, .campground, .beach]) : .excludingAll
        mapView.preferredConfiguration = configuration
        switch layer {
        case "light": overrideUserInterfaceStyle = .light
        case "dark": overrideUserInterfaceStyle = .dark
        default: overrideUserInterfaceStyle = .unspecified
        }
        model.isDark = traitCollection.userInterfaceStyle == .dark
    }

    /// Who the data on screen is from, as core credits each visible layer.
    func updateCredits() {
        var names = model.capability == .radar ? radar.credits(in: mapView.visibleMapRect) : []
        if isOn(.lightning) || model.capability == .lightning { names.append("Blitzortung.org") }
        model.credits = names.isEmpty ? "" : "© " + names.joined(separator: ", © ")
    }

    // MARK: - Data

    func fetch(_ url: URL, _ handler: @escaping @MainActor (Data?, Int?) -> Void) {
        URLSession.shared.dataTask(with: url) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode
            let body = status.map { (200 ..< 300).contains($0) } == true ? data : nil
            Task { @MainActor in handler(body, status) }
        }.resume()
    }

    // MARK: - The host's calls

    /// The user's position from the location button, as core's
    /// `lm.updateLocation`: `zoom` zooms in by the fix's accuracy, `focus`
    /// centres on it. Nil hides the dot.
    func showLocation(_ location: CLLocation?, zoom: Bool, focus: Bool) {
        mapView.showsUserLocation = location != nil
        model.userLocation = location
        guard let location else { return }
        if focus {
            if zoom {
                let accuracy = location.horizontalAccuracy
                place(NativeMapLink(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                                    zoom: accuracy < 800 ? 10 : accuracy < 2000 ? 9 : 8), animated: true)
            } else {
                mapView.setCenter(location.coordinate, animated: true)
            }
        }
        // The readings are for a long-pressed point while there is one.
        if model.point == nil { radar.point = location.coordinate }
    }

    /// Back to the live radar, as the logo does on the web map.
    func showLive() {
        model.capability = .radar
        player.showLive()
    }

    /// A link's view and frame (core's `latLonZ` and `t`).
    func open(search: String) {
        guard let link = NativeMapLink(search: search) else { return }
        if placed { place(link, animated: true) } else { pendingView = link }
        radar.show(time: link.time)
    }

    /// A link to what is on screen, in core's spelling, for the share sheet.
    func share() -> MapShare? {
        let center = mapView.centerCoordinate
        let time = player.step != player.timeline.now ? player.step : nil
        let link = NativeMapLink(latitude: center.latitude, longitude: center.longitude, zoom: zoomLevel, time: time)
        let shared = NativeMapLink.frameLink(Int(Date().timeIntervalSince1970) / 60 * 60)
        let url = MeteocoolEnvironment.current.mapURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            + "/" + link.search + "&shared=" + shared
        guard let data = try? JSONSerialization.data(withJSONObject: ["url": url, "title": "meteocool"]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return MapShare(json: json, mapHost: MeteocoolEnvironment.current.mapURL.host)
    }

    /// The map as on screen, for a screenshot's share.
    func snapshot() -> UIImage {
        UIGraphicsImageRenderer(bounds: bounds).image { _ in
            drawHierarchy(in: bounds, afterScreenUpdates: false)
        }
    }

    // MARK: - View

    /// OpenLayers' zoom, which links carry: 256 points per world at zoom 0.
    var zoomLevel: Double {
        let width = mapView.visibleMapRect.width
        guard width > 0, mapView.bounds.width > 0 else { return Self.defaultView.zoom }
        return log2(MKMapSize.world.width * Double(mapView.bounds.width) / (256 * width))
    }

    func place(_ link: NativeMapLink, animated: Bool) {
        guard mapView.bounds.width > 0 else {
            pendingView = link
            return
        }
        let coordinate = CLLocationCoordinate2D(latitude: link.latitude, longitude: link.longitude)
        let width = MKMapSize.world.width * Double(mapView.bounds.width) / (256 * pow(2, link.zoom))
        if !animated {
            // Close enough to measure from: MapKit fits a rect inside the
            // safe area and the strip, so it lands zoomed out a little.
            let height = width * Double(mapView.bounds.height / mapView.bounds.width)
            let center = MKMapPoint(coordinate)
            mapView.setVisibleMapRect(MKMapRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height),
                                      animated: false)
        }
        // The camera's distance sets the zoom over the whole view: the width
        // it shows grows with it, in map points per metre where it looks.
        let camera = mapView.camera
        let shown = mapView.visibleMapRect.width / MKMapPointsPerMeterAtLatitude(mapView.centerCoordinate.latitude)
        guard shown > 0, camera.centerCoordinateDistance > 0 else { return }
        let wanted = width / MKMapPointsPerMeterAtLatitude(link.latitude)
        let target = MKMapCamera(lookingAtCenter: coordinate, fromDistance: camera.centerCoordinateDistance * wanted / shown,
                                 pitch: 0, heading: camera.heading)
        mapView.setCamera(target, animated: animated)
    }

    // MARK: - MKMapViewDelegate

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        if overlay === radar.overlay { return radar.makeRenderer() }
        for feature in features {
            if let renderer = feature.renderer(for: overlay) { return renderer }
        }
        return MKOverlayRenderer(overlay: overlay)
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        for feature in features {
            if let view = feature.view(for: annotation, in: mapView) { return view }
        }
        return nil
    }

    func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
        _ = features.first { $0.didSelect(annotation) }
    }

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        radar.regionDidChange()
        for feature in features { feature.regionDidChange() }
        updateCredits()
    }
}
