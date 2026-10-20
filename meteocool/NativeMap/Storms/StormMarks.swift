//
//  StormMarks.swift
//  meteocool
//
//  Tracked storms on the native map: core's `StormManager` (drawing half),
//  `layers/cells.ts` and `layers/cellPulse.ts`.
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
    struct Scene {
        var marks: [StormMark] = []
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
        for mark in scene.marks {
            let picked = mark.storm == scene.picked || (mark.kind == .link && mark.fromStorm == scene.picked)
            let o = StormDrawing.ageOpacity(mark.ageMinutes)
            let colour = StormStyle.colour(mark.severity)
            let s = CGFloat(mark.severity)
            switch (mark.kind, mark.geometry) {
            case (.path, .line(let line)):
                let path = Self.line(line)
                let width = (picked ? 3 : 2) + s
                stroke(path, colour: casing.withAlphaComponent(casing.cgColor.alpha * (picked ? 1 : o)), width: (width + 4) * px, in: context)
                stroke(path, colour: colour.withAlphaComponent(picked ? 1 : o), width: width * px, in: context)
            case (.link, .line(let line)):
                context.setLineDash(phase: 0, lengths: [1 * px, 6 * px])
                stroke(Self.line(line), colour: colour.withAlphaComponent(picked ? 0.95 : 0.7 * o),
                       width: ((picked ? 2.5 : 1.5) + 0.5 * s) * px, in: context)
                context.setLineDash(phase: 0, lengths: [])
            case (.outline, .polygon(let ring)):
                guard StormDrawing.outlineIsCurrent(mark.ageMinutes) else { continue }
                stroke(Self.ring(ring), colour: colour.withAlphaComponent(0.6 * o), width: 1.5 * px, in: context)
            case (.ellipse, .polygon(let ring)):
                guard picked else { continue }
                let path = Self.ring(ring)
                context.setLineDash(phase: 0, lengths: [7 * px, 5 * px])
                stroke(path, colour: casing, width: 4 * px, in: context)
                stroke(path, colour: colour.withAlphaComponent(0.95), width: 2 * px, in: context)
                context.setLineDash(phase: 0, lengths: [])
            case (.forecast, .point(let at)):
                guard picked else { continue }
                let c = StormOverlay.point(at)
                let dot = CGRect(x: c.x - 3 * px, y: c.y - 3 * px, width: 6 * px, height: 6 * px)
                context.setFillColor(colour.withAlphaComponent(0.95).cgColor)
                context.fillEllipse(in: dot)
                context.setStrokeColor(casing.cgColor)
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
    }

    let id: String
    let coordinate: CLLocationCoordinate2D
    let look: Look

    init(id: String, coordinate: CLLocationCoordinate2D, look: Look) {
        self.id = id
        self.coordinate = coordinate
        self.look = look
    }

    var label: String {
        CoreStrings.t("storm.storm_label.\(StormRules.bandNames[max(0, min(look.severity, 3))])")
    }
}

/// The disc: radius by severity, outlined red for hail, a ↻ or ✦ badge, and
/// for a live storm the stepping dashed ring under it.
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

    func update() {
        guard let storm = annotation as? StormAnnotation else { return }
        let look = storm.look
        let s = CGFloat(max(0, min(look.severity, 3)))
        let radius = (look.picked ? 8 : 6) + 2 * s
        let badge = look.meso ? "↻" : look.hail ? "✦" : nil
        let side = max(radius * 2 + 8, CGFloat(StormPulse.ringRadius * 2 + StormPulse.ringWidth) + 4)
        let height = side + (badge == nil ? 0 : 36)
        let size = CGSize(width: side, height: height)
        let colour = StormStyle.colour(look.severity)
        let o = CGFloat(look.opacity)
        image = UIGraphicsImageRenderer(size: size).image { _ in
            let centre = CGPoint(x: size.width / 2, y: size.height - side / 2)
            let disc = UIBezierPath(arcCenter: centre, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: true)
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
        accessibilityLabel = storm.label
        accessibilityIdentifier = "nativeMap.storm.\(storm.id)"
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
    private var added = false
    private var discs: [String: StormAnnotation] = [:]
    private var labels: [StormLeadAnnotation] = []
    private var drawn = StormDrawingResult()
    private var crowded = Set<String>()
    private var ringTimer: Timer?
    private var labelTimer: Timer?
    private var moving = false
    private var sheet: StormSheet?
    private var revision = -1

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
        let a = store.$revision.sink { [weak self] _ in DispatchQueue.main.async { self?.redraw() } }
        let b = store.$selection.sink { [weak self] selection in
            DispatchQueue.main.async {
                self?.map?.model.selectedStorm = selection?.id
                self?.redraw()
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
        if let camera = origin.camera {
            DispatchQueue.main.async { [weak map] in
                map?.view.layoutIfNeeded()
                map?.mapView.setCamera(camera, animated: false)
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
            if visible { map.mapView.addOverlay(overlay, level: .aboveLabels) } else { map.mapView.removeOverlay(overlay) }
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
            store.show(.now)
        } else if let time = step.time {
            store.show(.at(Double(time) * 1000))
        }
    }

    func regionDidChange() {
        moving = false
        store.reload()
        redraw()
    }

    func wake() { store.refresh() }

    func socketEvent(_ name: String, _ data: Data) {
        if name == "storms" { store.refresh() }
    }

    func renderer(for overlay: MKOverlay) -> MKOverlayRenderer? {
        overlay === self.overlay ? StormMapRenderer(overlay: overlay) : nil
    }

    func view(for annotation: MKAnnotation, in mapView: MKMapView) -> MKAnnotationView? {
        switch annotation {
        case is StormAnnotation: return mapView.dequeueReusableAnnotationView(withIdentifier: StormDiscView.reuse, for: annotation)
        case is StormLeadAnnotation: return mapView.dequeueReusableAnnotationView(withIdentifier: StormLeadView.reuse, for: annotation)
        default: return nil
        }
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
        if let id = link["storm"], !id.isEmpty {
            map?.setOn(.storms, true)
            store.open(id: id, details: details)
            return true
        }
        if let code = link["cell"], !code.isEmpty {
            map?.setOn(.storms, true)
            store.openCell(code: code, details: details)
            return true
        }
        // A box of sky opens on the 3D map only, where it is drawn.
        if let cloud = link["cloud"], map?.model.capability == .cells3d, let path = NativeMapLink.cloudPath(cloud) {
            store.openCloud(path: path, details: details)
            return true
        }
        return false
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

    /// Builds core's marks for the frame on screen and puts them on the map.
    private func redraw() {
        guard let map else { return }
        let mapView = map.mapView
        guard visible, store.frame != .hidden else {
            overlay.scene = .init()
            mapView.removeAnnotations(Array(discs.values) + labels)
            discs = [:]
            labels = []
            mapView.renderer(for: overlay)?.setNeedsDisplay()
            return
        }
        let now = Date().timeIntervalSince1970 * 1000
        let reference = store.at ?? now
        drawn = StormDrawing.drawStorms(store.held, now: reference, reference: reference, selection: store.selection, at: store.at)
        let picked = StormDrawing.selectedMark(store.selection)
        let resolution = self.resolution
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
        let dark = map.model.isDark
        let lines = (drawn.links + drawn.marks).filter { $0.kind != .position && shown($0) }
        overlay.scene = StormOverlay.Scene(marks: lines, picked: picked, dark: dark)
        mapView.renderer(for: overlay)?.setNeedsDisplay()

        // Discs: kept where nothing changed, so playback does not flicker them.
        let live = Set(drawn.pings.map(\.storm))
        var wanted: [String: StormAnnotation] = [:]
        for mark in drawn.marks where mark.kind == .position && shown(mark) {
            guard case .point(let at) = mark.geometry else { continue }
            let look = StormAnnotation.Look(severity: mark.severity, hail: mark.hail, meso: mark.meso, picked: mark.storm == picked,
                                            opacity: mark.storm == picked ? 1 : StormDrawing.ageOpacity(mark.ageMinutes),
                                            live: live.contains(mark.storm), dark: dark)
            let coordinate = CLLocationCoordinate2D(latitude: at.lat, longitude: at.lon)
            if let old = discs[mark.storm], old.look == look, old.coordinate.latitude == at.lat, old.coordinate.longitude == at.lon {
                wanted[mark.storm] = old
            } else {
                wanted[mark.storm] = StormAnnotation(id: mark.storm, coordinate: coordinate, look: look)
            }
        }
        let gone = discs.filter { wanted[$0.key] !== $0.value }.map(\.value)
        let new = wanted.filter { discs[$0.key] !== $0.value }.map(\.value)
        mapView.removeAnnotations(gone)
        mapView.addAnnotations(new)
        discs = wanted
        updateLabels(now: now, picked: picked, dark: dark)
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
            Task { @MainActor in self?.redraw() }
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
        for mark in overlay.scene.marks.reversed() {
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
