//
//  NativeMapView.swift
//  meteocool
//
//  The radar map drawn with MapKit instead of core's web map.
//

import MapKit
import SwiftUI
import UIKit

/// core's flat radar map, native: Apple's base map, the radar composite
/// with its five-minute steps from two hours back to two ahead, lightning,
/// mesocyclones and storms, kept live over core's socket.
///
/// `ViewController` keeps its controls, location button and sheets, and
/// shows this in place of the web view while the native map is on
/// (`nativeMap` in Settings).
@MainActor
final class NativeMapView: UIView, MKMapViewDelegate {
    /// Where the map opens without a link or a location (core's `latLonZ` default).
    static let defaultView = NativeMapLink(latitude: 49.0, longitude: 11.0, zoom: 6)
    /// The stored switch that puts this map in place of the web view.
    static let settingKey = "nativeMap"

    let mapView = MKMapView()
    let player = RadarPlayer()

    private var endpoints = NativeMapEndpoints.of(.current)
    private let store: RadarTileStore
    private let compositor: RadarCompositor
    private let scene: RadarScene
    private var coverage: RadarCoverage
    private let overlay: RadarOverlay
    private let socket: RadarSocket
    private lazy var lightning = LightningMarks(mapView: mapView)
    private lazy var mesocyclones = MesocycloneMarks(mapView: mapView)
    private lazy var storms = StormMarks(mapView: mapView, endpoints: endpoints)
    private var stripHost: UIHostingController<RadarTimelineBar>?
    private let defaults = UserDefaults(suiteName: "group.org.frcy.app.meteocool")

    private var series: RadarSeries?
    private var seriesTask: URLSessionDataTask?
    private var seriesLoaded = Date.distantPast
    private var seriesPoint: CLLocation?
    private var seriesNetwork: String?
    private var seriesRetry: Timer?
    private var refreshAt: Date?
    private var refreshTimer: Timer?
    private var ticker: Timer?
    private var started = false
    /// The tiles of the step on screen, whose arrival redraws.
    private var shownTiles = Set<String>()
    /// A step scrubbed to whose pictures are not all ready: the step on
    /// screen stays until they are, then the whole map changes at once.
    private var heldFrame: RadarFrameRef?
    private var heldIndex: Int?
    private var holdTimer: Timer?
    private var prepareScheduled = false
    private var userLocation: CLLocation?
    private var placed = false
    private var pendingView: NativeMapLink?
    private var pendingTime: Int?
    private var lastRotation: Bool?

    /// The overlays the layers menu turns on and off, stored per layer.
    enum Layer: String, CaseIterable {
        case lightning, mesocyclones, storms, nowcast

        var title: String { NSLocalizedString("native_map_layer_\(rawValue)", comment: "") }
        var symbol: String {
            switch self {
            case .lightning: return "bolt.fill"
            case .mesocyclones: return "tornado"
            case .storms: return "cloud.bolt.rain.fill"
            case .nowcast: return "clock.arrow.trianglehead.counterclockwise.rotate.90"
            }
        }
    }

    init() {
        store = RadarTileStore(base: endpoints.tiles, palette: UserDefaults(suiteName: "group.org.frcy.app.meteocool")?
            .string(forKey: "radarColorMapping") ?? "classic")
        let coverage = RadarCoverage.bundled()
        self.coverage = coverage
        compositor = RadarCompositor(store: store, coverage: coverage)
        scene = RadarScene(compositor: compositor)
        overlay = RadarOverlay(scene: scene)
        socket = RadarSocket(host: endpoints.api)
        super.init(frame: .zero)
        configureMap()
        configureStrip()
        store.onTile = { [weak self] key in self?.tileArrived(key) }
        player.onStep = { [weak self] step in self?.showStep(step) }
        player.isReady = { [weak self] step in self?.isReady(step) ?? true }
        compositor.onPrepared = { [weak self] in self?.prepared() }
        compositor.onBuilt = { [weak self] frame, rect in
            guard let self, self.scene.frames.current == frame else { return }
            self.radarRenderer?.setNeedsDisplay(rect)
        }
        socket.onEvent = { [weak self] name, data in self?.socketEvent(name, data) }
        socket.onReconnect = { [weak self] in self?.wake() }
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
    }

    @objc private func enteredBackground() {
        stop()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func configureMap() {
        mapView.translatesAutoresizingMaskIntoConstraints = false
        mapView.delegate = self
        mapView.isPitchEnabled = false
        mapView.showsScale = false
        mapView.showsCompass = true
        mapView.pointOfInterestFilter = .excludingAll
        mapView.accessibilityIdentifier = "nativeMap"
        mapView.register(MesocycloneView.self, forAnnotationViewWithReuseIdentifier: MesocycloneView.reuse)
        mapView.register(StormView.self, forAnnotationViewWithReuseIdentifier: StormView.reuse)
        // Labels and roads' names above the radar, as core raises them.
        mapView.addOverlay(overlay, level: .aboveRoads)
        addSubview(mapView)
        NSLayoutConstraint.activate([
            mapView.topAnchor.constraint(equalTo: topAnchor),
            mapView.bottomAnchor.constraint(equalTo: bottomAnchor),
            mapView.leadingAnchor.constraint(equalTo: leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    private func configureStrip() {
        let host = UIHostingController(rootView: RadarTimelineBar(player: player))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.sizingOptions = .intrinsicContentSize
        addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ])
        stripHost = host
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Keep Apple's logo and legal link clear of the strip.
        if let strip = stripHost?.view {
            let covered = bounds.maxY - strip.frame.minY - safeAreaInsets.bottom + 8
            if abs(mapView.layoutMargins.bottom - covered) > 1 {
                mapView.layoutMargins = UIEdgeInsets(top: 0, left: 0, bottom: max(covered, 0), right: 0)
            }
        }
        if !placed, bounds.width > 0 {
            placed = true
            place(pendingView ?? Self.defaultView, animated: false)
            pendingView = nil
        }
    }

    // MARK: - Lifecycle

    /// Starts loading and listening; the map is on screen.
    func start() {
        guard !started else { return }
        started = true
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
        player.pause()
        socket.stop()
        ticker?.invalidate()
        ticker = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        seriesRetry?.invalidate()
        seriesTask?.cancel()
    }

    /// Everything again: the app came back, or the socket did (core's wake).
    private func wake() {
        loadSeries()
        loadCoverage()
        fetch(endpoints.lightning) { [weak self] data in self?.lightning.load(data) }
        fetch(endpoints.mesocyclones) { [weak self] data in self?.mesocyclones.load(data) }
        storms.refresh(force: true)
    }

    private func tick() {
        lightning.tick()
        mesocyclones.tick()
        storms.refresh()
        // The socket's pokes keep the series fresh; this is for when it is down.
        if Date().timeIntervalSince(seriesLoaded) > 180 { loadSeries() }
        updateOpacity()
    }

    // MARK: - Settings

    func isOn(_ layer: Layer) -> Bool {
        defaults?.object(forKey: "nativeMap.\(layer.rawValue)") as? Bool ?? true
    }

    private func toggle(_ layer: Layer) {
        defaults?.set(!isOn(layer), forKey: "nativeMap.\(layer.rawValue)")
        applyLayers()
        if layer == .nowcast { loadSeries() }
    }

    /// The layers button's menu: what the native map draws over the radar.
    func layerMenu() -> UIMenu {
        UIMenu(title: NSLocalizedString("map_layers", comment: ""), children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                guard let self else { return completion([]) }
                completion(Layer.allCases.map { layer in
                    UIAction(title: layer.title, image: UIImage(systemName: layer.symbol),
                             state: self.isOn(layer) ? .on : .off) { [weak self] _ in self?.toggle(layer) }
                })
            },
        ])
    }

    /// Reads the stored settings: palette, base map, rotation, deployment.
    func applySettings() {
        let palette = defaults?.string(forKey: "radarColorMapping") ?? "classic"
        if RadarLUT(palette: palette).name != store.paletteName {
            store.setPalette(palette)
            compositor.clear()
            radarRenderer?.setNeedsDisplay()
            schedulePrepare()
        }
        player.palette = RadarLUT(palette: palette).name
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
            store.setBase(next.tiles)
            socket.setHost(next.api)
            storms.setEndpoints(next)
            series = nil
            if started { wake() }
        }
        applyLayers()
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
    }

    private func applyLayers() {
        lightning.visible = isOn(.lightning)
        mesocyclones.visible = isOn(.mesocyclones)
        storms.visible = isOn(.storms) && onLiveStep
        updateCredits()
    }

    private var onLiveStep: Bool { player.step == nil || player.step == player.timeline.now }

    // MARK: - Radar

    private var radarRenderer: RadarRenderer? { mapView.renderer(for: overlay) as? RadarRenderer }

    private func loadSeries() {
        seriesTask?.cancel()
        seriesRetry?.invalidate()
        let point = userLocation
        let network = point.flatMap { coverage.network(at: MKMapPoint($0.coordinate)) }
        let url = endpoints.timeseries(latitude: point?.coordinate.latitude, longitude: point?.coordinate.longitude,
                                       network: network, nowcast: isOn(.nowcast))
        seriesLoaded = Date()
        seriesTask = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode
            let series = status == 200 ? data.flatMap { try? RadarSeries.decode($0) } : nil
            let cancelled = (error as? URLError)?.code == .cancelled
            Task { @MainActor in
                guard let self, !cancelled else { return }
                guard let series else {
                    // Once more soon, then the ticker keeps trying (core's recovery: 1 s, 4 s, …).
                    self.seriesRetry = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
                        Task { @MainActor in self?.loadSeries() }
                    }
                    return
                }
                self.series = series
                self.seriesPoint = point
                self.seriesNetwork = network
                self.compose()
            }
        }
        seriesTask?.resume()
    }

    private func compose() {
        guard let series else { return }
        let timeline = RadarTimeline(series: series, clock: Int(Date().timeIntervalSince1970), nowcast: isOn(.nowcast),
                                     network: seriesNetwork)
        player.setTimeline(timeline)
        if let time = pendingTime {
            pendingTime = nil
            player.show(time: time)
        }
        prefetch()
    }

    private func loadCoverage() {
        fetch(endpoints.coverage) { [weak self] data in
            guard let self, let coverage = RadarCoverage(json: data) else { return }
            self.coverage = coverage
            self.compositor.setCoverage(coverage)
            if let step = self.player.step { self.display(self.frame(for: step)) }
            self.radarRenderer?.setNeedsDisplay()
            self.schedulePrepare()
        }
    }

    private func showStep(_ step: Int) {
        let frame = frame(for: step)
        let showing = scene.frames.current
        // Playing waits for each step's pictures (`RadarPlayer.isReady`);
        // a scrubbed-to step that is not ready keeps the one on screen for
        // a moment, rather than changing tile by tile.
        if player.playing || showing.layers.isEmpty || frame == showing || isReady(frame) {
            display(frame)
        } else {
            heldFrame = frame
            heldIndex = player.index
            holdTimer?.invalidate()
            holdTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let held = self.heldFrame else { return }
                    self.display(held)
                }
            }
        }
        storms.visible = isOn(.storms) && onLiveStep
        updateOpacity()
        prepareAhead()
        prefetch()
    }

    /// Puts a step on screen: every tile of it in one redraw.
    private func display(_ frame: RadarFrameRef) {
        heldFrame = nil
        heldIndex = nil
        holdTimer?.invalidate()
        holdTimer = nil
        shownTiles = Set(frame.layers.map(\.tileId))
        if scene.show(frame) { radarRenderer?.setNeedsDisplay() }
        updateCredits()
    }

    private func frame(for step: Int) -> RadarFrameRef {
        RadarFrameRef(layers: player.timeline.layers[step] ?? [], coverage: coverage)
    }

    /// The tile zoom the map is drawn at.
    private var drawZoom: Int {
        scene.zoom ?? RadarTileKey.zoom(forScale: Double(mapView.bounds.width) / max(mapView.visibleMapRect.width, 1))
    }

    private func isReady(_ frame: RadarFrameRef) -> Bool {
        compositor.isReady(frame, zoom: drawZoom, in: mapView.visibleMapRect)
    }

    private func isReady(_ step: Int) -> Bool {
        isReady(frame(for: step))
    }

    /// Pictures were put together: a held step may be ready now.
    private func prepared() {
        if let held = heldFrame, isReady(held) { display(held) }
    }

    /// Puts the pictures of the steps coming up together ahead of time:
    /// while playing, in the order playing reaches them (core's
    /// `playbackLoop`); while paused, nearest first either side, for scrubbing.
    private func prepareAhead() {
        let steps = player.timeline.steps
        guard !steps.isEmpty, mapView.bounds.width > 0 else { return }
        let start = heldIndex ?? player.index
        var order = [start]
        if player.playing {
            var i = start
            while order.count < 10 {
                i = i + 1 < steps.count ? i + 1 : (player.nowIndex ?? 0)
                if order.contains(i) { break }
                order.append(i)
            }
        } else {
            for distance in 1 ..< steps.count where order.count < 14 {
                for i in [start + distance, start - distance] where steps.indices.contains(i) { order.append(i) }
            }
        }
        var seen = Set<String>()
        let frames = order.map { frame(for: steps[$0]) }.filter { seen.insert($0.key).inserted }
        // A margin around the view: MapKit draws a little past its edges.
        let visible = mapView.visibleMapRect
        compositor.prepare(frames, zoom: drawZoom, in: visible.insetBy(dx: -visible.width / 4, dy: -visible.height / 4))
    }

    /// Several arrivals in a row prepare once.
    private func schedulePrepare() {
        guard !prepareScheduled else { return }
        prepareScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                self?.prepareScheduled = false
                self?.prepareAhead()
            }
        }
    }

    private func tileArrived(_ key: RadarTileKey) {
        schedulePrepare()
        guard shownTiles.contains(key.tileId) else { return }
        radarRenderer?.setNeedsDisplay(key.mapRect)
    }

    /// The step on screen's tiles first, then the others nearest first
    /// (core's `precacheForecast`), at the zoom MapKit draws.
    private func prefetch() {
        let timeline = player.timeline
        guard !timeline.steps.isEmpty, mapView.bounds.width > 0 else { return }
        let visible = mapView.visibleMapRect
        let zoom = scene.zoom ?? RadarTileKey.zoom(forScale: Double(mapView.bounds.width) / visible.width)
        var plan: [RadarTileKey: Int] = [:]
        let order = timeline.steps.indices.sorted { abs($0 - player.index) < abs($1 - player.index) }
        for i in order {
            let distance = abs(i - player.index)
            for layer in timeline.layers[timeline.steps[i]] ?? [] {
                let z = max(RadarLayer.minZoom, min(zoom, layer.maxZoom))
                guard let range = RadarTileKey.range(z: z, covering: coverage.bounds(of: layer.clip).intersection(visible)) else { continue }
                for x in range.x {
                    for y in range.y where layer.index.has(z: z, x: x, y: y) {
                        let key = RadarTileKey(layer, z: z, x: x, y: y)
                        if plan[key] == nil { plan[key] = distance }
                    }
                }
            }
            if plan.count > 1200 { break }
        }
        store.replacePlan(plan)
    }

    /// 0.75 as core draws the radar; fainter while it is behind (core's
    /// `lib/freshness.ts`), so an old picture does not pass for the weather now.
    private func updateOpacity() {
        guard let renderer = radarRenderer else { return }
        let now = Int(Date().timeIntervalSince1970)
        let stale = player.timeline.now.map { now - $0 > 15 * 60 } ?? false
        renderer.alpha = stale ? 0.75 * 0.45 : 0.75
    }

    private static let networkCredits = [
        "ch": "MeteoSwiss", "fr": "Météo-France", "cz": "ČHMÚ", "pl": "IMGW-PIB", "be": "RMI, © VMM", "sk": "SHMÚ",
        "lt": "LHMT", "ee": "Keskkonnaagentuur", "ie": "Met Éireann (CC BY 4.0)", "hr": "DHMZ", "dk": "DMI",
        "nl": "KNMI", "fi": "FMI", "se": "SMHI", "no": "MET Norway",
    ]

    /// Who the data on screen is from, as core credits each visible layer.
    private func updateCredits() {
        let visible = mapView.visibleMapRect
        var names: [String] = []
        for layer in scene.frames.current.layers where coverage.bounds(of: layer.clip).intersects(visible) {
            if layer.key == "de" { names.insert("DWD", at: 0) } else if let name = Self.networkCredits[layer.key] { names.append(name) }
        }
        if isOn(.lightning) { names.append("Blitzortung.org") }
        player.credits = names.isEmpty ? "" : "© " + names.joined(separator: ", © ")
    }

    // MARK: - Socket

    private func socketEvent(_ name: String, _ data: Data) {
        switch name {
        case "poke":
            let refresh = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["refresh"] as? String
            if refresh == "radar" || refresh == "nowcast" { scheduleRefresh(after: 1) }
        case "nowcast":
            if isOn(.nowcast) { scheduleRefresh(after: 2) }
        case "network":
            // A network's new composite: the live step's, fetched with the
            // next series rather than on its own.
            scheduleRefresh(after: 30)
        case "lightning":
            lightning.add(data)
        case "mesocyclones":
            mesocyclones.load(data)
        case "storms":
            storms.refresh(force: true)
        default:
            break
        }
    }

    /// Several nudges in a row fetch the series once.
    private func scheduleRefresh(after delay: TimeInterval) {
        let due = Date().addingTimeInterval(delay)
        if let refreshAt, refreshAt <= due { return }
        refreshAt = due
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAt = nil
                self?.loadSeries()
            }
        }
    }

    private func fetch(_ url: URL, _ handler: @escaping @MainActor (Data) -> Void) {
        URLSession.shared.dataTask(with: url) { data, response, _ in
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data else { return }
            Task { @MainActor in handler(data) }
        }.resume()
    }

    // MARK: - The host's calls

    /// The user's position from the location button, as core's
    /// `lm.updateLocation`: `zoom` zooms in by the fix's accuracy, `focus`
    /// centres on it. Nil hides the dot.
    func showLocation(_ location: CLLocation?, zoom: Bool, focus: Bool) {
        mapView.showsUserLocation = location != nil
        userLocation = location
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
        // The bars show the rain at the user's position: ask again once it is known or has moved.
        if seriesPoint.map({ $0.distance(from: location) > 2000 }) ?? true, started { loadSeries() }
    }

    /// Back to the live radar, as the logo does on the web map.
    func showLive() {
        player.showLive()
    }

    /// A link's view and frame (core's `latLonZ` and `t`).
    func open(search: String) {
        guard let link = NativeMapLink(search: search) else { return }
        if placed { place(link, animated: true) } else { pendingView = link }
        if let time = link.time {
            if player.timeline.steps.isEmpty { pendingTime = time } else { player.show(time: time) }
        } else {
            player.showLive()
        }
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

    private func place(_ link: NativeMapLink, animated: Bool) {
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
        if let radar = overlay as? RadarOverlay {
            let renderer = RadarRenderer(radar: radar)
            renderer.alpha = 0.75
            return renderer
        }
        if overlay is LightningOverlay {
            return LightningRenderer(overlay: overlay)
        }
        if let path = overlay as? StormPath {
            return StormMarks.renderer(for: path, dark: traitCollection.userInterfaceStyle == .dark)
        }
        return MKOverlayRenderer(overlay: overlay)
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        switch annotation {
        case is MesocycloneAnnotation:
            return mapView.dequeueReusableAnnotationView(withIdentifier: MesocycloneView.reuse, for: annotation)
        case is StormAnnotation:
            return mapView.dequeueReusableAnnotationView(withIdentifier: StormView.reuse, for: annotation)
        default:
            return nil
        }
    }

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        storms.zoom = zoomLevel
        storms.refresh()
        prefetch()
        prepareAhead()
        updateCredits()
    }
}
