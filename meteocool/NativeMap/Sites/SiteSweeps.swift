//
//  SiteSweeps.swift
//  meteocool
//
//  Site mode, end to end (core's `lib/SiteSweepManager.ts`): the radar
//  marks, the open radar's sweep for the step on screen, the rings of beam
//  height, and what the tray and the long press read of it.
//

import Combine
import MapKit

/// What site mode is showing, for the tray.
struct SiteSweepView: Equatable {
    enum Status: Equatable { case loading, shown, none, failed }

    let site: ListedSite
    let tilts: [OfferedTilt]
    /// Whether the site published velocity lately, so V and SRV are offered.
    let hasVelocity: Bool
    let status: Status
    /// The drawn sweep's own scan, Nyquist and dealiasing, as its header says.
    var startedAt: String?
    var scannedAt: String?
    var nyquist: Double?
    var dealiased: Bool?
    var dealiaser: String?
    /// What SRV takes out, and whose it is.
    var srv = SrvMotion(source: .manual, motion: SrvMotionRules.motion(of: SrvMotionRules.defaultMotion))
    /// Whether a selected storm says how it moves, so its motion is on offer.
    var stormMoves = false
    /// The selected storm, as the motion's row names it.
    var stormName: String?
}

/// Site mode's state: what is open (set by a mark and by the tray), and
/// what is shown of it (written by `SiteSweeps` only).
@MainActor
final class SiteSweepState: ObservableObject {
    @Published var mode: SiteMode?
    /// The motion set by hand on the dial, kept (core's `srvMotion` setting).
    @Published var manual = SrvMotionRules.parse(SiteSweepState.defaults?.string(forKey: SiteSweepState.manualKey)) {
        didSet { SiteSweepState.defaults?.set(SrvMotionRules.format(manual), forKey: SiteSweepState.manualKey) }
    }
    /// The reader asked for their own motion over the selected storm's.
    @Published var prefersManual = false
    /// The motion's dial and stepper are open in the card.
    @Published var motionOpen = false

    private static let manualKey = "nativeMap.srvMotion"
    private static let defaults = UserDefaults(suiteName: "group.org.frcy.app.meteocool")

    /// Sets the motion by hand, from the one SRV takes out now; a storm's
    /// motion turned on the dial becomes the reader's own.
    func editMotion(heading: Double? = nil, speed: Double? = nil) {
        guard let srv = view?.srv else { return }
        let base = SrvMotionRules.editBase(srv, manual: manual)
        manual = ManualMotion(headingDeg: heading ?? base.headingDeg, speedKmh: SrvMotionRules.clampSpeed(speed ?? base.speedKmh))
        if srv.source == .storm { prefersManual = true }
    }
    @Published fileprivate(set) var view: SiteSweepView?
    fileprivate var reader: ((CLLocationCoordinate2D) -> ReadingParts?)?
    fileprivate var opener: ((String) -> Void)?

    /// Opens a radar's own sweeps on the flat map, as its mark does.
    func open(_ code: String) {
        opener?(code)
    }

    /// What the open sweep holds at a point, for the long press; nil
    /// outside it or with none open.
    func read(_ coordinate: CLLocationCoordinate2D) -> ReadingParts? {
        mode == nil ? nil : reader?(coordinate)
    }

    func close() {
        mode = nil
    }
}

@MainActor
final class SiteSweeps: NativeMapFeature {
    /// Below this the marks are clutter: a whole network fits in a thumb's width.
    static let minZoom = 6.0
    /// How strongly the composites are drawn under an open radar's sweep,
    /// and only while one is drawn: in grey there, they no longer mix with
    /// its colours, so they keep most of their structure.
    static let compositeDim = 0.6
    /// Sweeps kept decoded: a step's, the three ahead, and a few behind.
    private static let kept = 16

    private weak var map: NativeMapContext?
    private let overlay = SiteSweepOverlay()
    /// The selected storm's motion, for storm-relative velocity.
    private let motion: () -> StormMotion?
    /// Whether a tap lands on a storm, which a tap past the reach leaves to it.
    private let hitsStorm: (CGPoint) -> Bool

    private var marks: [String: RadarSiteAnnotation] = [:]
    /// The open site as `/sweeps?site=` last answered, newer than the viewport's listing.
    private var openSite: ListedSite?
    private var shown: (scan: ListedScan, sweep: Sweep)?
    /// The open site's last sweep drawn, kept through a step with none: how far it reaches.
    private var reach: (geometry: SweepGeometry, groundM: Double)?
    /// Bumped on every redraw, so a sweep that lands after the reader moved on is not drawn.
    private var generation = 0
    private var listedBox: String?
    private var sweeps: [String: Sweep] = [:]
    private var used: [String] = []
    private var loading: [String: [(Sweep?) -> Void]] = [:]
    private var rings: [BeamRing] = []
    private var ringLabels: [BeamRingLabel] = []
    private var ringsKey = ""
    private var step = RadarStep(time: nil, isLive: true, isForecast: false)
    private var overlayAdded = false
    private var observers = Set<AnyCancellable>()

    /// The selected storm's name: its place, else its strength.
    private let stormName: () -> String?

    init(motion: @escaping () -> StormMotion?, stormName: @escaping () -> String? = { nil }, hitsStorm: @escaping (CGPoint) -> Bool) {
        self.motion = motion
        self.stormName = stormName
        self.hitsStorm = hitsStorm
    }

    private var state: SiteSweepState? { map?.model.site }
    /// What SRV takes out: the selected storm's motion, or the reader's own.
    private var srv: SrvMotion {
        SrvMotionRules.resolve(storm: motion(), manual: state?.manual ?? SrvMotionRules.defaultMotion,
                               prefersManual: state?.prefersManual ?? false)
    }
    private var marksShown: Bool {
        guard let map else { return false }
        return map.isOn(.sites) && map.model.capability == .radar && map.zoomLevel > Self.minZoom
    }

    func attach(to map: NativeMapContext) {
        self.map = map
        map.mapView.register(RadarSiteMarkView.self, forAnnotationViewWithReuseIdentifier: RadarSiteMarkView.reuse)
        map.mapView.register(BeamRingLabelView.self, forAnnotationViewWithReuseIdentifier: BeamRingLabelView.reuse)
        map.model.site.reader = { [weak self] coordinate in self?.readAt(coordinate) }
        map.model.site.opener = { [weak self] code in
            // Site mode is the flat radar map's.
            if self?.map?.model.capability != .radar { self?.map?.setCapability(.radar) }
            self?.open(code)
        }
        map.model.site.$mode
            .removeDuplicates()
            .sink { [weak self] mode in DispatchQueue.main.async { self?.modeChanged(mode) } }
            .store(in: &observers)
        // SRV takes the selected storm's motion out; its details may come later.
        Publishers.Merge(map.model.$selectedStorm.map { _ in () }, map.model.$opened.map { _ in () })
            .sink { [weak self] in DispatchQueue.main.async { self?.redraw() } }
            .store(in: &observers)
        // The dial turned: the sweep on screen drawn again, nothing fetched.
        Publishers.Merge(map.model.site.$manual.dropFirst().map { _ in () }, map.model.site.$prefersManual.dropFirst().map { _ in () })
            .sink { [weak self] in DispatchQueue.main.async { self?.redraw() } }
            .store(in: &observers)
        map.model.$isDark
            .removeDuplicates()
            .sink { [weak self] dark in DispatchQueue.main.async { self?.appearanceChanged(dark) } }
            .store(in: &observers)
    }

    // MARK: - Hooks

    func renderer(for overlay: MKOverlay) -> MKOverlayRenderer? {
        if overlay === self.overlay { return SiteSweepRenderer(sweep: self.overlay) }
        if let ring = overlay as? BeamRing { return BeamRings.renderer(ring) }
        return nil
    }

    func view(for annotation: MKAnnotation, in mapView: MKMapView) -> MKAnnotationView? {
        if annotation is RadarSiteAnnotation {
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: RadarSiteMarkView.reuse, for: annotation) as? RadarSiteMarkView
            view?.setDark(map?.model.isDark ?? false)
            view?.update()
            return view
        }
        if annotation is BeamRingLabel {
            return mapView.dequeueReusableAnnotationView(withIdentifier: BeamRingLabelView.reuse, for: annotation)
        }
        return nil
    }

    /// A radar's mark opens it, before anything under it.
    func didSelect(_ annotation: MKAnnotation) -> Bool {
        guard let mark = annotation as? RadarSiteAnnotation else { return false }
        map?.mapView.deselectAnnotation(annotation, animated: false)
        open(mark.site.site)
        return true
    }

    /// With a radar open, a tap past its reach that hits no storm closes it,
    /// and only it: the storm a storm-relative sweep is read against stays.
    func didTap(at coordinate: CLLocationCoordinate2D, point: CGPoint) -> Bool {
        guard let state, state.mode != nil, !reaches(coordinate), !hitsStorm(point) else { return false }
        state.close()
        return true
    }

    func regionDidChange() {
        updateMarks()
    }

    func stepDidChange(_ step: RadarStep) {
        guard step != self.step else { return }
        self.step = step
        redraw()
    }

    func wake() {
        listedBox = nil
        updateMarks()
        if let code = state?.mode?.site {
            refreshOpenSite(code) { [weak self] in self?.redraw() }
        }
    }

    /// A radar published new sweeps: the open one's are fetched again.
    func socketEvent(_ name: String, _ data: Data) {
        guard name == "sweeps",
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = event["site"] as? String, code == state?.mode?.site else { return }
        refreshOpenSite(code) { [weak self] in self?.redraw() }
    }

    func settingsDidChange() {
        guard let map else { return }
        if !map.isOn(.sites) { state?.close() }
        updateMarks()
        // The reader's palette may have changed.
        redraw()
    }

    /// A link to a radar (`radar=`, `sweep=`, `tilt=`) opens it, on the
    /// radar map; with no view of its own, the radar's reach in view.
    func open(_ link: [String: String]) -> Bool {
        guard let map, let mode = SiteSweepRules.fromLink(radar: link["radar"], sweep: link["sweep"], tilt: link["tilt"]) else { return false }
        if map.model.capability != .radar { map.setCapability(.radar) }
        if link["latLonZ"] == nil, let site = RadarSites.site(mode.site) {
            map.place(NativeMapLink(latitude: site.lat, longitude: site.lon, zoom: Self.linkZoom), animated: false)
        }
        state?.mode = mode
        return false
    }

    /// The open radar, for a link to the map on screen.
    func linkParameters() -> [String: String] {
        guard map?.model.capability == .radar, let mode = state?.mode else { return [:] }
        return SiteSweepRules.toLink(mode)
    }

    /// Where a link to a radar opens when it does not say: its whole reach in view.
    static let linkZoom = 7.0

    /// Site mode is the radar map's.
    func capabilityDidChange(_ capability: NativeMapModel.Capability) {
        if capability != .radar { state?.close() }
        updateMarks()
    }

    // MARK: - Marks

    private func updateMarks() {
        guard let map else { return }
        guard marksShown else {
            if !marks.isEmpty {
                map.mapView.removeAnnotations(Array(marks.values))
                marks = [:]
            }
            listedBox = nil
            return
        }
        let rect = map.mapView.visibleMapRect
        let northWest = MKMapPoint(x: rect.minX, y: rect.minY).coordinate
        let southEast = MKMapPoint(x: rect.maxX, y: rect.maxY).coordinate
        let box = [northWest.longitude, southEast.latitude, southEast.longitude, northWest.latitude]
            .map { String(format: "%.3f", $0) }.joined(separator: ",")
        guard box != listedBox else { return }
        listedBox = box
        map.fetch(map.endpoints.sweeps(bbox: box)) { [weak self] data, _ in
            guard let self, self.listedBox == box, self.marksShown, let data,
                  let listing = try? JSONDecoder().decode(SweepListing.self, from: data) else { return }
            var sites = listing.sites ?? []
            // The open site stays listed while the reader pans away from it.
            if let open = self.openSite, !sites.contains(where: { $0.site == open.site }) { sites.append(open) }
            self.setSites(sites)
        }
    }

    private func setSites(_ sites: [ListedSite]) {
        guard let map else { return }
        let wanted = Dictionary(sites.map { ($0.site, $0) }) { first, _ in first }
        let gone = marks.filter { wanted[$0.key] != $0.value.site }
        map.mapView.removeAnnotations(Array(gone.values))
        for code in gone.keys { marks[code] = nil }
        let open = state?.mode?.site
        var added: [RadarSiteAnnotation] = []
        for (code, site) in wanted where marks[code] == nil {
            let mark = RadarSiteAnnotation(site)
            mark.open = code == open
            marks[code] = mark
            added.append(mark)
        }
        map.mapView.addAnnotations(added)
    }

    private func markOpen(_ code: String?) {
        guard let mapView = map?.mapView else { return }
        for (site, mark) in marks where mark.open != (site == code) {
            mark.open = site == code
            (mapView.view(for: mark) as? RadarSiteMarkView)?.update()
        }
    }

    private func appearanceChanged(_ dark: Bool) {
        guard let mapView = map?.mapView else { return }
        for mark in marks.values { (mapView.view(for: mark) as? RadarSiteMarkView)?.setDark(dark) }
        overlay.scene.setDark(dark)
        if overlayAdded { mapView.renderer(for: overlay)?.setNeedsDisplay() }
        greyComposites()
        ringsKey = ""
        if let shown { showRings(shown.sweep.header.geometry) }
    }

    // MARK: - Opening and closing

    /// Opens a radar: reflectivity at its lowest tilt, or what was open if
    /// it is the same radar, with the player taken back to now.
    func open(_ code: String) {
        guard let state, let map else { return }
        let current = state.mode
        if current?.site == code { return }
        let lowest = marks[code].map { SiteSweepRules.listed($0.site, .reflectivity).map(\.elevationDeg).min() ?? 0 } ?? 0
        state.mode = SiteMode(site: code, quantity: current?.quantity ?? .reflectivity, elevation: lowest)
    }

    /// Whether a point is inside the open radar's reach, as its last sweep drawn covered it.
    func reaches(_ coordinate: CLLocationCoordinate2D) -> Bool {
        guard state?.mode != nil, let reach else { return false }
        return SweepGeometryRules.fromSite(lon: reach.geometry.lon, lat: reach.geometry.lat,
                                           lon: coordinate.longitude, lat: coordinate.latitude).groundM <= reach.groundM
    }

    private func modeChanged(_ mode: SiteMode?) {
        guard let map else { return }
        markOpen(mode?.site)
        guard let mode else {
            openSite = nil
            shown = nil
            reach = nil
            sweeps = [:]
            used = []
            generation += 1
            show(nil)
            clearRings()
            state?.view = nil
            map.player.only = nil
            return
        }
        if openSite?.site != mode.site {
            openSite = marks[mode.site]?.site
            shown = nil
            reach = nil
            sweeps = [:]
            used = []
            redraw()
            refreshOpenSite(mode.site) { [weak self] in self?.redraw() }
        } else {
            redraw()
        }
    }

    private func refreshOpenSite(_ code: String, then: @escaping () -> Void) {
        guard let map else { return }
        map.fetch(map.endpoints.sweeps(site: code)) { [weak self] data, _ in
            guard let self else { return }
            if let data, let listing = try? JSONDecoder().decode(SweepListing.self, from: data),
               let site = listing.sites?.first(where: { $0.site == code }), self.state?.mode?.site == code {
                self.openSite = site
            }
            then()
        }
    }

    // MARK: - Drawing

    /// Draws what the step on screen should show of the open site, fetching it if need be.
    private func redraw() {
        guard let state, let mode = state.mode, let site = openSite else { return }
        generation += 1
        let generation = generation
        let tilts = SiteSweepRules.listed(site, mode.quantity)
        let tilt = SiteSweepRules.tiltNear(tilts, mode.elevation)
        // The timeline keeps to the steps this tilt has a sweep for.
        if let player = map?.player, let latest = player.timeline.now {
            let only = Set(SiteSweepRules.stepsWithSweep(tilt?.scans ?? [], steps: player.timeline.steps, latest: latest))
            if player.only != only { player.only = only }
        }
        let live = step.isLive || step.time == nil
        let scan = tilt.flatMap { SiteSweepRules.sweepAt($0.scans, step: Double(step.time ?? 0), live: live) }
        let base = SiteSweepView(site: site, tilts: offered(site, mode), hasVelocity: !SiteSweepRules.listed(site, .velocity).isEmpty,
                                 status: .loading, srv: srv, stormMoves: motion() != nil,
                                 stormName: stormName())
        guard let scan, let tilt else {
            shown = nil
            show(nil)
            clearRings()
            state.view = base.with(status: .none)
            return
        }
        if shown?.scan.path != scan.path {
            var loading = base
            loading.startedAt = state.view?.startedAt
            loading.scannedAt = state.view?.scannedAt
            loading.nyquist = state.view?.nyquist
            loading.dealiased = state.view?.dealiased
            loading.dealiaser = state.view?.dealiaser
            state.view = loading
        }
        load(scan.path) { [weak self] sweep in
            guard let self, generation == self.generation, let state = self.state, let mode = state.mode else { return }
            guard let sweep else {
                self.shown = nil
                self.show(nil)
                var failed = base.with(status: .failed)
                failed.scannedAt = scan.scannedAt
                state.view = failed
                return
            }
            self.shown = (scan, sweep)
            let geometry = sweep.header.geometry
            self.reach = (geometry, SweepGeometryRules.reachM(geometry))
            // Taken now, not before the fetch: the dial may have turned while it was out.
            self.show(SiteSweepScene.drawing(sweep, quantity: mode.quantity, motion: self.srv.motion,
                                             reflectivity: RadarLUT(palette: self.map?.player.palette ?? "classic")))
            self.showRings(geometry)
            var view = base.with(status: .shown)
            view.startedAt = sweep.header.startedAt
            view.scannedAt = sweep.header.scannedAt
            view.nyquist = sweep.header.nyquistMs
            view.dealiased = sweep.header.isVelocity ? sweep.header.dealiased : nil
            view.dealiaser = sweep.header.dealiaser
            // Offered again with the drawn antenna's own height.
            state.view = SiteSweepView(site: view.site, tilts: self.offered(site, mode), hasVelocity: view.hasVelocity, status: .shown,
                                       startedAt: view.startedAt, scannedAt: view.scannedAt, nyquist: view.nyquist,
                                       dealiased: view.dealiased, dealiaser: view.dealiaser, srv: self.srv,
                                       stormMoves: view.stormMoves, stormName: view.stormName)
            // The next few, so a step forward finds its sweep already here.
            for next in SiteSweepRules.ahead(of: tilt.scans, shown: scan) { self.load(next.path) { _ in } }
        }
    }

    /// Every tilt of what is open, lowest first, each with its beam's height 100 km out.
    private func offered(_ site: ListedSite, _ mode: SiteMode) -> [OfferedTilt] {
        let height = shown?.sweep.header.heightM ?? RadarSites.all[site.site]?.heightM ?? 0
        return SiteSweepRules.listed(site, mode.quantity)
            .sorted { $0.elevationDeg < $1.elevationDeg }
            .map { OfferedTilt(elevation: $0.elevationDeg,
                               beamKmAt100: RadarSites.beamHeightKm(range: 100, elevationDeg: $0.elevationDeg, siteHeightM: height)) }
    }

    private func show(_ drawn: SiteSweepScene.Drawn?) {
        guard let mapView = map?.mapView else { return }
        overlay.scene.show(drawn)
        if drawn != nil, !overlayAdded {
            overlay.scene.setDark(map?.model.isDark ?? false)
            // Over the composites, under the snow and the marks.
            if let radar = map?.radar.overlay { mapView.insertOverlay(overlay, above: radar) } else { mapView.addOverlay(overlay, level: .aboveRoads) }
            overlayAdded = true
        } else if drawn == nil, overlayAdded {
            mapView.removeOverlay(overlay)
            overlayAdded = false
        }
        if overlayAdded { mapView.renderer(for: overlay)?.setNeedsDisplay() }
        greyComposites()
    }

    /// The composites under a drawn sweep: dimmed, and in grey, black ink on
    /// a light map and white on a dark one.
    private func greyComposites() {
        guard let map else { return }
        map.radar.siteDimmed = overlayAdded
        map.radar.ink = overlayAdded ? (map.model.isDark ? .white : .black) : nil
    }

    private func showRings(_ geometry: SweepGeometry) {
        guard let mapView = map?.mapView else { return }
        let key = "\(geometry.lat):\(geometry.lon):\(geometry.elevationDeg):\(Double(geometry.nbins) * geometry.rangeStepM)"
        guard key != ringsKey else { return }
        clearRings()
        ringsKey = key
        let made = BeamRings.make(geometry, dark: map?.model.isDark ?? false)
        rings = made.rings
        ringLabels = made.labels
        for ring in rings { mapView.insertOverlay(ring, above: overlay) }
        mapView.addAnnotations(ringLabels)
    }

    private func clearRings() {
        guard let mapView = map?.mapView else { return }
        mapView.removeOverlays(rings)
        mapView.removeAnnotations(ringLabels)
        rings = []
        ringLabels = []
        ringsKey = ""
    }

    // MARK: - Reading

    private func readAt(_ coordinate: CLLocationCoordinate2D) -> ReadingParts? {
        guard let mode = state?.mode, let shown else { return nil }
        let header = shown.sweep.header
        guard let bin = SweepGeometryRules.binAt(header.geometry, lon: coordinate.longitude, lat: coordinate.latitude) else { return nil }
        var reading = Sweep.read(header.encoding, shown.sweep.bins[bin.ray * header.nbins + bin.bin])
        if mode.quantity == .srv, case .value(let value) = reading {
            reading = .value(SweepGeometryRules.stormRelative(value, azimuthDeg: bin.azimuthDeg, motion: srv.motion))
        }
        return SiteSweepRules.describe(reading, mode.quantity, azimuthDeg: bin.azimuthDeg, groundM: bin.groundM, heightM: bin.heightM) {
            CoreStrings.t($0, $1)
        }
    }

    // MARK: - Sweeps

    /// One sweep, from the ones held or the bucket; the least recently used
    /// is let go past `kept`. nil when it could not be had.
    private func load(_ path: String, _ done: @escaping (Sweep?) -> Void) {
        if let held = sweeps[path] {
            used.removeAll { $0 == path }
            used.append(path)
            done(held)
            return
        }
        if loading[path] != nil {
            loading[path]?.append(done)
            return
        }
        guard let map else { return done(nil) }
        loading[path] = [done]
        map.fetch(map.endpoints.tiles.appendingPathComponent(path)) { [weak self] data, _ in
            guard let self else { return }
            let sweep = data.flatMap { try? Sweep.decode($0) }
            let waiting = self.loading.removeValue(forKey: path) ?? []
            if let sweep {
                self.sweeps[path] = sweep
                self.used.append(path)
                while self.used.count > Self.kept { self.sweeps[self.used.removeFirst()] = nil }
            }
            for done in waiting { done(sweep) }
        }
    }
}

private extension SiteSweepView {
    func with(status: Status) -> SiteSweepView {
        SiteSweepView(site: site, tilts: tilts, hasVelocity: hasVelocity, status: status, startedAt: startedAt, scannedAt: scannedAt,
                      nyquist: nyquist, dealiased: dealiased, dealiaser: dealiaser, srv: srv, stormMoves: stormMoves,
                      stormName: stormName)
    }
}
