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
final class NativeMapView: UIView, MKMapViewDelegate, NativeMapContext, UIGestureRecognizerDelegate, ObservableObject {
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
    private var stripsChrome: UIView?
    private var otherChrome: UIView?
    /// The dock stands on the radar's tray, or on another map's bar.
    private var dockOnTray: NSLayoutConstraint?
    private var dockOnOther: NSLayoutConstraint?
    /// The bars above the tray, bottom up: core's strips, then the parts'
    /// bars (a storm's hint), each hidden while it has nothing to say.
    private let dock = PassthroughStack()
    let monitor = ConnectionMonitor()
    let notices = NoticeState()
    let productScans = ProductScans()
    /// Bumped on each foreground and wake, for the pill's dimming.
    @Published private var wakes = 0
    var wakeCount: Int { wakes }
    private let chromeState = ChromeState()
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
            guard let self else { return }
            self.model.serverTime = Date(timeIntervalSince1970: TimeInterval(series.serverTime))
            // A fresh series answers the staleness.
            self.model.stale = false
            self.radar.stale = false
            self.updateCoverage()
        }
        radar.onGaveUp = { [weak self] product in self?.gaveUp(product) }
        monitor.radarStale = { [weak self] in self?.model.stale ?? false }
        monitor.newestProcessed = { [weak self] in self?.radar.processedTimes ?? (nil, nil) }
        observeSettings()
        socket.onEvent = { [weak self] name, data in self?.socketEvent(name, data) }
        socket.onReconnect = { [weak self] in self?.wake() }
        socket.onConnection = { [weak self] connected in self?.model.connected = connected }

        for feature in Self.makeFeatures() { add(feature) }
        applySettings()
        #if DEBUG || FRAME_TIMING
        // A view and frame to open at, to hold the map against core's:
        // `MC_NATIVE_MAP_LINK='?latLonZ=45.8,4.6,7'` (devicectl's
        // `--environment-variables` on a phone).
        if let search = ProcessInfo.processInfo.environment["MC_NATIVE_MAP_LINK"] { open(search: search) }
        #endif
        #if DEBUG
        // And a position of the user's own (`MC_USER_LOCATION='48.14,11.58'`),
        // held whatever Core Location says: UI tests of what is shown for it.
        if let pair = ProcessInfo.processInfo.environment["MC_USER_LOCATION"]?.split(separator: ","), pair.count == 2,
           let latitude = Double(pair[0]), let longitude = Double(pair[1]) {
            heldLocation = CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude), altitude: 0,
                                      horizontalAccuracy: 30, verticalAccuracy: -1, timestamp: Date())
            showLocation(heldLocation, zoom: false, focus: false)
        }
        #endif
        // Nothing to keep live in the background; `ViewController` starts
        // it again when the app is active.
        NotificationCenter.default.addObserver(self, selector: #selector(enteredBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: NativeMapView, _: UITraitCollection) in
            view.appearanceChanged()
        }
        model.$covers
            .sink { [weak self] covers in self?.host?.mapCovered(!covers.isEmpty, by: "nativeMap") }
            .store(in: &observers)
        model.site.$view
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateCredits() } }
            .store(in: &observers)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The parts of the map, bottom to top.
    private static func makeFeatures() -> [NativeMapFeature] {
        let storms = StormMarks()
        // Before the storms: a tap past an open radar's reach closes it, and
        // only it, unless it lands on a storm.
        let sites = SiteSweeps(motion: { [weak storms] in
            storms?.store.selection.flatMap(StormSelect.motionOf).map { StormMotion(speedMs: $0.speedMs, headingDeg: $0.headingDeg) }
        }, stormName: { [weak storms] in
            guard let selection = storms?.store.selection else { return nil }
            let t: StormTranslate = { CoreStrings.t($0, $1) }
            if let place = StormRules.placementLabel(selection.cell?.placement ?? selection.summary?.properties.placement, t, style: .short) {
                return place
            }
            guard StormSelect.knowsSeverity(selection) else { return CoreStrings.t("storm.storm_label.unclassed") }
            return CoreStrings.t("storm.storm_label.\(StormRules.bandNames[StormSelect.severityOf(selection) ?? 0])")
        }, hitsStorm: { [weak storms] point in storms?.hits(point) ?? false })
        return [PrecipTypesMap(), LightningMap(), SnowOverlay(), LightningMarks(), MesocycloneMarks(), StationMarks(), sites, storms, CloudHints(),
                PointFeature(), RadarWash(), ThreeDMap()]
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
    /// keeps every touch that misses them: the tray at the bottom, the strips
    /// above it, "Back to now" above those, the status pill on the top line,
    /// and toasts under it.
    private func configureChrome() {
        let actions = TrayActions(showForMyLocation: { [weak self] in self?.clearPoint() },
                                  openProducts: { [weak self] in self?.openProducts() },
                                  openStormKey: { [weak self] in self?.openStormKey() },
                                  toggleStations: { [weak self] in
                                      guard let self else { return }
                                      self.setOn(.stations, !self.isOn(.stations))
                                  })
        let tray = addChrome(PlayerTray(player: player, model: model, actions: actions))
        // The tray sits half the home indicator's height above the bottom (`--mc-tray-bottom`).
        let trayBottom = tray.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -21)
        chromeState.trayBottom = trayBottom
        NSLayoutConstraint.activate([
            tray.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: ChromeTheme.gutter),
            tray.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -ChromeTheme.gutter),
            trayBottom,
        ])
        bottomChrome = tray

        // The other flat maps' bar, where the tray is.
        let other = addChrome(OtherMapTray(model: model))
        NSLayoutConstraint.activate([
            other.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: ChromeTheme.gutter),
            other.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -ChromeTheme.gutter),
            other.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -21),
        ])
        otherChrome = other

        dock.axis = .vertical
        dock.spacing = ChromeTheme.gutter
        dock.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dock)
        NSLayoutConstraint.activate([
            dock.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            dock.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
        ])
        dockOnTray = dock.bottomAnchor.constraint(equalTo: tray.topAnchor, constant: -ChromeTheme.gutter)
        dockOnOther = dock.bottomAnchor.constraint(equalTo: other.topAnchor, constant: -ChromeTheme.gutter)
        dockOnTray?.isActive = true
        // An open radar's controls, on the tray; the strips stand on them.
        let siteCard = addToDock(SiteSweepCard(state: model.site, model: model))
        siteCard.isHidden = true
        model.site.$mode
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak siteCard] open in
                DispatchQueue.main.async {
                    siteCard?.isHidden = !open
                    siteCard?.invalidateIntrinsicContentSize()
                }
            }
            .store(in: &observers)
        // Measured again as it grows or shrinks: the motion's editor, another
        // quantity's rows. A host keeps the size it was laid out at otherwise,
        // and what grows past it takes no touches.
        Publishers.Merge(model.site.$motionOpen.map { _ in () }, model.site.$mode.map { _ in () })
            .sink { [weak self, weak siteCard] in
                DispatchQueue.main.async {
                    siteCard?.invalidateIntrinsicContentSize()
                    self?.setNeedsLayout()
                }
            }
            .store(in: &observers)
        // The stations' parameter, over the radar's controls when both are up.
        let stationCard = addToDock(StationPicker(model: model, state: model.stations))
        stationCard.isHidden = true
        model.$layersOn.combineLatest(model.$capability)
            .map { on, capability in on.contains(.stations) && capability == .radar }
            .removeDuplicates()
            .sink { [weak stationCard] shown in
                DispatchQueue.main.async {
                    stationCard?.isHidden = !shown
                    stationCard?.invalidateIntrinsicContentSize()
                }
            }
            .store(in: &observers)
        let strips = addToDock(NoticeStrips(player: player, model: model, notices: notices))
        stripsChrome = strips
        notices.objectWillChange
            .sink { [weak self] in DispatchQueue.main.async { self?.updateChromeVisibility() } }
            .store(in: &observers)

        // Above whichever bars are up, as core counts the open strips and hints.
        let backHost = WeakView()
        let back = addChrome(BackToNowPill(player: player, model: model, site: model.site) { backHost.view?.invalidateIntrinsicContentSize() })
        backHost.view = back
        NSLayoutConstraint.activate([
            back.centerXAnchor.constraint(equalTo: centerXAnchor),
            back.bottomAnchor.constraint(equalTo: dock.topAnchor, constant: -ChromeTheme.gutter),
        ])

        let pill = addChrome(PillHost(player: player, model: model, monitor: monitor, owner: self))
        NSLayoutConstraint.activate([
            pill.centerXAnchor.constraint(equalTo: centerXAnchor),
            pill.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: ChromeTheme.gutter),
        ])

        let toast = addChrome(ToastHost(model: model, state: chromeState))
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: centerXAnchor),
            toast.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -120),
            toast.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: ChromeTheme.gutter + 44 + ChromeTheme.gutter),
        ])
    }

    /// The tray, strips and "Back to now" are the radar map's; other maps
    /// and a storm's sheet put them away.
    private func updateChromeVisibility() {
        let radar = model.capability == .radar && !model.trayHidden
        bottomChrome?.isHidden = !radar
        otherChrome?.isHidden = !(model.capability == .lightning || model.capability == .precipitationTypes) || model.trayHidden
        // Its content changed while it was hidden: measured again now it shows.
        otherChrome?.invalidateIntrinsicContentSize()
        // The dock stays up on the lightning map for its histogram.
        dock.isHidden = !radar && model.capability != .lightning
        let onTray = model.capability == .radar
        if dockOnTray?.isActive != onTray {
            dockOnTray?.isActive = false
            dockOnOther?.isActive = false
            (onTray ? dockOnTray : dockOnOther)?.isActive = true
        }
        notices.radarShown = radar
        stripsChrome?.isHidden = !(notices.showNoRadar || notices.showNoForecast)
        stripsChrome?.invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    /// Clears a long-pressed point: the bars are your own position's again
    /// (core's `returnToCurrentPosition`).
    func clearPoint() {
        model.point = nil
        if let location = model.userLocation { radar.point = location.coordinate }
        updateTitle()
    }

    /// The tray's title: the place's name once known, else what the bars
    /// measure; nothing without a position or a point.
    private func updateTitle() {
        if model.point != nil {
            model.trayTitle = model.placeName ?? CoreStrings.t("precipitation_at_point")
        } else if model.userLocation != nil {
            model.trayTitle = model.placeName ?? CoreStrings.t("precipitation_here")
        } else {
            model.trayTitle = nil
        }
    }

    /// What the storm marks mean, each switchable (core's `StormKey`).
    func openStormKey() {
        let mesocyclones = Binding(get: { [weak self] in self?.isOn(.mesocyclones) ?? true },
                                   set: { [weak self] on in self?.setOn(.mesocyclones, on) })
        let key = UIHostingController(rootView: StormKeyView(model: model, mesocyclones: mesocyclones,
                                                             close: { [weak self] in self?.dismissSheet() }))
        presentSheet(key, detents: [.medium(), .large()])
    }

    func openProducts() {
        productScans.load(self)
        let menu = UIHostingController(rootView: ProductMenu(player: player, model: model, scans: productScans,
                                                            close: { [weak self] in self?.dismissSheet() },
                                                            explain: { [weak self] in self?.openExplainer() }))
        presentSheet(menu, detents: [.medium(), .large()])
    }

    private func openExplainer() {
        dismissSheet { [weak self] in
            guard let self else { return }
            let explainer = UIHostingController(rootView: RadarExplainer(palette: self.player.palette,
                                                                         close: { [weak self] in self?.dismissSheet() }))
            self.presentSheet(explainer, detents: [.large()])
        }
    }

    func openConnectionDetails() {
        let details = UIHostingController(rootView: ConnectionDetails(player: player, model: model, monitor: monitor,
                                                                      close: { [weak self] in self?.dismissSheet() }))
        presentSheet(details, detents: [.large()])
    }

    /// A sheet over the map, the app's buttons hidden while it is up.
    func presentSheet(_ controller: UIViewController, detents: [UISheetPresentationController.Detent]) {
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = detents
            sheet.prefersGrabberVisible = true
        }
        host?.presentOverMap(controller)
    }

    private func dismissSheet(then: (() -> Void)? = nil) {
        guard let presenter = window?.rootViewController else { then?(); return }
        presenter.dismiss(animated: true, completion: then)
    }

    /// Whether the radar or its forecast covers the view (core's notices and
    /// `canPlay`): the networks' boxes for the radar; for the forecast, a
    /// 12×12 sample of the view against DWD's reach and the nowcast runs.
    private func updateCoverage() {
        guard model.capability == .radar, mapView.bounds.width > 0 else { return }
        let visible = mapView.visibleMapRect
        let out = !RadarCoverage.touchesRadar(visible)
        notices.outOfRadar = out
        player.outOfRadar = out
        let timeline = player.timeline
        let anyRun = Set(timeline.nowcastDomains.values.flatMap { $0 })
        player.noForecast = !out && ForecastCoverage.uncoveredShare(visible, radar: radar, domains: Array(anyRun)) >= 1
        if let step = player.step, timeline.isForecast(step) {
            notices.noForecastHere = !out && ForecastCoverage.uncoveredShare(visible, radar: radar, domains: timeline.nowcastDomains[step] ?? []) >= 1
        } else {
            notices.noForecastHere = false
        }
    }

    /// Hosts a SwiftUI view over the map, sized to fit; the caller places it.
    @discardableResult
    func addChrome<Content: View>(_ content: Content) -> UIView {
        let host = UIHostingController(rootView: content.chromeTypeSize())
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.sizingOptions = .intrinsicContentSize
        addSubview(host.view)
        chrome.append(host.view)
        return host.view
    }

    @discardableResult
    func addToDock<Content: View>(_ content: Content) -> UIView {
        let host = UIHostingController(rootView: content.chromeTypeSize())
        host.view.backgroundColor = .clear
        host.sizingOptions = .intrinsicContentSize
        dock.insertArrangedSubview(host.view, at: 0)
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
        // Taps on marks are the map's own (`didSelect`); a hold is the map's
        // wherever it lands, as core's is.
        if gestureRecognizer is UILongPressGestureRecognizer { return true }
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
        if abs(chromeState.width - bounds.width) > 0.5 { chromeState.width = bounds.width }
        // Keep Apple's logo and legal link clear of the controls at the bottom.
        if let bottom = [bottomChrome, otherChrome].compactMap({ $0 }).first(where: { !$0.isHidden }) ?? bottomChrome {
            let covered = bottom.isHidden ? 0 : bounds.maxY - bottom.frame.minY - safeAreaInsets.bottom + 8
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

    private func appearanceChanged() {
        let dark = traitCollection.userInterfaceStyle == .dark
        if dark != model.isDark {
            model.isDark = dark
            for feature in features { feature.settingsDidChange() }
        }
    }

    // MARK: - Lifecycle

    /// Starts loading and listening; the map is on screen.
    func start() {
        player.returnedToForeground()
        wakes += 1
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
        // On wake core judges the radar's age: out of date until a new grid lands.
        let now = Int(Date().timeIntervalSince1970)
        if ConnectionRules.outdated(newestObservation: player.timeline.now, period: radar.processedTimes.cadence, now: now) {
            model.stale = true
            radar.stale = true
        }
        radar.wake()
        for feature in features { feature.wake() }
    }

    private func tick() {
        radar.tick()
        for feature in features { feature.tick() }
        updateCredits()
    }

    private func stepChanged() {
        updateCoverage()
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
        linkOverrides[layer] ?? defaults?.object(forKey: "nativeMap.\(layer.rawValue)") as? Bool ?? layer.defaultOn
    }

    func setOn(_ layer: NativeMapLayer, _ on: Bool) {
        // The reader's own switch wins over what a link said.
        linkOverrides[layer] = nil
        defaults?.set(on, forKey: "nativeMap.\(layer.rawValue)")
        applySettings()
    }

    /// What a link turned on or off for this visit (core's `settings.override`),
    /// over the reader's own settings, which it leaves as they were.
    private var linkOverrides: [NativeMapLayer: Bool] = [:]

    /// The radar map's overlays as links name them.
    private static let overlayLayers: [String: NativeMapLayer] = ["cells": .storms, "lightning": .lightning, "mesocyclones": .mesocyclones]

    /// A link's overlays (`applyLinkedOverlays`): on the radar map a link that
    /// names none means all of them; a storm or a cell turns storms on.
    private func applyLinkedOverlays(_ parameters: [String: String]) {
        let named = NativeMapLink.overlays(parameters["overlays"])
        let onRadar = (parameters["layer"].flatMap(NativeMapModel.Capability.init) ?? model.capability) == .radar
        if let on = named ?? (onRadar ? NativeMapLink.overlayNames : nil) {
            for (name, layer) in Self.overlayLayers { linkOverrides[layer] = on.contains(name) }
        }
        if parameters["storm"] != nil || parameters["cell"] != nil { linkOverrides[.storms] = true }
        applySettings()
    }

    /// The layers button's panel: core's maps as tiles, and what the radar
    /// map draws over the radar.
    func openLayers() {
        // The switcher drops the storm open (core's App.svelte), its panel
        // put away before the switcher can come up.
        if let marks = features.lazy.compactMap({ $0 as? StormMarks }).first, marks.store.selection != nil {
            marks.dropSelection { [weak self] in self?.presentLayers() }
        } else {
            presentLayers()
        }
    }

    private func presentLayers() {
        let snapshots = LayerSnapshots()
        let region = mapView.region
        snapshots.take(region: region, size: CGSize(width: 360, height: 180), dark: model.isDark)
        let fromStart = Binding<Bool>(
            get: { [weak self] in self?.defaults?.bool(forKey: "nativeMap.playbackFromStart") ?? false },
            set: { [weak self] in
                self?.defaults?.set($0, forKey: "nativeMap.playbackFromStart")
                self?.applySettings()
            })
        let view = LayerSwitcherView(model: model, snapshots: snapshots,
                                     isOn: { [weak self] in self?.isOn($0) ?? $0.defaultOn },
                                     setOn: { [weak self] in self?.setOn($0, $1) },
                                     fromStart: fromStart,
                                     choose: { [weak self] capability in
                                         self?.dismissSheet { self?.setCapability(capability) }
                                     },
                                     close: { [weak self] in self?.dismissSheet() })
        presentSheet(UIHostingController(rootView: view), detents: [.medium(), .large()])
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
        player.fromStart = defaults?.bool(forKey: "nativeMap.playbackFromStart") ?? false
        let on = Set(NativeMapLayer.allCases.filter(isOn))
        if model.layersOn != on { model.layersOn = on }
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
        // The open radar's own sweep, credited as its network is.
        if model.capability == .radar, model.site.view?.status == .shown, let network = model.site.view?.site.network,
           let credit = RadarEngine.credit(network: network), !names.contains(credit) {
            names.append(credit)
        }
        if isOn(.lightning) || model.capability == .lightning { names.append("Blitzortung.org") }
        model.credits = names.isEmpty ? "" : "© " + names.joined(separator: ", © ")
    }

    var view: UIView { self }

    // MARK: - Data

    func fetch(_ url: URL, _ handler: @escaping @MainActor (Data?, Int?) -> Void) {
        let started = Date()
        NetworkLog.shared.started()
        URLSession.shared.dataTask(with: url) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode
            NetworkLog.shared.finished(RequestRecord(service: NetworkLog.service(of: url), endpoint: url.path, time: Date(),
                                                     status: status, duration: Date().timeIntervalSince(started),
                                                     bytes: data?.count ?? 0, cached: false))
            let body = status.map { (200 ..< 300).contains($0) } == true ? data : nil
            Task { @MainActor in handler(body, status) }
        }.resume()
    }

    /// Keeps the chrome's own settings stored, and the radar in step with them.
    private func observeSettings() {
        model.legendDBZ = defaults?.string(forKey: "nativeMap.radarLegendUnit") == "dbz"
        model.product = RadarProduct(setting: defaults?.string(forKey: "nativeMap.radarProduct"))
        radar.product = model.product
        model.$legendDBZ.dropFirst()
            .sink { [weak self] dbz in self?.defaults?.set(dbz ? "dbz" : "pictogram", forKey: "nativeMap.radarLegendUnit") }
            .store(in: &observers)
        model.$product.dropFirst()
            .sink { [weak self] product in
                self?.defaults?.set(product.rawValue, forKey: "nativeMap.radarProduct")
                self?.radar.product = product
            }
            .store(in: &observers)
        model.$selectedStorm
            .sink { [weak self] storm in self?.radar.dimmed = storm != nil }
            .store(in: &observers)
        Publishers.CombineLatest3(model.$point, model.$userLocation, model.$placeName)
            .sink { [weak self] _, _, _ in DispatchQueue.main.async { self?.updateTitle() } }
            .store(in: &observers)
        Publishers.CombineLatest(model.$capability, model.$trayHidden)
            .sink { [weak self] _, _ in DispatchQueue.main.async { self?.updateChromeVisibility() } }
            .store(in: &observers)
    }

    /// The chosen product has no frame at all: back to the lowest scan, and
    /// say so (`giveUpChoice`).
    private func gaveUp(_ product: RadarProduct) {
        model.product = .hx
        model.toast = CoreStrings.t("chrome.radar_product.gave_up", [
            "product": CoreStrings.t("chrome.radar_product.\(product.rawValue)"),
            "fallback": CoreStrings.t("chrome.radar_product.hx"),
        ])
    }

    // MARK: - The host's calls

    /// A position for UI tests that Core Location does not replace.
    private var heldLocation: CLLocation?

    /// The user's position from the location button, as core's
    /// `lm.updateLocation`: `zoom` zooms in by the fix's accuracy, `focus`
    /// centres on it. Nil hides the dot.
    func showLocation(_ location: CLLocation?, zoom: Bool, focus: Bool) {
        let location = heldLocation ?? location
        mapView.showsUserLocation = location != nil && heldLocation == nil
        model.userLocation = location
        guard let location else { return }
        if focus {
            let accuracy = location.horizontalAccuracy
            let level: Double? = zoom ? (accuracy < 800 ? 10 : accuracy < 2000 ? 9 : 8) : nil
            if let level {
                place(NativeMapLink(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, zoom: level),
                      animated: true)
            } else {
                mapView.setCenter(location.coordinate, animated: true)
            }
            // The 3D map, where it is the map shown, flies its own camera.
            _ = features.first { $0.lookAt(location.coordinate, zoom: level) }
        }
        // The readings are for a long-pressed point while there is one.
        if model.point == nil { radar.point = location.coordinate }
    }

    /// Back to the live radar, as the logo does on the web map.
    func showLive() {
        model.capability = .radar
        player.showLive()
    }

    /// A link: its map (`layer`), view and frame (`latLonZ`, `t`), and
    /// whatever its parts take from it (a storm, a point, …).
    func open(search: String) {
        let parameters = NativeMapLink.parameters(search)
        // A link shared a while ago says so (`share.stale`).
        if let shared = parameters["shared"].flatMap(NativeMapLink.frameTime),
           let ago = ShareAge.text(sharedAt: shared, now: Int(Date().timeIntervalSince1970)) {
            let key = parameters["storm"] != nil || parameters["cell"] != nil || parameters["cloud"] != nil ? "share.stale_storm" : "share.stale"
            model.toast = CoreStrings.t(key, ["ago": ago])
        }
        if let layer = parameters["layer"], let capability = NativeMapModel.Capability(rawValue: layer) {
            setCapability(capability)
        }
        applyLinkedOverlays(parameters)
        if let link = NativeMapLink(search: search) {
            if placed { place(link, animated: true) } else { pendingView = link }
            // A storm's link opens on now: it is about the storm, not a frame.
            if parameters["storm"] == nil, parameters["cell"] == nil { radar.show(time: link.time) }
        }
        for feature in features { _ = feature.open(parameters) }
    }

    func openLink(_ parameters: [String: String]) {
        for feature in features { _ = feature.open(parameters) }
    }

    func setCapability(_ capability: NativeMapModel.Capability) {
        guard capability != model.capability else { return }
        if capability != .cells3d { model.detour = nil }
        model.capability = capability
        radar.visible = capability == .radar
        radar.underlay = capability == .lightning
        model.lastUpdated = nil
        updateChromeVisibility()
        for feature in features { feature.capabilityDidChange(capability) }
        for feature in features { feature.settingsDidChange() }
        updateCredits()
    }

    /// A link to what is on screen, in core's spelling, for the share sheet.
    func shareMap(title: String, source: UIView?, center: CLLocationCoordinate2D?, extra: [String: String]) {
        guard let share = share(title: title, center: center, extra: extra) else { return }
        host?.shareFromMap(share, source: source)
    }

    func share(title: String = "meteocool", center: CLLocationCoordinate2D? = nil, extra given: [String: String] = [:]) -> MapShare? {
        // The 3D map's camera where it is the map shown (core's `mapView`).
        let shown = features.lazy.compactMap { $0.linkView() }.first
        let center = center ?? shown.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) } ?? mapView.centerCoordinate
        let shared = NativeMapLink.frameLink(Int(Date().timeIntervalSince1970) / 60 * 60)
        var extra: [String: String] = model.capability == .radar ? [:] : ["layer": model.capability.rawValue]
        extra.merge(given) { _, new in new }
        for feature in features { extra.merge(feature.linkParameters()) { first, _ in first } }
        // The overlays, only where they differ from all on: saying all on
        // would override a reader who turned lightning off for good.
        if model.capability == .radar {
            let on = NativeMapLink.overlayNames.filter { Self.overlayLayers[$0].map(isOn) ?? true }
            if on.count != NativeMapLink.overlayNames.count { extra["overlays"] = NativeMapLink.overlaysValue(on) }
        }
        // The frame: not for a storm, which is about now, and not mid-play,
        // which would park the link on whichever frame it caught.
        let tracked = extra["storm"] != nil || extra["cell"] != nil
        let time = player.step != player.timeline.now && !player.playing && !tracked ? player.step : nil
        let link = NativeMapLink(latitude: center.latitude, longitude: center.longitude, zoom: shown?.zoom ?? zoomLevel, time: time)
        var components = URLComponents()
        components.queryItems = extra.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let more = extra.isEmpty ? "" : "&" + (components.percentEncodedQuery ?? "")
        let url = MeteocoolEnvironment.current.mapURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            + "/" + link.search + more + "&shared=" + shared
        guard let data = try? JSONSerialization.data(withJSONObject: ["url": url, "title": title]),
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

    func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
        for feature in features { feature.regionWillChange() }
    }

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        #if DEBUG
        // Where the map is, for UI tests (`nativeMap.view`'s value), in a
        // link's spelling: MapKit keeps the map's own value to itself.
        accessibilityIdentifier = "nativeMap.view"
        accessibilityValue = String(format: "%.3f,%.3f,%.1f", mapView.centerCoordinate.latitude,
                                    mapView.centerCoordinate.longitude, zoomLevel)
        #endif
        radar.regionDidChange()
        updateCoverage()
        for feature in features { feature.regionDidChange() }
        updateCredits()
    }
}

/// Holds what the chrome's hosts are laid out against.
@MainActor
private final class ChromeState: ObservableObject {
    var trayBottom: NSLayoutConstraint?
    /// The map's width, for chrome that wraps text to it (toasts).
    @Published var width: CGFloat = 0
}

/// The status pill, which opens Connection Details.
private struct PillHost: View {
    @ObservedObject var player: RadarPlayer
    @ObservedObject var model: NativeMapModel
    @ObservedObject var monitor: ConnectionMonitor
    @ObservedObject var owner: NativeMapView

    var body: some View {
        StatusPill(player: player, model: model, monitor: monitor, open: { owner.openConnectionDetails() }, wakes: owner.wakeCount)
            .opacity(model.capability == .radar ? 1 : 0)
    }
}

/// A toast under the top line, gone after fifteen seconds (`reportToast`).
private struct ToastHost: View {
    @ObservedObject var model: NativeMapModel
    @ObservedObject var state: ChromeState

    var body: some View {
        // Never empty: a host laid out at zero size does not grow back.
        ZStack {
            Color.clear.frame(width: 1, height: 1)
            if let text = model.toast {
                MapToast(text: text, symbol: "clock.arrow.circlepath", theme: ChromeTheme(dark: model.isDark)) { model.toast = nil }
                    .frame(width: min(448, max(220, state.width - 120)))
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: text) {
                        try? await Task.sleep(for: .seconds(15))
                        if !Task.isCancelled, model.toast == text { model.toast = nil }
                    }
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.toast)
    }
}

/// A stack that keeps none of the touches between its bars for itself.
/// A view to reach later from a closure built before it.
private final class WeakView {
    weak var view: UIView?
}

private final class PassthroughStack: UIStackView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}
