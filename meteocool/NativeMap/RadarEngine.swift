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
    /// Called when the chosen product has no frame at all (`givesUpChoice`).
    var onGaveUp: ((RadarProduct) -> Void)?
    /// The radar is out of date: drawn fainter (`STALE_OPACITY`).
    var stale = false { didSet { updateOpacity() } }
    /// A storm is selected: the radar steps back (`INSPECT_OPACITY`).
    var dimmed = false { didSet { updateOpacity() } }
    /// A radar is open in its own sweep: the composites step back under it.
    var siteDimmed = false { didSet { updateOpacity() } }
    /// The newest observation's build time and the learned cadence, for the
    /// pill's "publish cadence" rule.
    private(set) var processedTimes: (newest: Int?, cadence: Int?) = (nil, nil)

    private weak var mapView: MKMapView?
    private var endpoints: NativeMapEndpoints
    private let store: RadarTileStore
    private let compositor: RadarCompositor
    private let scene: RadarScene

    /// The observed picture chosen (`radarProduct`): its past comes with the
    /// series, asked for by name.
    var product = RadarProduct.hx {
        didSet {
            guard product != oldValue else { return }
            if product.timeseriesProducts != seriesProducts { load() } else { compose() }
        }
    }
    private var seriesProducts: [String] = []
    /// The point the series' readings are for: the user's position or a
    /// long-pressed point (that wins, as in core).
    var point: CLLocationCoordinate2D? {
        didSet {
            guard let point else { return }
            // Against the series held, or the one on its way: a stream of
            // location fixes must not cancel the first request over and over.
            if (seriesPoint ?? requestedPoint).map({ CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                .distance(from: CLLocation(latitude: point.latitude, longitude: point.longitude)) > 2000 }) ?? true {
                load()
            }
        }
    }
    private(set) var series: RadarSeries?
    private var seriesTask: URLSessionDataTask?
    private(set) var seriesLoaded = Date.distantPast
    private var seriesPoint: CLLocationCoordinate2D?
    /// The point of the request on its way.
    private var requestedPoint: CLLocationCoordinate2D?
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
            scheduleRefresh(after: 2)
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
        let point = self.point
        let network = point.flatMap { coverage.network(at: MKMapPoint($0)) }
        let products = product.timeseriesProducts
        let url = endpoints.timeseries(latitude: point?.latitude, longitude: point?.longitude,
                                       network: network, products: products)
        // The same question already on its way (a wake, a reconnect, a fix
        // a few metres on) is left to answer rather than asked again: asked
        // again and again, as a flapping socket would, it never answers.
        if let seriesTask, seriesTask.state == .running, seriesTask.originalRequest?.url == url { return }
        seriesTask?.cancel()
        seriesRetry?.invalidate()
        seriesLoaded = Date()
        requestedPoint = point
        // A stalled answer is asked again soon rather than after a minute.
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        seriesTask = URLSession.meteocool.dataTask(with: request) { [weak self] data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode
            let series = Self.forTests(status == 200 ? data.flatMap { try? RadarSeries.decode($0) } : nil)
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
                self.seriesProducts = products
                let built = series.frames.values.compactMap { $0 }.filter(\.isObservation).map(\.processedTime)
                self.processedTimes = (built.max(), ConnectionRules.cadence(processedTimes: built))
                self.compose()
                self.onSeries?(series)
                if self.product == .merged || self.product == .colmax,
                   series.products?[self.product.rawValue]?.isEmpty ?? true {
                    self.onGaveUp?(self.product)
                }
            }
        }
        seriesTask?.resume()
    }

    /// The series as UI tests want it: without the networks' nowcasts
    /// (`MC_NO_NOWCAST`), as a run that has not come in would leave it.
    nonisolated private static func forTests(_ series: RadarSeries?) -> RadarSeries? {
        #if DEBUG
        if ProcessInfo.processInfo.environment["MC_NO_NOWCAST"] != nil, let all = series {
            return RadarSeries(frames: all.frames, networks: all.networks,
                               products: all.products?.filter { !$0.key.hasPrefix("nowcast_") },
                               serverTime: all.serverTime, replay: all.replay)
        }
        #endif
        return series
    }

    private func compose() {
        guard let series else { return }
        let timeline = RadarTimeline(series: series, clock: Int(Date().timeIntervalSince1970),
                                     network: seriesNetwork, product: product)
        player.setTimeline(timeline)
        updatePreloaded()
        if let time = pendingTime {
            pendingTime = nil
            player.show(time: time)
        }
        prefetch()
        updateOpacity()
    }

    private func loadCoverage() {
        URLSession.meteocool.dataTask(with: endpoints.coverage) { [weak self] data, response, _ in
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

    /// The step on screen (the newest when there is none yet) as one
    /// picture of `rect`, `pixels` square, for the 3D map's ground. Nil while
    /// tiles it needs are still loading: they are asked for, so try again.
    func drape(_ rect: MKMapRect, pixels: Int, completion: @escaping @MainActor (CGImage?) -> Void) {
        guard let step = player.step ?? player.timeline.now, rect.width > 0, rect.width.isFinite, rect.minX.isFinite, rect.minY.isFinite
        else { return completion(nil) }
        let frame = self.frame(for: step)
        let compositor = self.compositor
        // As many tiles across as the picture has room for at their own size.
        let wanted = Int((log2(MKMapSize.world.width * Double(pixels) / (512 * rect.width))).rounded())
        let z = frame.zoom(for: max(RadarLayer.minZoom, wanted))
        DispatchQueue.global(qos: .userInitiated).async {
            var images: [(CGImage, MKMapRect)] = []
            var pending = false
            for tile in frame.tiles(z: z, in: rect) {
                switch compositor.picture(frame, z: z, x: tile.x, y: tile.y, priority: 1) {
                case .image(let image): images.append((image, RadarTileKey.mapRect(z: z, x: tile.x, y: tile.y)))
                case .empty: break
                case .pending: pending = true
                }
            }
            var picture: CGImage?
            if !pending, let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                // Map points, rows down, as the overlay draws them.
                let scale = Double(pixels) / rect.width
                context.translateBy(x: 0, y: CGFloat(pixels))
                context.scaleBy(x: scale, y: -scale)
                context.translateBy(x: -rect.minX, y: -rect.minY)
                context.interpolationQuality = .none
                for (image, tileRect) in images { RadarCompositor.drawTile(image, in: tileRect, context: context) }
                picture = context.makeImage()
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(picture) } }
        }
    }

    func frame(for step: Int) -> RadarFrameRef {
        RadarFrameRef(layers: player.timeline.layers[step] ?? [], coverage: coverage)
    }

    /// The tile zoom the map is drawn at. A map launched in the background
    /// is not laid out yet: no width, no scale.
    private var drawZoom: Int {
        guard let mapView, mapView.visibleMapRect.width > 0, mapView.bounds.width > 0 else { return 6 }
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
        updatePreloaded()
    }

    /// Which steps are ready to show, for the strip's preload fill.
    private func updatePreloaded() {
        let timeline = player.timeline
        let ready = Set(timeline.steps.filter { timeline.isPlayable($0) && !(timeline.layers[$0]?.isEmpty ?? true) && isReady($0) })
        if ready != player.preloaded { player.preloaded = ready }
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
        guard visible || underlay else { return 0 }
        // Under the lightning map's strikes (`RAIN_UNDERLAY_OPACITY`).
        if !visible { return 0.3 }
        return 0.75 * (stale ? 0.45 : 1) * (dimmed ? 0.55 : 1) * (siteDimmed ? SiteSweeps.compositeDim : 1)
    }

    private func updateOpacity() {
        renderer?.alpha = opacity
    }

    /// Hides or shows the radar, for maps that draw something else.
    var visible = true {
        didSet { updateOpacity() }
    }

    /// Faint, under another map (the lightning map's rain).
    var underlay = false {
        didSet { updateOpacity() }
    }

    private static let networkCredits = [
        "ch": "MeteoSwiss", "fr": "Météo-France", "cz": "ČHMÚ", "pl": "IMGW-PIB", "be": "RMI, © VMM", "sk": "SHMÚ",
        "lt": "LHMT", "ee": "Keskkonnaagentuur", "ie": "Met Éireann (CC BY 4.0)", "hr": "DHMZ", "dk": "DMI",
        "nl": "KNMI", "fi": "FMI", "se": "SMHI", "no": "MET Norway",
    ]

    /// Who a network's radar is from.
    static func credit(network: String) -> String? {
        network == "de" ? "DWD" : networkCredits[network]
    }

    /// Who the radar on screen is from, as core credits each visible layer.
    func credits(in visible: MKMapRect) -> [String] {
        var names: [String] = []
        for layer in shownLayers where coverage.bounds(of: layer.clip).intersects(visible) {
            if layer.key == "de" { names.insert("DWD", at: 0) } else if let name = Self.networkCredits[layer.key] { names.append(name) }
        }
        return names
    }
}
