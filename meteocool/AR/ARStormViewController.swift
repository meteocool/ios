//
//  ARStormViewController.swift
//  meteocool
//
//  Point the phone at a storm and see meteocool's 3D cloud over the real one.
//

import ARKit
import CoreLocation
import MetalKit
import SwiftUI
import UIKit

/// A storm the map asked the AR view to find.
enum StormTarget: Equatable, Sendable {
    /// A volume, by its path on the asset host.
    case volume(String)
    /// A tracked KONRAD3D cell, by its 22-digit code.
    case cell(String)
}

/// The AR storm view: the camera image with every storm within range drawn
/// over it, in place and to scale, with modes to cut and peel them, tags that
/// say which storm is which, and a way back to the same storm on the map.
///
/// Where ARKit is not available (the simulator, and the UI tests) it runs as
/// a preview: the same scene over a sky, looked around by dragging.
@MainActor
final class ARStormViewController: UIViewController, LocationObserver {
    /// Whether the AR view is on screen: `AppDelegate` allows landscape only then.
    private(set) static var isPresented = false

    /// Whether this build can show the AR view at all.
    static var isAvailable: Bool {
        if ARKitCamera.isSupported { return true }
        #if DEBUG && targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// Called after the view is dismissed with the search part of a map link
    /// to the storm the reader chose.
    var onOpenOnMap: ((String) -> Void)?
    /// Called once the view has been dismissed, whichever way.
    var onClose: (() -> Void)?

    private let target: StormTarget?
    private var targetResolved = false
    private let isPreview: Bool

    private let metalView = MTKView()
    private let labelLayer = StormLabelLayer()
    private let hud = ARHUDModel()
    private let feed = StormFeed()
    private let alignment = HeadingAlignment()
    private let preview = PreviewCamera()
    private var arCamera: ARKitCamera?
    private var renderer: StormRenderer?
    private var scene: StormScene?
    private var huds: [UIHostingController<ARHUDView>] = []

    private var placed: [PlacedStorm] = []
    /// `placed` as storms: a storm is every tile of it.
    private var groups: [StormGroup] = []
    /// The boxes drawn this frame, each with the storm it draws for: fine
    /// tiles near, coarse tiles standing in for them far away.
    private var drawn: [(storm: PlacedStorm, group: StormGroup)] = []
    private var lastPose: CameraPose?
    private var labelModels: [String: StormLabelModel] = [:]
    private var labelsBuiltAt = Date.distantPast
    private var hudUpdatedAt = Date.distantPast
    private var geoNorthCheckedAt = Date.distantPast
    private var sliderValues: [ARViewMode: Double] = [:]
    private var transientBanner: (ARHUDModel.Banner, Date)?
    private var previewPlacement: String?
    private var locationProblem: ARHUDModel.Banner?
    private var lastLocation: CLLocation?
    private let userDefaults = UserDefaults(suiteName: "group.org.frcy.app.meteocool")
    // Written once in viewDidLoad, read once in deinit.
    nonisolated(unsafe) private var thermalObserver: NSObjectProtocol?

    init(target: StormTarget? = nil) {
        self.target = target
        isPreview = !ARKitCamera.isSupported || ProcessInfo.processInfo.arguments.contains("--ar-preview")
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    // MARK: Life cycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.accessibilityIdentifier = "ar.view"

        metalView.frame = view.bounds
        metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        metalView.preferredFramesPerSecond = 60
        metalView.delegate = self
        metalView.isAccessibilityElement = false
        view.addSubview(metalView)
        renderer = StormRenderer(view: metalView)
        renderer?.setPalette(userDefaults?.string(forKey: "radarColorMapping") ?? "classic")

        labelLayer.frame = view.bounds
        labelLayer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        labelLayer.onSelect = { [weak self] key in self?.select(key, toggle: true) }
        labelLayer.onOpen = { [weak self] key in self?.openOnMap(key) }
        view.addSubview(labelLayer)

        installHUD()
        installGestures()

        if !isPreview {
            let camera = ARKitCamera()
            camera.onTrackingChange = { [weak self] _ in self?.refreshBanner() }
            arCamera = camera
        }

        feed.onChange = { [weak self] in self?.feedChanged() }

        // The thermal state is posted on whichever thread noticed the change,
        // not the main one, so it is received on the main queue: a selector
        // here would run main-actor code off the main thread, which Swift
        // traps on (this crashed the view a minute in, once the phone warmed).
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.thermalStateChanged() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(pause),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resume),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        thermalStateChanged()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        Self.isPresented = true
        setNeedsUpdateOfSupportedInterfaceOrientations()
        feed.start()
        if isPreview {
            locationProblem = nil
        } else {
            alignment.start()
            arCamera?.run()
        }
        acquireLocation()
        metalView.isPaused = false
        refreshBanner()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Back to portrait as the map comes back, not after.
        Self.isPresented = false
        presentingViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        feed.stop()
        alignment.stop()
        arCamera?.pause()
        metalView.isPaused = true
    }

    @objc private func pause() {
        guard Self.isPresented else { return }
        arCamera?.pause()
        metalView.isPaused = true
    }

    @objc private func resume() {
        guard Self.isPresented, view.window != nil else { return }
        // The same configuration, without resetting tracking: a sun fix or a
        // nudge stays valid when ARKit picks up where it left off.
        if let arCamera, let configuration = arCamera.session.configuration {
            arCamera.session.run(configuration)
        }
        metalView.isPaused = false
    }

    private func thermalStateChanged() {
        // A raymarch per pixel is the heaviest thing the app asks of the GPU;
        // a hot phone gets fewer pixels and fewer steps before it gets dropped frames.
        let state = ProcessInfo.processInfo.thermalState
        let (scale, steps, fps): (CGFloat, Float, Int) = switch state {
        case .serious: (0.35, 64, 30)
        case .critical: (0.25, 48, 20)
        default: (0.5, 96, 60)
        }
        renderer?.resolutionScale = scale
        renderer?.steps = steps
        metalView.preferredFramesPerSecond = fps
    }

    private func close() {
        let onClose = onClose
        dismiss(animated: true) { onClose?() }
    }

    // MARK: Location

    private func acquireLocation() {
        SharedLocationUpdater.addObserver(observer: self)
        switch SharedLocationUpdater.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            SharedLocationUpdater.startAccurateLocationUpdates()
            if let location = SharedLocationUpdater.getCurrentLocation() { notify(location: location) }
            if scene == nil, !isPreview {
                locationProblem = ARHUDModel.Banner(text: NSLocalizedString("ar_finding_location", comment: ""))
            }
        case .notDetermined where isPreview:
            // The preview can stand anywhere; it is not worth a permission prompt.
            placePreviewIfNeeded()
        case .notDetermined:
            SharedLocationUpdater.requestAuthorization { [weak self] granted, _ in
                if granted { self?.acquireLocation() } else { self?.locationDenied() }
            }
        default:
            locationDenied()
        }
        refreshBanner()
    }

    private func locationDenied() {
        // The preview can stand anywhere; AR has to know where the phone is.
        guard !isPreview else { placePreviewIfNeeded(); return }
        locationProblem = ARHUDModel.Banner(text: NSLocalizedString("ar_location_denied", comment: ""),
                                            actionTitle: NSLocalizedString("ar_open_settings", comment: ""))
        refreshBanner()
    }

    func notify(location: CLLocation) {
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 1_000 else { return }
        lastLocation = location
        // MSL; the boxes stand on sea level too, so the two agree.
        let altitude = location.verticalAccuracy >= 0 ? location.altitude : 0
        if let scene {
            guard !isPreview || previewPlacement == nil else { return }
            let moved = Geo.distanceBearing(fromLat: scene.frame.latitude, lon: scene.frame.longitude,
                                            toLat: location.coordinate.latitude, lon: location.coordinate.longitude).metres
            // The world's origin is where the session started. Once the viewer
            // has gone a kilometre, put both back together.
            guard moved > 1_000 else { return }
            arCamera?.recentre()
            scene.move(to: GeoFrame(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, altitude: altitude))
        } else {
            // The world's origin is where the session started, a moment ago
            // and a few metres away at most; put it under the viewer exactly.
            arCamera?.recentre()
            scene = StormScene(frame: GeoFrame(latitude: location.coordinate.latitude,
                                               longitude: location.coordinate.longitude, altitude: altitude))
            applySettingsToScene()
            arCamera?.upgradeToGeoTracking(at: location.coordinate) { [weak self] in
                // Tracking restarted with its origin at the camera; north is
                // the compass's again until geo tracking localises.
                self?.alignment.reset()
            }
        }
        locationProblem = nil
        feed.viewer = (location.coordinate.latitude, location.coordinate.longitude)
        refreshBanner()
    }

    /// The preview stands where the reader is if storms are near; otherwise
    /// it walks them out to the strongest storm (or the one the map asked
    /// for), 28 km south-south-west of it, looking at it.
    private func placePreviewIfNeeded() {
        guard isPreview, previewPlacement == nil, feed.status == .ready else { return }
        if scene != nil, !feed.nearbyEntries.isEmpty { return }
        let targeted = feed.entries.first { entry in
            switch target {
            case .volume(let path): return entry.path == path
            case .cell(let code): return feed.cell(for: entry)?.code == code
            case nil: return false
            }
        }
        let strongest = feed.entries.max { ($0.openable ? 1 : 0, $0.peakDbz ?? 0) < ($1.openable ? 1 : 0, $1.peakDbz ?? 0) }
        guard let storm = targeted ?? strongest else {
            if scene == nil {
                // Nothing anywhere: stand in Munich and say so.
                scene = StormScene(frame: GeoFrame(latitude: 48.14, longitude: 11.58, altitude: 520))
                applySettingsToScene()
                feed.viewer = (48.14, 11.58)
            }
            return
        }
        let standing = Geo.destination(lat: storm.lat, lon: storm.lon, bearing: 200, metres: 28_000)
        scene = StormScene(frame: GeoFrame(latitude: standing.lat, longitude: standing.lon, altitude: 500))
        applySettingsToScene()
        feed.viewer = standing
        preview.yaw = 20
        preview.pitch = 10
        previewPlacement = NSLocalizedString("ar_preview_placed", comment: "")
        refreshBanner()
    }

    // MARK: Feed

    private func feedChanged() {
        placePreviewIfNeeded()
        resolveTargetIfNeeded()
        labelsBuiltAt = .distantPast
        refreshTrackAvailability()
        refreshBanner()
    }

    private func resolveTargetIfNeeded() {
        guard !targetResolved, let target else { return }
        let entry = feed.entries.first { entry in
            switch target {
            case .volume(let path): return entry.path == path
            case .cell(let code): return feed.cell(for: entry)?.code == code
            }
        }
        guard let entry else { return }
        targetResolved = true
        select(entry.stormKey, toggle: false)
    }

    private func refreshTrackAvailability() {
        if let key = scene?.selectedKey {
            hud.trackAvailable = feed.entries.contains { $0.stormKey == key && feed.cell(for: $0)?.headingDeg != nil }
        } else {
            hud.trackAvailable = feed.entries.contains { feed.cell(for: $0)?.headingDeg != nil }
        }
        if hud.mode == .track && !hud.trackAvailable { setMode(.live) }
    }

    // MARK: HUD

    private func installHUD() {
        hud.isPreview = isPreview
        hud.mode = .live
        hud.onClose = { [weak self] in self?.close() }
        hud.onModeChange = { [weak self] mode in self?.setMode(mode) }
        hud.onSliderChange = { [weak self] value in self?.setSlider(value) }
        hud.onToggleLightning = { [weak self] on in
            self?.hud.showLightning = on
            self?.scene?.showLightning = on
        }
        hud.onToggleExtrapolate = { [weak self] on in
            self?.hud.extrapolate = on
            self?.scene?.extrapolate = on
            self?.labelsBuiltAt = .distantPast
        }
        hud.onArmSunFix = { [weak self] in self?.hud.sunFixArmed = true }
        hud.onResetAlignment = { [weak self] in
            self?.alignment.reset()
            self?.refreshBanner()
        }
        hud.onBannerAction = {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        }

        // Two hosting views, each as tall as its content; see `ARHUDView`.
        for part in [ARHUDView.Part.top, .bottom] {
            let hosting = UIHostingController(rootView: ARHUDView(model: hud, part: part))
            hosting.view.backgroundColor = .clear
            hosting.sizingOptions = .intrinsicContentSize
            hosting.view.translatesAutoresizingMaskIntoConstraints = false
            addChild(hosting)
            view.addSubview(hosting.view)
            let guide = view.safeAreaLayoutGuide
            NSLayoutConstraint.activate([
                hosting.view.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
                hosting.view.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
                part == .top
                    ? hosting.view.topAnchor.constraint(equalTo: guide.topAnchor)
                    : hosting.view.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            ])
            hosting.didMove(toParent: self)
            huds.append(hosting)
        }
        setMode(.live)
    }

    private func applySettingsToScene() {
        guard let scene else { return }
        scene.mode = hud.mode
        scene.sliderValue = hud.sliderValue
        scene.showLightning = hud.showLightning
        scene.extrapolate = hud.extrapolate
        scene.palette = userDefaults?.string(forKey: "radarColorMapping") ?? "classic"
    }

    private func setMode(_ mode: ARViewMode) {
        hud.mode = mode
        let value = sliderValues[mode] ?? mode.slider?.initial ?? 0
        hud.sliderValue = value
        scene?.mode = mode
        scene?.sliderValue = value
        refreshSliderText()
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func setSlider(_ value: Double) {
        hud.sliderValue = value
        sliderValues[hud.mode] = value
        scene?.sliderValue = value
        refreshSliderText()
    }

    private func refreshSliderText() {
        guard let slider = hud.mode.slider else { hud.sliderText = ""; return }
        let value = hud.sliderValue
        let number: String
        switch hud.mode {
        case .peel:
            if let key = scene?.selectedKey, let group = groups.first(where: { $0.key == key }) {
                number = String(format: "%.0f", StormVolume.dbzLow + value * (group.peelFloor - StormVolume.dbzLow))
            } else {
                hud.sliderText = String(format: "%.0f %%", value * 100)
                return
            }
        case .slice, .track, .turn:
            number = String(format: "%+.0f", value)
        default:
            number = String(format: "%.1f", value)
        }
        hud.sliderText = String(format: slider.format, number)
    }

    private func refreshBanner() {
        var banner: ARHUDModel.Banner?
        if renderer == nil {
            banner = .init(text: NSLocalizedString("ar_no_metal", comment: ""))
        } else if let (transient, until) = transientBanner, until > Date() {
            banner = transient
        } else if let locationProblem {
            banner = locationProblem
        } else if let tracking = arCamera?.tracking, tracking != .normal {
            switch tracking {
            case .cameraDenied:
                banner = .init(text: NSLocalizedString("ar_camera_denied", comment: ""),
                               actionTitle: NSLocalizedString("ar_open_settings", comment: ""))
            case .failed(let message): banner = .init(text: message)
            case .limited(let message): banner = .init(text: message)
            case .starting: banner = .init(text: NSLocalizedString("ar_tracking_starting", comment: ""))
            case .normal: break
            }
        } else if feed.status == .failed {
            banner = .init(text: NSLocalizedString("ar_feed_failed", comment: ""))
        } else if feed.status == .ready, scene != nil, feed.nearbyEntries.isEmpty {
            banner = .init(text: NSLocalizedString("ar_no_storms", comment: ""))
        }
        if hud.banner != banner { hud.banner = banner }
        refreshStatus()
    }

    private func refreshStatus() {
        switch feed.status {
        case .loading:
            hud.status = NSLocalizedString("ar_status_loading", comment: "")
        case .failed:
            hud.status = NSLocalizedString("ar_status_failed", comment: "")
        case .ready:
            let nearby = feed.nearbyEntries
            // Storms, not the tiles they are boxed in.
            var status = String(format: NSLocalizedString("ar_status_storms", comment: ""), Set(nearby.map(\.stormKey)).count)
            if let newest = nearby.compactMap(\.scanDate).max() {
                status += " · " + String(format: NSLocalizedString("ar_label_age", comment: ""), max(0, Int(Date().timeIntervalSince(newest) / 60)))
            }
            hud.status = status
        }
        if isPreview {
            // Where the preview stands goes here, not in a banner: a banner
            // that never goes away sits over the storms' tags.
            hud.alignment = previewPlacement ?? NSLocalizedString("ar_alignment_preview", comment: "")
            return
        }
        let correction = String(format: "%+.0f°", alignment.error)
        switch alignment.source {
        case .compass: hud.alignment = String(format: NSLocalizedString("ar_alignment_compass", comment: ""), correction)
        case .manual: hud.alignment = String(format: NSLocalizedString("ar_alignment_manual", comment: ""), correction)
        case .sun: hud.alignment = String(format: NSLocalizedString("ar_alignment_sun", comment: ""), correction)
        case .geoTracking: hud.alignment = NSLocalizedString("ar_alignment_geo", comment: "")
        }
    }

    private func showTransient(_ text: String) {
        transientBanner = (ARHUDModel.Banner(text: text), Date().addingTimeInterval(4))
        refreshBanner()
    }

    // MARK: Gestures

    private func installGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        [tap, pan, pinch].forEach(metalView.addGestureRecognizer)
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard let pose = lastPose, let scene else { return }
        let point = recognizer.location(in: metalView)
        if hud.sunFixArmed {
            hud.sunFixArmed = false
            sunFix(at: point, pose: pose, scene: scene)
            return
        }
        select(scene.pick(point, pose: pose, targets: drawn)?.key, toggle: false)
    }

    private func sunFix(at point: CGPoint, pose: CameraPose, scene: StormScene) {
        let (_, direction) = pose.ray(through: point)
        let sun = SunPosition.at(Date(), latitude: scene.frame.latitude, longitude: scene.frame.longitude)
        let result = alignment.sunFix(tappedAzimuth: StormScene.frameAzimuth(ofWorld: direction),
                                      tappedElevation: StormScene.elevation(ofWorld: direction), sun: sun)
        switch result {
        case .aligned(let correction):
            showTransient(String(format: NSLocalizedString("ar_sun_fix_done", comment: ""), correction))
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .sunBelowHorizon:
            showTransient(NSLocalizedString("ar_sun_fix_night", comment: ""))
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .notTheSun:
            showTransient(NSLocalizedString("ar_sun_fix_missed", comment: ""))
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        guard let pose = lastPose else { return }
        let translation = recognizer.translation(in: metalView)
        recognizer.setTranslation(.zero, in: metalView)
        let size = metalView.bounds.size
        let horizontal = pose.horizontalFOV
        let vertical = horizontal * Double(size.height / max(size.width, 1))
        if isPreview {
            // Drag the sky: the view follows the finger.
            preview.look(byYaw: -Double(translation.x / size.width) * horizontal,
                         pitch: Double(translation.y / size.height) * vertical)
        } else {
            // Drag the overlay sideways onto the real storm.
            alignment.nudge(by: Double(translation.x / size.width) * horizontal)
            if recognizer.state == .ended { refreshStatus() }
        }
    }

    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        guard isPreview else { return }
        preview.zoom(by: Double(recognizer.scale))
        recognizer.scale = 1
    }

    /// Select a storm by its key (`StormGroup.key`), or nothing.
    private func select(_ key: String?, toggle: Bool) {
        guard let scene else { return }
        let next = toggle && scene.selectedKey == key ? nil : key
        guard next != scene.selectedKey else { return }
        scene.selectedKey = next
        labelsBuiltAt = .distantPast
        refreshTrackAvailability()
        refreshSliderText()
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// Open a storm on the map: by its cell where it has one, otherwise by the
    /// tile holding its peak, which is the one the map names the storm by.
    private func openOnMap(_ key: String) {
        let tiles = feed.entries.filter { $0.stormKey == key }
        guard let peak = tiles.first(where: \.isStormPeak) ?? tiles.max(by: { ($0.peakDbz ?? 0) < ($1.peakDbz ?? 0) }) else { return }
        let cell = tiles.compactMap { feed.cell(for: $0) }.max { ($0.maxDbz ?? 0) < ($1.maxDbz ?? 0) }
        guard let search = MapLink.search(for: peak, cell: cell) else { return }
        let onOpen = onOpenOnMap, onClose = onClose
        dismiss(animated: true) {
            onClose?()
            onOpen?(search)
        }
    }

    // MARK: Per frame

    fileprivate func render(in view: MTKView) {
        guard let renderer else { return }
        let viewport = view.bounds.size
        let orientation = view.window?.windowScene?.effectiveGeometry.interfaceOrientation ?? .portrait
        let pose: CameraPose
        let background: StormRenderer.Background
        if let arCamera {
            guard let (current, frame) = arCamera.current(viewport: viewport, orientation: orientation) else { return }
            pose = current
            let transform = frame.displayTransform(for: orientation, viewportSize: viewport).inverted()
            background = .camera(frame.capturedImage, transform)
            if arCamera.tracking == .normal {
                alignment.update(frameAzimuth: StormScene.frameAzimuth(ofWorld: pose.forward))
            }
            checkGeoNorth(arCamera)
        } else {
            pose = preview.pose(viewport: viewport)
            background = .sky(horizonDip: GeoFrame.horizonDip(eyeAboveGround: 1.6))
        }
        lastPose = pose

        var storms: [StormRenderer.Storm] = []
        var lines: (under: [WorldLine], over: [WorldLine]) = ([], [])
        if let scene {
            scene.now = Date()
            scene.alignmentError = isPreview ? 0 : alignment.error
            feed.lookAzimuth = scene.trueAzimuth(ofWorld: pose.forward)
            placed = scene.placeAll(feed.nearbyEntries, volumes: feed.volumes) { [feed] in feed.cell(for: $0) }
            groups = scene.groups(placed)
            let groupByKey = Dictionary(uniqueKeysWithValues: groups.map { ($0.key, $0) })
            let light = scene.light()
            let target = CGSize(width: view.drawableSize.width * renderer.resolutionScale,
                                height: view.drawableSize.height * renderer.resolutionScale)
            let camera = SIMD3<Double>(pose.position)
            drawn = drawTargets(scene: scene, groupByKey: groupByKey)
            storms = drawn
                .compactMap { storm, group -> StormRenderer.Storm? in
                    // A box with no echo in it draws nothing; skip it outright.
                    guard let volume = storm.volume, volume.marchBounds != nil else { return nil }
                    let uniforms = scene.uniforms(for: storm, group: group, volume: volume, pose: pose, target: target, light: light)
                    let centre = storm.centre + storm.up * 6_000
                    return StormRenderer.Storm(path: storm.entry.path, volume: volume, uniforms: uniforms,
                                               boxToWorld: simd_float4x4(converting: storm.boxToWorld),
                                               distance: Float(length(centre - camera)),
                                               system: storm.entry.coarse == true ? storm.entry.path : storm.stormKey)
                }
            lines = scene.lines(groups: groups, feed: feed, pose: pose)
        }
        renderer.retain(only: Set(feed.volumes.keys))
        renderer.draw(StormRenderer.Frame(background: background, pose: pose, storms: storms,
                                          under: lines.under, over: lines.over), in: view)
        updateOverlays(pose: pose)
    }

    /// What to draw, from the feed's plan: a fine tile with its own storm, a
    /// coarse tile with the storm most of the fine tiles inside it belong to.
    private func drawTargets(scene: StormScene, groupByKey: [String: StormGroup]) -> [(storm: PlacedStorm, group: StormGroup)] {
        let placedByPath = Dictionary(placed.map { ($0.entry.path, $0) }, uniquingKeysWith: { first, _ in first })
        return feed.drawPlan().compactMap { unit -> (storm: PlacedStorm, group: StormGroup)? in
            if unit.coarse != true {
                guard let storm = placedByPath[unit.path], let group = groupByKey[storm.stormKey] else { return nil }
                return (storm, group)
            }
            let inside = placed.filter { $0.entry.coarseParent == unit.tile }
            var count: [String: Int] = [:]
            for storm in inside { count[storm.stormKey, default: 0] += 1 }
            guard let key = count.max(by: { a, b in a.value != b.value ? a.value < b.value
                      : (groupByKey[a.key]?.peakDbz ?? 0) < (groupByKey[b.key]?.peakDbz ?? 0) })?.key,
                  let group = groupByKey[key] else { return nil }
            return (scene.place(unit, volume: feed.volumes[unit.path], cell: group.cell), group)
        }
    }

    private func checkGeoNorth(_ camera: ARKitCamera) {
        guard camera.usesGeoTracking, camera.geoLocalized, Date().timeIntervalSince(geoNorthCheckedAt) > 2 else { return }
        geoNorthCheckedAt = Date()
        Task { [weak self] in
            guard let north = await camera.geoNorth() else { return }
            self?.alignment.geoTracked(trueNorthAzimuth: north)
        }
    }

    private func updateOverlays(pose: CameraPose) {
        guard let scene else {
            labelLayer.layout([])
            labelLayer.layoutTicks([])
            return
        }
        let now = Date()
        if now.timeIntervalSince(labelsBuiltAt) > 0.5 {
            labelModels = Dictionary(uniqueKeysWithValues: groups.map { ($0.key, scene.label(for: $0, feed: feed)) })
            labelsBuiltAt = now
        }
        // One tag per storm, however many tiles it covers.
        labelLayer.layout(groups.compactMap { group in
            labelModels[group.key].map { ($0, pose.project(SIMD3<Float>(group.anchor))) }
        })
        let selected = groups.first { $0.key == scene.selectedKey }
        labelLayer.layoutTicks(selected.map { group in
            scene.heightTicks(for: group, pose: pose).map { ($0.km, pose.project($0.point)) }
        } ?? [])

        guard now.timeIntervalSince(hudUpdatedAt) > 0.1 else { return }
        hudUpdatedAt = now
        hud.heading = scene.trueAzimuth(ofWorld: pose.forward)
        hud.guidance = guidance(pose: pose, scene: scene, selected: selected)
        if now.timeIntervalSince(labelsBuiltAt) < 0.11 { refreshBanner() }
    }

    /// Which way to turn to bring the selected storm into view, while it is not.
    private func guidance(pose: CameraPose, scene: StormScene, selected: StormGroup?) -> ARHUDModel.Guidance? {
        guard let selected else { return nil }
        if let point = pose.project(SIMD3<Float>(selected.anchor)), metalView.bounds.insetBy(dx: 20, dy: 20).contains(point) {
            return nil
        }
        let degrees = Geo.angleDifference(selected.bearing, hud.heading)
        guard abs(degrees) > pose.horizontalFOV / 2 - 5 else { return nil }
        let format = NSLocalizedString(degrees < 0 ? "ar_turn_left" : "ar_turn_right", comment: "")
        return ARHUDModel.Guidance(degrees: degrees, text: String(format: format, abs(degrees)))
    }
}

extension ARStormViewController: MTKViewDelegate {
    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { render(in: view) }
    }
}
