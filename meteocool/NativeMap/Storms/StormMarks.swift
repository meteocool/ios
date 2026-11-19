//
//  StormMarks.swift
//  meteocool
//
//  Tracked storms on the native map: core's `lib/StormManager.ts` (drawing
//  half), `layers/cells.ts`, `layers/cellPulse.ts` and the systems'
//  outlines of `layers/stormGroups.ts`; changes eased by
//  `lib/stormEasing.ts` (`StormEasing`).
//

import Combine
import MapKit
import UIKit

/// Severity colours (`layers/cells.ts`).
enum StormStyle {
    static let colours: [UIColor] = [
        UIColor(red: 0x2f / 255, green: 0x9e / 255, blue: 0x44 / 255, alpha: 1),
        UIColor(red: 0xf0 / 255, green: 0xb4 / 255, blue: 0x29 / 255, alpha: 1),
        UIColor(red: 0xe0 / 255, green: 0x31 / 255, blue: 0x31 / 255, alpha: 1),
        UIColor(red: 0x9c / 255, green: 0x36 / 255, blue: 0xb5 / 255, alpha: 1),
    ]
    static let hail = colours[2]

    static func colour(_ severity: Int) -> UIColor { colours[max(0, min(severity, 3))] }

    /// Under a track (`casing.ts`): light on light maps, dark on the dark one.
    static func casing(dark: Bool) -> UIColor {
        dark ? UIColor(red: 12 / 255, green: 16 / 255, blue: 22 / 255, alpha: 0.75) : UIColor(white: 1, alpha: 0.75)
    }

    /// The live ring's ink: the other way round from the casing.
    static func ringInk(dark: Bool) -> UIColor {
        dark ? UIColor(white: 1, alpha: 0.95) : UIColor(red: 17 / 255, green: 20 / 255, blue: 26 / 255, alpha: 0.9)
    }
}

/// The marks drawn as lines and shapes, shared with MapKit's drawing threads.
final class StormOverlay: NSObject, MKOverlay, @unchecked Sendable {
    /// A mark as a transition draws it (`StormEasing`).
    struct Shown: Equatable {
        var mark: StormMark
        /// How far it has faded in, 0 to 1; 1 at rest.
        var fade: Double = 1
        /// Fading out for good: not tapped.
        var leaving = false
    }

    struct Scene: Equatable {
        var marks: [Shown] = []
        var picked: String?
        var dark = false
    }

    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let boundingMapRect = MKMapRect.world
    private let lock = NSLock()
    private var current = Scene()

    var scene: Scene {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    static func point(_ p: LonLat) -> CGPoint {
        let m = MKMapPoint(CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon))
        return CGPoint(x: m.x, y: m.y)
    }
}

/// Links, paths, outlines, forecast dots and ellipses, in core's order and
/// styles, at screen widths whatever the zoom.
final class StormMapRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let scene = (overlay as? StormOverlay)?.scene else { return }
        let px = 1 / zoomScale
        let casing = StormStyle.casing(dark: scene.dark)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for shown in scene.marks where shown.fade > 0 {
            let mark = shown.mark
            let picked = mark.storm == scene.picked || (mark.kind == .link && mark.fromStorm == scene.picked)
            // The age fade and the transition's together, in tenths as core
            // buckets them (`opacityOf`); the selected storm's by the
            // transition alone.
            let fade = StormDrawing.jsRound(shown.fade * 10) / 10
            let o = StormDrawing.jsRound(StormDrawing.ageOpacity(mark.ageMinutes) * fade * 10) / 10
            let colour = StormStyle.colour(mark.severity)
            let s = CGFloat(mark.severity)
            switch (mark.kind, mark.geometry) {
            case (.path, .line(let line)):
                let path = Self.line(line)
                let width = (picked ? 3 : 2) + s
                stroke(path, colour: casing.withAlphaComponent(casing.cgColor.alpha * (picked ? fade : o)), width: (width + 4) * px, in: context)
                stroke(path, colour: colour.withAlphaComponent(picked ? fade : o), width: width * px, in: context)
            case (.link, .line(let line)):
                context.setLineDash(phase: 0, lengths: [1 * px, 6 * px])
                stroke(Self.line(line), colour: colour.withAlphaComponent(picked ? 0.95 * fade : 0.7 * o),
                       width: ((picked ? 2.5 : 1.5) + 0.5 * s) * px, in: context)
                context.setLineDash(phase: 0, lengths: [])
            case (.outline, .polygon(let ring)):
                guard StormDrawing.outlineIsCurrent(mark.ageMinutes) else { continue }
                stroke(Self.ring(ring), colour: colour.withAlphaComponent(0.6 * o), width: 1.5 * px, in: context)
            case (.ellipse, .polygon(let ring)):
                guard picked else { continue }
                let path = Self.ring(ring)
                context.setLineDash(phase: 0, lengths: [7 * px, 5 * px])
                stroke(path, colour: casing.withAlphaComponent(casing.cgColor.alpha * fade), width: 4 * px, in: context)
                stroke(path, colour: colour.withAlphaComponent(0.95 * fade), width: 2 * px, in: context)
                context.setLineDash(phase: 0, lengths: [])
            case (.forecast, .point(let at)):
                guard picked else { continue }
                let c = StormOverlay.point(at)
                let dot = CGRect(x: c.x - 3 * px, y: c.y - 3 * px, width: 6 * px, height: 6 * px)
                context.setFillColor(colour.withAlphaComponent(0.95 * fade).cgColor)
                context.fillEllipse(in: dot)
                context.setStrokeColor(casing.withAlphaComponent(casing.cgColor.alpha * fade).cgColor)
                context.setLineWidth(1.5 * px)
                context.strokeEllipse(in: dot)
            default:
                continue
            }
        }
    }

    private func stroke(_ path: CGPath, colour: UIColor, width: CGFloat, in context: CGContext) {
        context.addPath(path)
        context.setStrokeColor(colour.cgColor)
        context.setLineWidth(width)
        context.strokePath()
    }

    private static func line(_ points: [LonLat]) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points.map(StormOverlay.point))
        return path
    }

    private static func ring(_ points: [LonLat]) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points.map(StormOverlay.point))
        path.closeSubpath()
        return path
    }
}

/// The storms that are one system, as one outline round the area they
/// share (core's `layers/stormGroups.ts`), shared with MapKit's drawing
/// threads.
final class StormGroupOverlay: NSObject, MKOverlay, @unchecked Sendable {
    struct Shown: Equatable {
        var outline: GroupOutline
        /// How far it has faded in, 0 to 1; 1 at rest.
        var fade: Double = 1
    }

    struct Scene {
        /// Each outline, with how far it has faded in.
        var outlines: [Shown] = []
        /// The accent, resolved for the basemap and the contrast setting.
        var accent = UIColor.systemBlue.cgColor
        var dark = false
    }

    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let boundingMapRect = MKMapRect.world
    private let lock = NSLock()
    private var current = Scene()

    var scene: Scene {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

/// Content on the map, not chrome, and the quietest thing about a storm: a
/// thin line in the system accent with a wash of it a few percent strong.
/// The radar's ramp runs from green through yellow and red to purple, and
/// the storms' marks are drawn in it; a blue that is none of those stays
/// apart from both. Over the radar and its sweeps, under the lightning and
/// the storms; nothing on it is tapped.
final class StormGroupRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let scene = (overlay as? StormGroupOverlay)?.scene else { return }
        let px = 1 / zoomScale
        let reach = mapRect.insetBy(dx: -4 * px, dy: -4 * px)
        context.setLineJoin(.round)
        context.setLineWidth(1.5 * px)
        for shown in scene.outlines where shown.fade > 0 {
            let outline = shown.outline
            // In tenths, as core's styles are cached.
            let fade = StormDrawing.jsRound(shown.fade * 10) / 10
            let path = CGMutablePath()
            for polygon in outline.polygons {
                for ring in polygon where ring.count > 2 {
                    path.addLines(between: ring.map(StormOverlay.point))
                    path.closeSubpath()
                }
            }
            guard path.boundingBox.intersects(CGRect(x: reach.minX, y: reach.minY, width: reach.width, height: reach.height)) else { continue }
            context.addPath(path)
            context.setFillColor(scene.accent.copy(alpha: (scene.dark ? 0.07 : 0.05) * fade) ?? scene.accent)
            context.fillPath(using: .evenOdd)
            context.addPath(path)
            context.setStrokeColor(scene.accent.copy(alpha: (scene.dark ? 0.8 : 0.7) * fade) ?? scene.accent)
            context.strokePath()
        }
    }
}

/// A storm's centroid, as its disc on the map.
final class StormAnnotation: NSObject, MKAnnotation {
    struct Look: Equatable {
        var severity: Int
        var hail: Bool
        var meso: Bool
        var picked: Bool
        var opacity: Double
        var live: Bool
        var dark: Bool
        /// DWD's storm: a diamond, where meteocool's is a circle.
        var dwd = false
        /// Not one the backend marks: a small dot (`StormDrawing.stormLook`).
        var quiet = false
    }

    /// The storm it is.
    let id: String
    /// Moved while its storm slides (`StormEasing`); MapKit follows.
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var look: Look
    /// How far it has faded in, 0 to 1; 1 at rest.
    var fade: Double
    /// Fading out for good: not tapped, not read out.
    var leaving: Bool

    init(id: String, coordinate: CLLocationCoordinate2D, look: Look, fade: Double = 1, leaving: Bool = false) {
        self.id = id
        self.coordinate = coordinate
        self.look = look
        self.fade = fade
        self.leaving = leaving
    }

    var label: String {
        CoreStrings.t("storm.storm_label.\(StormRules.bandNames[max(0, min(look.severity, 3))])")
    }
}

/// The disc: radius by severity, a diamond for DWD's storms (core's
/// `DIAMOND_REACH`), outlined red for hail, a ↻ or ✦ badge, and for a live
/// storm the stepping dashed ring under it. A quiet storm is a small pale
/// dot, with no badge and no ring, still there to be tapped.
final class StormDiscView: MKAnnotationView {
    static let reuse = "storm"
    let ring = CAShapeLayer()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        displayPriority = .required
        collisionMode = .none
        canShowCallout = false
        // Over the other marks, under the "3D" tags beside them, as core
        // stacks its cells (202) under the tags (203).
        zPriority = MKAnnotationViewZPriority(rawValue: 850)
        layer.addSublayer(ring)
        isAccessibilityElement = true
        accessibilityTraits = .button
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var annotation: MKAnnotation? { didSet { update() } }

    /// A quiet storm's dot: how far it reaches, points (core's `QUIET_RADIUS`).
    static let quietRadius: CGFloat = 3

    func update() {
        guard let storm = annotation as? StormAnnotation else { return }
        let look = storm.look
        let s = CGFloat(max(0, min(look.severity, 3)))
        let radius = look.quiet ? Self.quietRadius : (look.picked ? 8 : 6) + 2 * s
        let badge = look.meso ? "↻" : look.hail ? "✦" : nil
        let side = max(radius * (look.dwd ? 2.6 : 2) + 8, CGFloat(StormPulse.ringRadius * 2 + StormPulse.ringWidth) + 4)
        let height = side + (badge == nil ? 0 : 36)
        let size = CGSize(width: side, height: height)
        let colour = StormStyle.colour(look.severity)
        let o = CGFloat(look.opacity)
        image = UIGraphicsImageRenderer(size: size).image { _ in
            let centre = CGPoint(x: size.width / 2, y: size.height - side / 2)
            let disc: UIBezierPath
            if look.dwd {
                let reach = radius * 1.3
                disc = UIBezierPath()
                disc.move(to: CGPoint(x: centre.x, y: centre.y - reach))
                disc.addLine(to: CGPoint(x: centre.x + reach, y: centre.y))
                disc.addLine(to: CGPoint(x: centre.x, y: centre.y + reach))
                disc.addLine(to: CGPoint(x: centre.x - reach, y: centre.y))
                disc.close()
                disc.lineJoinStyle = .round
            } else {
                disc = UIBezierPath(arcCenter: centre, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: true)
            }
            if look.quiet {
                // Paler, cased in the basemap's colour rather than white, so
                // it does not light up on the dark map; the shape still tells
                // DWD's from meteocool's.
                colour.withAlphaComponent(0.6 * o).setFill()
                disc.fill()
                let casing = StormStyle.casing(dark: look.dark)
                casing.withAlphaComponent(casing.cgColor.alpha * o).setStroke()
                disc.lineWidth = 1
                disc.stroke()
                return
            }
            colour.withAlphaComponent((look.picked ? 1 : 0.75) * o).setFill()
            disc.fill()
            (look.hail ? StormStyle.hail : UIColor.white).withAlphaComponent(o).setStroke()
            disc.lineWidth = look.picked ? 3.5 : (look.hail ? 3 : 1.5)
            disc.stroke()
            if let badge {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 13, weight: .bold),
                    .foregroundColor: colour.withAlphaComponent(o),
                    .strokeColor: UIColor.white.withAlphaComponent(o),
                    .strokeWidth: -3.0,
                ]
                let text = badge as NSString
                let textSize = text.size(withAttributes: attributes)
                text.draw(at: CGPoint(x: centre.x - textSize.width / 2, y: centre.y - 16 - textSize.height / 2), withAttributes: attributes)
            }
        }
        // The disc's centre on the storm.
        centerOffset = CGPoint(x: 0, y: -(height - side) / 2)
        // The live ring: dashes laid on whole periods so it closes seamlessly.
        let r = CGFloat(StormPulse.ringRadius)
        let scale = (2 * CGFloat.pi * r) / CGFloat(StormPulse.ringPathLength)
        // Bounds and position, not frame: the ring is turned, and a turned
        // layer's frame is not where it is.
        ring.bounds = CGRect(x: 0, y: 0, width: 2 * r + 4, height: 2 * r + 4)
        ring.position = CGPoint(x: size.width / 2, y: size.height - side / 2)
        ring.path = UIBezierPath(ovalIn: CGRect(x: 2, y: 2, width: 2 * r, height: 2 * r)).cgPath
        ring.fillColor = nil
        ring.strokeColor = StormStyle.ringInk(dark: look.dark).cgColor
        ring.lineWidth = CGFloat(StormPulse.ringWidth)
        ring.lineDashPattern = [NSNumber(value: Double(5 * scale)), NSNumber(value: Double(4 * scale))]
        ring.isHidden = !look.live
        ring.zPosition = -1
        alpha = CGFloat(storm.fade)
        isUserInteractionEnabled = !storm.leaving
        isAccessibilityElement = !storm.leaving
        accessibilityLabel = storm.label
        accessibilityIdentifier = storm.leaving ? nil : "nativeMap.storm.\(storm.id)"
        accessibilityTraits = look.picked ? [.button, .selected] : .button
        #if DEBUG
        // How it is drawn, for UI tests: quiet, or ringed as still being seen.
        accessibilityValue = look.quiet ? "quiet" : look.live ? "live" : nil
        #endif
    }
}

/// A forecast ring's lead time, "+8 min", above its leading edge.
final class StormLeadAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let text: String
    let severity: Int
    let dark: Bool

    init(coordinate: CLLocationCoordinate2D, text: String, severity: Int, dark: Bool) {
        (self.coordinate, self.text, self.severity, self.dark) = (coordinate, text, severity, dark)
    }
}

final class StormLeadView: MKAnnotationView {
    static let reuse = "stormLabel"

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        displayPriority = .required
        collisionMode = .none
        isUserInteractionEnabled = false
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var annotation: MKAnnotation? { didSet { update() } }

    private func update() {
        guard let label = annotation as? StormLeadAnnotation else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: StormStyle.colour(label.severity),
            .strokeColor: StormStyle.casing(dark: label.dark),
            .strokeWidth: -3.0,
        ]
        let text = label.text as NSString
        let size = text.size(withAttributes: attributes)
        image = UIGraphicsImageRenderer(size: CGSize(width: size.width + 4, height: size.height + 2)).image { _ in
            text.draw(at: CGPoint(x: 2, y: 1), withAttributes: attributes)
        }
        centerOffset = CGPoint(x: 0, y: -9)
    }
}

/// The storm layer: fetches and holds `/storms`, draws core's marks, steps
/// the live rings, routes taps to the selection, and opens the sheet.
@MainActor
final class StormMarks: NativeMapFeature {
    let store = StormStore()
    private weak var map: NativeMapContext?
    private let overlay = StormOverlay()
    private let groupOverlay = StormGroupOverlay()
    private var added = false
    private var discs: [String: StormAnnotation] = [:]
    private var labels: [StormLeadAnnotation] = []
    private var drawn = StormDrawingResult()
    private var crowded = Set<String>()
    private var ringTimer: Timer?
    private var labelTimer: Timer?
    private var moving = false
    private var sheet: StormSheet?
    /// What the selection was when last drawn.
    private var drawnFor = ""

    func attach(to map: NativeMapContext) {
        self.map = map
        store.map = map
        map.mapView.register(StormDiscView.self, forAnnotationViewWithReuseIdentifier: StormDiscView.reuse)
        map.mapView.register(StormLeadView.self, forAnnotationViewWithReuseIdentifier: StormLeadView.reuse)
        sheet = StormSheet(store: store, map: map)
        settingsDidChange()
        startRings()
        observe()
    }

    private var observers: [Any] = []

    /// Redraws when the store changes what is drawn.
    private func observe() {
        let a = store.$revision.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, let change = self.store.takeChange() else { return }
                self.redraw(change)
            }
        }
        let b = store.$selection.sink { [weak self] selection in
            DispatchQueue.main.async {
                self?.map?.model.selectedStorm = selection?.id
                let opened = selection.map(OpenedStorm.init)
                if self?.map?.model.opened != opened { self?.map?.model.opened = opened }
                if self?.map?.model.stormOpen != (selection != nil) { self?.map?.model.stormOpen = selection != nil }
                // Only a change of storm, cell or forecast redraws: a newer
                // copy of the same storm comes with an answer, which eases.
                let key = "\(StormSelect.selectionKey(selection))|\(selection?.cell?.code ?? "")|\(selection?.summary == nil ? 0 : 1)"
                if self?.drawnFor != key {
                    self?.drawnFor = key
                    self?.redraw()
                }
                self?.sheet?.update()
                self?.endDetour()
            }
        }
        let c = store.$details.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.sheet?.update()
                self?.endDetour()
            }
        }
        // Another part cleared the selection (a hold on the map, the model
        // comparison): the store follows. Only a storm's id is mirrored, so a
        // cell still being resolved is left alone.
        let d = map?.model.$selectedStorm.dropFirst().sink { [weak self] id in
            DispatchQueue.main.async {
                guard let self, id == nil, self.map?.model.selectedStorm == nil,
                      let selection = self.store.selection, selection.id != nil else { return }
                self.store.selection = nil
            }
        }
        let e = map?.model.$volumeRequest.compactMap { $0 }.sink { [weak self] volume in
            DispatchQueue.main.async {
                guard let self else { return }
                self.map?.model.volumeRequest = nil
                self.store.openVolume(volume, details: true)
            }
        }
        let f = map?.model.$volumes.sink { [weak self] volumes in
            DispatchQueue.main.async { self?.store.offerVolumes(volumes) }
        }
        observers = [a, b, c] + (d.map { [$0] } ?? []) + (e.map { [$0] } ?? []) + (f.map { [$0] } ?? [])
        // What the map key turned off.
        if let hidden = map?.model.$hiddenStormMarks.dropFirst().sink(receiveValue: { [weak self] _ in
            DispatchQueue.main.async { self?.redraw() }
        }) {
            observers.append(hidden)
        }
    }

    /// A storm opened on the 3D map from the flat one, closed: back to the
    /// map and the view it came from (core's `returnFrom3D`). Closing means
    /// its panel going, which on a phone can leave it selected.
    private func endDetour() {
        guard let map, map.model.capability == .cells3d, let origin = map.model.detour,
              store.selection == nil || !store.details else { return }
        map.model.detour = nil
        map.setCapability(origin.capability)
        // After the tray is back: the camera's centre is the middle of the
        // map above it, as when it was saved.
        // MapKit centres the camera inside the map's margins, which the tray
        // sets as it comes back; set again once it has, or the view lands
        // half a tray off.
        if let camera = origin.camera {
            for delay in [0.0, 0.35] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak map] in
                    map?.view.layoutIfNeeded()
                    map?.mapView.setCamera(camera, animated: false)
                }
            }
        }
    }

    private var visible: Bool {
        guard let map else { return false }
        return map.isOn(.storms) && map.model.capability == .radar
    }

    func settingsDidChange() {
        guard let map else { return }
        if visible != added {
            added = visible
            if visible {
                // The systems over the radar and its sweeps, under the labels,
                // the lightning and the storms.
                map.mapView.addOverlay(groupOverlay, level: .aboveRoads)
                map.mapView.addOverlay(overlay, level: .aboveLabels)
            } else {
                map.mapView.removeOverlays([groupOverlay, overlay])
            }
        }
        // The 3D map keeps the storm it opened.
        if !visible, map.model.capability != .cells3d { store.selection = nil }
        redraw()
    }

    func stepDidChange(_ step: RadarStep) {
        // The 3D map keeps the storm it opened, whatever the flat map's
        // timeline does meanwhile (a new scan landing, say).
        if map?.model.capability == .cells3d { return }
        if !visible || step.isForecast {
            store.show(.hidden)
        } else if step.isLive || step.time == nil {
            // A new scan on the live step: the storms' ages count from it.
            if store.frame == .now { redraw(.update) }
            store.show(.now)
        } else if let time = step.time {
            store.show(.at(Double(time) * 1000))
        }
    }

    func regionDidChange() {
        moving = false
        store.reload()
        // A zoom lays the rings out anew; a pan leaves the marks as they are.
        if laidAt != resolution { redraw() }
    }

    func wake() { store.refresh() }

    /// A window's storms are every one that overlapped it, rewound to each
    /// step (`stepDidChange` shows them at it: no step of a window is live).
    func windowDidChange(_ window: RadarWindow?) { store.setWindow(window) }

    func socketEvent(_ name: String, _ data: Data) {
        if name == "storms" { store.refresh() }
    }

    func renderer(for overlay: MKOverlay) -> MKOverlayRenderer? {
        if overlay === groupOverlay { return StormGroupRenderer(overlay: overlay) }
        return overlay === self.overlay ? StormMapRenderer(overlay: overlay) : nil
    }

    func view(for annotation: MKAnnotation, in mapView: MKMapView) -> MKAnnotationView? {
        switch annotation {
        case is StormAnnotation: return mapView.dequeueReusableAnnotationView(withIdentifier: StormDiscView.reuse, for: annotation)
        case is StormLeadAnnotation: return mapView.dequeueReusableAnnotationView(withIdentifier: StormLeadView.reuse, for: annotation)
        default: return nil
        }
    }

    /// A tap on a mesocyclone's ring: the tracked storm it turns in, as
    /// drawn (`MesocycloneRules`), as though that storm were tapped.
    func openStorm(atMesocyclone coordinate: CLLocationCoordinate2D) -> Bool {
        guard visible, store.frame != .hidden,
              let id = MesocycloneRules.stormAt(drawn.live, lon: coordinate.longitude, lat: coordinate.latitude) else { return false }
        store.tapped(id)
        return true
    }

    func didSelect(_ annotation: MKAnnotation) -> Bool {
        guard let storm = annotation as? StormAnnotation else { return false }
        map?.mapView.deselectAnnotation(annotation, animated: false)
        store.tapped(storm.id)
        return true
    }

    /// A tap on a line, a ring or a forecast dot within 6 pt picks its storm
    /// (a link picks the storm it leads into); anywhere else clears.
    func didTap(at coordinate: CLLocationCoordinate2D, point: CGPoint) -> Bool {
        guard visible, let map else { return false }
        if let code = hit(point, in: map.mapView) {
            store.tapped(code)
            return true
        }
        if store.selection != nil { store.tapped(nil) }
        return false
    }

    func open(_ link: [String: String]) -> Bool {
        let details = link["details"] != "0"
        let cut = CutAngle.fromLink(link["cut"])
        if let id = link["storm"], !id.isEmpty {
            map?.setOn(.storms, true)
            opening(cut, same: store.selection?.id == id) { store.open(id: id, details: details) }
            return true
        }
        if let code = link["cell"], !code.isEmpty {
            map?.setOn(.storms, true)
            opening(cut, same: store.selection?.cell?.code == code) { store.openCell(code: code, details: details) }
            return true
        }
        // A box of sky opens on the 3D map only, where it is drawn.
        if let cloud = link["cloud"], map?.model.capability == .cells3d, let path = NativeMapLink.cloudPath(cloud) {
            opening(cut, same: store.selection?.volume?.path == path) { store.openCloud(path: path, details: details) }
            return true
        }
        return false
    }

    /// A link's slice: turned now on the storm already open, else held for
    /// the one the link opens, which would otherwise open along its track.
    private func opening(_ cut: Double?, same: Bool, _ open: () -> Void) {
        if same {
            open()
            if let cut { map?.model.cut.set(cut) }
        } else {
            store.linkCut = cut
            open()
        }
    }

    func linkParameters() -> [String: String] {
        guard let selection = store.selection else { return [:] }
        var out: [String: String] = [:]
        if let id = selection.id {
            out["storm"] = id
        } else if let cell = selection.cell {
            out["cell"] = cell.code
        } else if let volume = selection.volume, map?.model.capability == .cells3d, let cloud = NativeMapLink.cloudLink(volume.path) {
            out["cloud"] = cloud
        }
        if !store.details { out["details"] = "0" }
        // Only a storm with a volume has a slice to turn.
        let tracked = selection.id != nil || selection.cell != nil
        if selection.cell?.volume != nil || selection.volume != nil, tracked || map?.model.capability == .cells3d,
           let cut = map.flatMap({ CutAngle.toLink($0.model.cut.angle) }) {
            out["cut"] = cut
        }
        return out
    }

    func stop() {
        sheet?.dismiss()
    }

    /// Drops the selection, its panel put away first (`StormSheet.close`).
    func dropSelection(then: @escaping () -> Void) {
        guard store.selection != nil, let sheet else { then(); return }
        sheet.close(then: then)
    }

    // MARK: - Drawing

    private var resolution: Double { StormPulse.resolution(zoom: map?.zoomLevel ?? 6) }

    /// The storm marks' transition and the systems' outlines', running or
    /// settled on what is drawn (`StormEasing`).
    private var markEasings: [Easing<StormMark>] = []
    private var outlineEasings: [Easing<GroupOutline>] = []
    /// When the running transition began (s of media time), nil with none.
    private var easingSince: CFTimeInterval?
    private lazy var ticker = FrameTicker { [weak self] in self?.frame() }
    /// How long a transition lasts, ms; UI tests slow it down to watch one
    /// (`MC_STORM_EASE_MS`).
    private let easeMs: Double = {
        #if DEBUG
        if let ms = ProcessInfo.processInfo.environment["MC_STORM_EASE_MS"].flatMap(Double.init) { return ms }
        #endif
        return StormEasing.durationMs
    }()
    /// Counts transitions, so what starts leaving in one has keys of its own.
    private var seq = 0
    /// Whether anything has been drawn since the storms were last dropped:
    /// a first drawing appears at once.
    private var drawnOnce = false
    /// What every mark of a drawing is drawn against.
    private var context = (picked: String?.none, dark: false, live: Set<String>())
    /// The resolution the marks were laid out for: a pan alone leaves them.
    private var laidAt: Double?

    /// What decides how a mark looks: a change of it cross-fades.
    private static func lookOf(_ mark: StormMark) -> String {
        mark.kind == .position || mark.kind == .path
            ? "\(mark.kind):\(mark.quiet):\(mark.severity):\(mark.hail):\(mark.meso):\(mark.source)"
            : "\(mark.kind):\(mark.severity):\(mark.source)"
    }

    /// Builds core's marks for the frame on screen and puts them on the map:
    /// eased from what is drawn for a new answer or scan, and for a step of
    /// the player unless it came hard on the one before; at once for a change
    /// of what is viewed (a selection, the map key, a zoom), and for
    /// everything under Reduce Motion.
    private func redraw(_ change: StormStore.Change = .view) {
        guard let map else { return }
        let mapView = map.mapView
        guard visible, store.frame != .hidden, change != .drop else {
            dropDrawing()
            if change == .drop { redraw() }
            return
        }
        let now = Date().timeIntervalSince1970 * 1000
        let reference = StormPulse.reference(at: store.at, newestScan: map.player.timeline.now, clock: now)
        drawn = StormDrawing.drawStorms(store.held, now: reference, reference: reference, selection: store.selection, at: store.at,
                                        hidden: map.model.hiddenStormMarks)
        let picked = StormDrawing.selectedMark(store.selection)
        let resolution = self.resolution
        laidAt = resolution
        let showsEnded = StormPulse.showsEnded(resolution)
        crowded = StormPulse.crowdedOut(drawn.pings.map { ping in
            let p = StormOverlay.point(ping.coordinates)
            let metres = 40_075_016.685578488 / MKMapSize.world.width
            return StormPulse.RingSpot(storm: ping.storm, x: p.x * metres, y: p.y * metres, severity: ping.severity,
                                       historyMinutes: ping.historyMinutes)
        }, resolution: resolution, selected: store.selection?.id)
        func shown(_ mark: StormMark) -> Bool {
            if crowded.contains(mark.storm) || mark.fromStorm.map(crowded.contains) == true { return false }
            if !mark.live, !showsEnded, mark.storm != picked, mark.fromStorm != picked { return false }
            return true
        }
        context = (picked, map.model.isDark, Set(drawn.pings.map(\.storm)))
        // Joins first, so the tracks and their marks draw over them.
        let marks = (drawn.links + drawn.marks).filter(shown).map { mark in
            EaseDrawn(key: mark.id, look: Self.lookOf(mark), moves: mark.kind == .position || mark.kind == .path,
                      shape: EaseShape(mark.geometry), value: mark)
        }
        let outlines = StormGroupRules.groupOutlines(store.groups, reference).map { outline in
            EaseDrawn(key: outline.id, look: "", moves: false, shape: .multiPolygon(outline.polygons), value: outline)
        }

        var stepGap: Double?
        if case .step(let gap) = change { stepGap = gap }
        let ease = change != .view
            && StormEasing.eases(reducedMotion: UIAccessibility.isReduceMotionEnabled, drawnBefore: drawnOnce, stepGap: stepGap)
        drawnOnce = true
        // Taken over from wherever a running transition has got to.
        let t = easingSince.map { (CACurrentMediaTime() - $0) * 1000 / easeMs } ?? 1
        seq += 1
        if ease {
            markEasings = StormEasing.plan(StormEasing.showingAt(markEasings, t), marks, seq: seq)
            outlineEasings = StormEasing.plan(StormEasing.showingAt(outlineEasings, t), outlines, seq: seq)
        } else {
            markEasings = StormEasing.settledOn(marks)
            outlineEasings = StormEasing.settledOn(outlines)
        }
        if ease && (StormEasing.animates(markEasings) || StormEasing.animates(outlineEasings)) {
            easingSince = CACurrentMediaTime()
            show(at: 0)
            ticker.start()
        } else {
            stopEasing()
            show(at: 1)
        }
        updateLabels(now: now, picked: picked, dark: context.dark)
    }

    /// One frame of the running transition.
    private func frame() {
        guard let since = easingSince else { return ticker.stop() }
        let t = (CACurrentMediaTime() - since) * 1000 / easeMs
        if t >= 1 { return settle() }
        show(at: StormEasing.easeOut(t))
    }

    /// End the running transition: everything where it was going, what was leaving gone.
    private func settle() {
        markEasings = StormEasing.settledOn(markEasings.filter { !$0.leaving }.map(\.item))
        outlineEasings = StormEasing.settledOn(outlineEasings.filter { !$0.leaving }.map(\.item))
        stopEasing()
        show(at: 1)
    }

    private func stopEasing() {
        easingSince = nil
        ticker.stop()
    }

    /// Puts the transitions on the map `e` of the way through (eased already):
    /// the lines and outlines redrawn when they changed, the discs moved and
    /// faded where they are.
    private func show(at e: Double) {
        guard let mapView = map?.mapView else { return }
        let (picked, dark, live) = context
        var lines: [StormOverlay.Shown] = []
        var wanted: [String: StormAnnotation] = [:]
        var added: [StormAnnotation] = []
        for easing in markEasings {
            let fade = easing.fromAlpha + (easing.toAlpha - easing.fromAlpha) * e
            var mark = easing.item.value
            if easing.from != easing.to { mark.geometry = StormEasing.shapeAt(easing.from, easing.to, e).markGeometry }
            guard mark.kind == .position else {
                // In tenths, as core's styles read it: a frame where no tenth
                // changed and nothing moved redraws nothing.
                lines.append(StormOverlay.Shown(mark: mark, fade: Self.tenths(fade), leaving: easing.leaving))
                continue
            }
            guard case .point(let at) = mark.geometry else { continue }
            let look = StormAnnotation.Look(severity: mark.severity, hail: mark.hail, meso: mark.meso, picked: mark.storm == picked,
                                            opacity: mark.storm == picked ? 1 : StormDrawing.ageOpacity(mark.ageMinutes),
                                            live: live.contains(mark.storm), dark: dark, dwd: mark.source == .dwd, quiet: mark.quiet)
            let coordinate = CLLocationCoordinate2D(latitude: at.lat, longitude: at.lon)
            // Kept from one drawing to the next, so playback does not flicker
            // them and a live ring stays the same ring while its storm slides.
            if let disc = discs[easing.key] {
                if disc.coordinate.latitude != at.lat || disc.coordinate.longitude != at.lon { disc.coordinate = coordinate }
                let restyled = disc.look != look || disc.leaving != easing.leaving
                let faded = disc.fade != fade
                disc.look = look
                disc.leaving = easing.leaving
                disc.fade = fade
                if let view = mapView.view(for: disc) as? StormDiscView {
                    if restyled { view.update() } else if faded { view.alpha = CGFloat(fade) }
                }
                wanted[easing.key] = disc
            } else {
                let disc = StormAnnotation(id: mark.storm, coordinate: coordinate, look: look, fade: fade, leaving: easing.leaving)
                wanted[easing.key] = disc
                added.append(disc)
            }
        }
        mapView.removeAnnotations(discs.filter { wanted[$0.key] == nil }.map(\.value))
        mapView.addAnnotations(added)
        discs = wanted

        let scene = StormOverlay.Scene(marks: lines, picked: picked, dark: dark)
        if scene != overlay.scene {
            overlay.scene = scene
            mapView.renderer(for: overlay)?.setNeedsDisplay()
        }
        let systems = outlineEasings.map { easing in
            StormGroupOverlay.Shown(outline: easing.item.value, fade: Self.tenths(easing.fromAlpha + (easing.toAlpha - easing.fromAlpha) * e))
        }
        let accent = Self.accent(dark: dark)
        if systems != groupOverlay.scene.outlines || groupOverlay.scene.dark != dark || groupOverlay.scene.accent != accent {
            groupOverlay.scene = StormGroupOverlay.Scene(outlines: systems, accent: accent, dark: dark)
            mapView.renderer(for: groupOverlay)?.setNeedsDisplay()
        }
    }

    private static func tenths(_ fade: Double) -> Double { StormDrawing.jsRound(fade * 10) / 10 }

    /// Drop everything drawn and any transition, so the next drawing appears at once.
    private func dropDrawing() {
        guard let mapView = map?.mapView else { return }
        stopEasing()
        markEasings = []
        outlineEasings = []
        drawnOnce = false
        overlay.scene = .init()
        groupOverlay.scene = .init()
        mapView.removeAnnotations(Array(discs.values) + labels)
        discs = [:]
        labels = []
        mapView.renderer(for: overlay)?.setNeedsDisplay()
        mapView.renderer(for: groupOverlay)?.setNeedsDisplay()
    }

    /// The system accent for the basemap, with Increase Contrast's variant.
    private static func accent(dark: Bool) -> CGColor {
        let traits = UITraitCollection { traits in
            traits.userInterfaceStyle = dark ? .dark : .light
            traits.accessibilityContrast = UIAccessibility.isDarkerSystemColorsEnabled ? .high : .normal
        }
        return UIColor.systemBlue.resolvedColor(with: traits).cgColor
    }

    /// The lead labels of the selected storm's forecast rings, counted from
    /// the clock and thinned by zoom; every 15 s while one is selected.
    private func updateLabels(now: Double, picked: String?, dark: Bool) {
        guard let mapView = map?.mapView else { return }
        mapView.removeAnnotations(labels)
        labels = drawn.marks.compactMap { mark in
            guard mark.kind == .ellipse, mark.storm == picked, let tip = mark.tip,
                  let text = StormDrawing.leadLabel(mark.forecastAt, mark.leadMinutes, resolution: resolution, now: now) else { return nil }
            return StormLeadAnnotation(coordinate: CLLocationCoordinate2D(latitude: tip.lat, longitude: tip.lon), text: text,
                                        severity: mark.severity, dark: dark)
        }
        mapView.addAnnotations(labels)
        labelTimer?.invalidate()
        guard !labels.isEmpty else { return }
        labelTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.updateLabels(now: Date().timeIntervalSince1970 * 1000, picked: self.context.picked, dark: self.context.dark)
            }
        }
    }

    /// Every ring turns one notch every 200 ms, off the wall clock, so all of
    /// them step together; still under Reduce Motion.
    private func startRings() {
        ringTimer?.invalidate()
        ringTimer = Timer.scheduledTimer(withTimeInterval: StormPulse.tickMs / 1000, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.stepRings() }
        }
    }

    private func stepRings() {
        guard let mapView = map?.mapView, !moving, !UIAccessibility.isReduceMotionEnabled else { return }
        let angle = StormPulse.ringAngle(Date().timeIntervalSince1970 * 1000) * .pi / 180
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for annotation in discs.values where annotation.look.live {
            (mapView.view(for: annotation) as? StormDiscView)?.ring.setAffineTransform(CGAffineTransform(rotationAngle: angle))
        }
        CATransaction.commit()
    }

    // MARK: - Hit testing

    /// Whether a tap lands on a storm the map draws.
    func hits(_ point: CGPoint) -> Bool {
        guard visible, let mapView = map?.mapView else { return false }
        return hit(point, in: mapView) != nil
    }

    /// The storm under a tap: lines and shapes within 6 pt of their stroke,
    /// forecast dots within 6 pt, topmost first.
    private func hit(_ point: CGPoint, in mapView: MKMapView) -> String? {
        let tolerance: CGFloat = 6
        func screen(_ p: LonLat) -> CGPoint {
            mapView.convert(CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon), toPointTo: mapView)
        }
        func near(_ points: [LonLat], closed: Bool) -> Bool {
            let s = points.map(screen)
            guard s.count > 1 else { return false }
            let pairs = zip(s, s.dropFirst()).map { ($0, $1) } + (closed ? [(s[s.count - 1], s[0])] : [])
            return pairs.contains { Self.distance(point, $0.0, $0.1) <= tolerance }
        }
        // Not a mark fading out for good: what it was is gone.
        for mark in overlay.scene.marks.reversed().filter({ !$0.leaving }).map(\.mark) {
            let hit: Bool
            switch mark.geometry {
            case .line(let line): hit = near(line, closed: false)
            case .polygon(let ring): hit = near(ring, closed: true)
            case .point(let at): hit = hypot(screen(at).x - point.x, screen(at).y - point.y) <= tolerance + 3
            }
            if hit { return mark.storm }
        }
        return nil
    }

    private static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = dx * dx + dy * dy
        let t = length == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

/// Calls back on every frame the screen draws while started, for a
/// transition of the marks.
@MainActor
private final class FrameTicker: NSObject {
    private var link: CADisplayLink?
    private let tick: @MainActor () -> Void

    init(_ tick: @escaping @MainActor () -> Void) {
        self.tick = tick
    }

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(fire))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func fire() { tick() }
}
