//
//  RadarEngine.swift
//  meteocool
//
//  The radar composite on the native map: the series, its steps, and the
//  tiles and pictures each step needs.
//

import MapKit
import UIKit

/// Loads `/v3/radar/timeseries`, turns it into steps (`RadarTimeline`),
/// and keeps the overlay on the step the player is on, each step's pictures
/// prepared before it is shown (`RadarCompositor`).
@MainActor
final class RadarEngine {
    let player: RadarPlayer
    let overlay: RadarOverlay
    private(set) var coverage: RadarCoverage
    /// Called after a step was put on screen.
    var onStep: ((Int) -> Void)?
    /// Called when the series was loaded again.
    var onSeries: ((RadarSeries) -> Void)?

    private weak var mapView: MKMapView?
    private var endpoints: NativeMapEndpoints
    private let store: RadarTileStore
    private let compositor: RadarCompositor
    private let scene: RadarScene

    /// Whether core's own nowcast is drawn on forecast steps (`meteocoolNowcast`).
    var nowcast = true {
        didSet { if nowcast != oldValue { load() } }
    }
    /// The point the series' readings are for: the user's position or a
    /// long-pressed point (that wins, as in core).
    var point: CLLocationCoordinate2D? {
        didSet {
            guard let point else { return }
            if seriesPoint.map({ CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                .distance(from: CLLocation(latitude: point.latitude, longitude: point.longitude)) > 2000 }) ?? true {
                load()
            }
        }
    }
    private(set) var series: RadarSeries?
    private var seriesTask: URLSessionDataTask?
    private(set) var seriesLoaded = Date.distantPast
    private var seriesPoint: CLLocationCoordinate2D?
    private var seriesNetwork: String?
    private var seriesRetry: Timer?
    private var refreshAt: Date?
    private var refreshTimer: Timer?
    private var pendingTime: Int?
    private var running = false

    /// The tiles of the step on screen, whose arrival redraws.
    private var shownTiles = Set<String>()
    /// A step scrubbed to whose pictures are not all ready: the step on
    /// screen stays until they are, then the whole map changes at once.
    private var heldFrame: RadarFrameRef?
    private var heldIndex: Int?
    private var holdTimer: Timer?
    private var prepareScheduled = false

    init(mapView: MKMapView, endpoints: NativeMapEndpoints, palette: String) {
        self.mapView = mapView
        self.endpoints = endpoints
        player = RadarPlayer()
        store = RadarTileStore(base: endpoints.tiles, palette: palette)
        let coverage = RadarCoverage.bundled()
        self.coverage = coverage
        compositor = RadarCompositor(store: store, coverage: coverage)
        scene = RadarScene(compositor: compositor)
        overlay = RadarOverlay(scene: scene)
        player.palette = RadarLUT(palette: palette).name

        store.onTile = { [weak self] key in self?.tileArrived(key) }
        player.onStep = { [weak self] step in self?.showStep(step) }
        player.isReady = { [weak self] step in self?.isReady(step) ?? true }
        compositor.onPrepared = { [weak self] in self?.prepared() }
        compositor.onBuilt = { [weak self] frame, rect in
            guard let self, self.scene.frames.current == frame else { return }
            self.renderer?.setNeedsDisplay(rect)
        }
    }

    var renderer: RadarRenderer? { mapView?.renderer(for: overlay) as? RadarRenderer }

    /// The radar's renderer, for the map's delegate.
    func makeRenderer() -> RadarRenderer {
        let renderer = RadarRenderer(radar: overlay)
        renderer.alpha = opacity
        return renderer
    }

    /// The layers on screen, for credits and the readings.
    var shownLayers: [RadarLayer] { scene.frames.current.layers }

    // MARK: - Lifecycle

    func start() {
        running = true
    }

    func stop() {
        running = false
        player.pause()
        refreshTimer?.invalidate()
        refreshTimer = nil
        refreshAt = nil
        seriesRetry?.invalidate()
        seriesTask?.cancel()
    }

    func wake() {
        load()
        loadCoverage()
    }

    func tick() {
        // The socket's pokes keep the series fresh; this is for when it is down.
        if Date().timeIntervalSince(seriesLoaded) > 180 { load() }
        updateOpacity()
    }

    func setEndpoints(_ next: NativeMapEndpoints) {
        guard next != endpoints else { return }
        endpoints = next
        store.setBase(next.tiles)
        series = nil
        if running { wake() }
    }

    func setPalette(_ palette: String) {
        guard RadarLUT(palette: palette).name != store.paletteName else { return }
        store.setPalette(palette)
        compositor.clear()
        player.palette = RadarLUT(palette: palette).name
        renderer?.setNeedsDisplay()
        schedulePrepare()
    }

    /// A link's frame (core's `t=`), once the steps are there.
    func show(time: Int?) {
        guard let time else { return player.showLive() }
        if player.timeline.steps.isEmpty { pendingTime = time } else { player.show(time: time) }
    }

    /// The socket's nudges about the radar; true when handled.
    @discardableResult
    func socketEvent(_ name: String, _ data: Data) -> Bool {
        switch name {
        case "poke":
            let refresh = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["refresh"] as? String
            if refresh == "radar" || refresh == "nowcast" { scheduleRefresh(after: 1) }
        case "nowcast":
            if nowcast { scheduleRefresh(after: 2) }
        case "network":
            // A network's new composite: the live step's, fetched with the
            // next series rather than on its own.
            scheduleRefresh(after: 30)
        default:
            return false
        }
        return true
    }

    func regionDidChange() {
        prefetch()
        prepareAhead()
    }

    // MARK: - Series

    func load() {
        seriesTask?.cancel()
        seriesRetry?.invalidate()
        let point = self.point
        let network = point.flatMap { coverage.network(at: MKMapPoint($0)) }
        let url = endpoints.timeseries(latitude: point?.latitude, longitude: point?.longitude,
                                       network: network, nowcast: nowcast)
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
                        Task { @MainActor in self?.load() }
                    }
                    return
                }
                self.series = series
                self.seriesPoint = point
                self.seriesNetwork = network
                self.compose()
                self.onSeries?(series)
            }
        }
        seriesTask?.resume()
    }

    private func compose() {
        guard let series else { return }
        let timeline = RadarTimeline(series: series, clock: Int(Date().timeIntervalSince1970), nowcast: nowcast,
                                     network: seriesNetwork)
        player.setTimeline(timeline)
        if let time = pendingTime {
            pendingTime = nil
            player.show(time: time)
        }
        prefetch()
        updateOpacity()
    }

    private func loadCoverage() {
        URLSession.shared.dataTask(with: endpoints.coverage) { [weak self] data, response, _ in
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data, let coverage = RadarCoverage(json: data) else { return }
            Task { @MainActor in
                guard let self else { return }
                self.coverage = coverage
                self.compositor.setCoverage(coverage)
                if let step = self.player.step { self.display(self.frame(for: step)) }
                self.renderer?.setNeedsDisplay()
                self.schedulePrepare()
            }
        }.resume()
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
                self?.load()
            }
        }
    }

    // MARK: - Steps

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
        updateOpacity()
        prepareAhead()
        prefetch()
        onStep?(step)
    }

    /// Puts a step on screen: every tile of it in one redraw.
    private func display(_ frame: RadarFrameRef) {
        heldFrame = nil
        heldIndex = nil
        holdTimer?.invalidate()
        holdTimer = nil
        shownTiles = Set(frame.layers.map(\.tileId))
        if scene.show(frame) { renderer?.setNeedsDisplay() }
    }

    func frame(for step: Int) -> RadarFrameRef {
        RadarFrameRef(layers: player.timeline.layers[step] ?? [], coverage: coverage)
    }

    /// The tile zoom the map is drawn at.
    private var drawZoom: Int {
        guard let mapView, mapView.visibleMapRect.width > 0 else { return 6 }
        return scene.zoom ?? RadarTileKey.zoom(forScale: Double(mapView.bounds.width) / mapView.visibleMapRect.width)
    }

    private func isReady(_ frame: RadarFrameRef) -> Bool {
        guard let mapView else { return true }
        return compositor.isReady(frame, zoom: drawZoom, in: mapView.visibleMapRect)
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
        guard !steps.isEmpty, let mapView, mapView.bounds.width > 0 else { return }
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
        renderer?.setNeedsDisplay(key.mapRect)
    }

    /// The step on screen's tiles first, then the others nearest first
    /// (core's `precacheForecast`), at the zoom MapKit draws.
    private func prefetch() {
        let timeline = player.timeline
        guard !timeline.steps.isEmpty, let mapView, mapView.bounds.width > 0 else { return }
        let visible = mapView.visibleMapRect
        let zoom = drawZoom
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

    // MARK: - Look

    /// 0.75 as core draws the radar; fainter while it is behind (core's
    /// `lib/freshness.ts`), so an old picture does not pass for the weather now.
    private var opacity: CGFloat {
        let now = Int(Date().timeIntervalSince1970)
        let stale = player.timeline.now.map { now - $0 > 15 * 60 } ?? false
        return stale ? 0.75 * 0.45 : 0.75
    }

    private func updateOpacity() {
        renderer?.alpha = opacity
    }

    /// Hides or shows the radar, for maps that draw something else.
    var visible = true {
        didSet { renderer?.alpha = visible ? opacity : 0 }
    }

    private static let networkCredits = [
        "ch": "MeteoSwiss", "fr": "Météo-France", "cz": "ČHMÚ", "pl": "IMGW-PIB", "be": "RMI, © VMM", "sk": "SHMÚ",
        "lt": "LHMT", "ee": "Keskkonnaagentuur", "ie": "Met Éireann (CC BY 4.0)", "hr": "DHMZ", "dk": "DMI",
        "nl": "KNMI", "fi": "FMI", "se": "SMHI", "no": "MET Norway",
    ]

    /// Who the radar on screen is from, as core credits each visible layer.
    func credits(in visible: MKMapRect) -> [String] {
        var names: [String] = []
        for layer in shownLayers where coverage.bounds(of: layer.clip).intersects(visible) {
            if layer.key == "de" { names.insert("DWD", at: 0) } else if let name = Self.networkCredits[layer.key] { names.append(name) }
        }
        return names
    }
}
