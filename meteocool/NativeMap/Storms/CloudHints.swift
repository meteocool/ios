//
//  CloudHints.swift
//  meteocool
//
//  A "3D" tag beside every storm core the 3D map can cut open (core's
//  `layers/cloudHints.ts`), and the way there: a tap opens the core on the
//  3D map with its panel. Only on the flat radar map's newest observation,
//  the scan the cores were found in. One per storm, thinned at a wide zoom.
//
//  Unlike core's, a tag a scan behind its radar keeps its colour: it only
//  gives way to a current one where two are too close.
//

import Combine
import MapKit
import UIKit

final class CloudHintAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let tag: CloudHintRules.Tag

    init(_ tag: CloudHintRules.Tag) {
        self.tag = tag
        coordinate = CLLocationCoordinate2D(latitude: tag.cloud.lat, longitude: tag.cloud.lon)
    }
}

/// The pill: a cube in the core's peak colour and "3D", beside the core.
final class CloudHintView: MKAnnotationView {
    static let reuse = "cloudHint"
    static let size = CGSize(width: 34, height: 18)
    var palette = "classic"
    var dark = false

    private static var cache: [String: UIImage] = [:]

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(origin: .zero, size: Self.size)
        // Bottom-left 8 pt right of and above the core (`anchor`, `DISPLACEMENT`).
        centerOffset = CGPoint(x: 8 + Self.size.width / 2, y: -8 - Self.size.height / 2)
        // Shown whatever else is near: they give way to each other only
        // (`CloudHintRules.thin`), and draw over the storms' discs.
        displayPriority = .required
        zPriority = MKAnnotationViewZPriority(rawValue: 900)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = "nativeMap.cloudHint"
        accessibilityLabel = CoreStrings.t("storm.open_3d")
    }

    required init?(coder: NSCoder) { fatalError() }

    func update() {
        guard let hint = annotation as? CloudHintAnnotation else { return }
        let dbz = ((hint.tag.cloud.peakDbz ?? 40) / CloudHintRules.dbzStep).rounded() * CloudHintRules.dbzStep
        image = Self.pill(dbz: dbz, palette: palette, dark: dark)
        accessibilityValue = "\(Int(dbz)) dBZ"
    }

    private static func pill(dbz: Double, palette: String, dark: Bool) -> UIImage {
        let key = "\(palette)|\(dbz)|\(dark)"
        if let image = cache[key] { return image }
        let fill = dark ? UIColor(red: 24 / 255, green: 28 / 255, blue: 36 / 255, alpha: 0.92) : UIColor(white: 1, alpha: 0.94)
        let edge = dark ? UIColor(white: 1, alpha: 0.22) : UIColor(red: 17 / 255, green: 20 / 255, blue: 26 / 255, alpha: 0.18)
        let text = dark ? UIColor(red: 0xf2 / 255, green: 0xf4 / 255, blue: 0xf7 / 255, alpha: 1)
            : UIColor(red: 0x11 / 255, green: 0x14 / 255, blue: 0x1a / 255, alpha: 1)
        let rgb = Colormaps.colour(dbz: dbz, palette: palette)
        let core = UIColor(red: CGFloat(rgb.x) / 255, green: CGFloat(rgb.y) / 255, blue: CGFloat(rgb.z) / 255, alpha: 1)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            let body = UIBezierPath(roundedRect: CGRect(x: 0.5, y: 0.5, width: 33, height: 17), cornerRadius: 8.5)
            fill.setFill()
            body.fill()
            edge.setStroke()
            body.lineWidth = 1
            body.stroke()
            let cube = UIBezierPath()
            for (i, p) in [(10, 4), (14.5, 6.5), (14.5, 11.5), (10, 14), (5.5, 11.5), (5.5, 6.5)].enumerated() {
                let point = CGPoint(x: p.0, y: p.1)
                if i == 0 { cube.move(to: point) } else { cube.addLine(to: point) }
            }
            cube.close()
            core.setFill()
            cube.fill()
            let edges = UIBezierPath()
            edges.move(to: CGPoint(x: 5.5, y: 6.5))
            edges.addLine(to: CGPoint(x: 10, y: 9))
            edges.addLine(to: CGPoint(x: 14.5, y: 6.5))
            edges.move(to: CGPoint(x: 10, y: 9))
            edges.addLine(to: CGPoint(x: 10, y: 14))
            edges.lineWidth = 1
            edges.lineJoinStyle = .round
            fill.setStroke()
            edges.stroke()
            let label = NSAttributedString(string: "3D", attributes: [
                .font: UIFont.systemFont(ofSize: 9.5, weight: .bold), .foregroundColor: text,
            ])
            let box = label.size()
            label.draw(at: CGPoint(x: 23.5 - box.width / 2, y: 9 - box.height / 2))
        }
        cache[key] = image
        return image
    }
}

@MainActor
final class CloudHints: NativeMapFeature {
    private weak var map: NativeMapContext?
    private var clouds: [RadarVolume] = []
    private var drawn: [CloudHintAnnotation] = []
    private var drawnKey = ""
    private var live = true
    private var loading = false
    private var keyChanged: AnyCancellable?

    func attach(to map: NativeMapContext) {
        self.map = map
        map.mapView.register(CloudHintView.self, forAnnotationViewWithReuseIdentifier: CloudHintView.reuse)
        // The storm key's "3D tags" row.
        keyChanged = map.model.$hiddenStormMarks.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.redraw() } }
    }

    func wake() { load() }

    /// The cores are rebuilt with each run, and with each network's.
    func socketEvent(_ name: String, _ data: Data) {
        if name == "cells" || name == "volumes" { load() }
    }

    /// A tag a scan behind waits for its scan's cores (`VolumeFeed.follow`).
    func tick() {
        guard let map else { return }
        if clouds.contains(where: { CloudHintRules.isBehind($0, liveScans: map.player.timeline.liveScans) }) { load() }
    }

    func stepDidChange(_ step: RadarStep) {
        live = step.isLive || step.time == nil
        redraw()
    }

    func regionDidChange() { redraw() }
    func settingsDidChange() { redraw() }
    func capabilityDidChange(_ capability: NativeMapModel.Capability) { redraw() }

    func view(for annotation: MKAnnotation, in mapView: MKMapView) -> MKAnnotationView? {
        guard annotation is CloudHintAnnotation, let map,
              let view = mapView.dequeueReusableAnnotationView(withIdentifier: CloudHintView.reuse, for: annotation) as? CloudHintView
        else { return nil }
        view.palette = Self.palette
        view.dark = map.model.isDark
        view.update()
        return view
    }

    /// Opens the core on the 3D map, its panel up (`openCloudIn3D`): the open
    /// storm's own when it holds the core's patch.
    func didSelect(_ annotation: MKAnnotation) -> Bool {
        guard let hint = annotation as? CloudHintAnnotation, let map else { return false }
        map.mapView.deselectAnnotation(annotation, animated: false)
        let cloud = hint.tag.cloud
        map.model.volumeRequest = cloud
        map.model.focus3D = ThreeDFocus(latitude: cloud.lat, longitude: cloud.lon, areaKm2: cloud.areaKm2, topM: nil)
        let from = (map.model.capability, map.mapView.camera.copy() as? MKMapCamera)
        map.setCapability(.cells3d)
        map.model.detour = from
        return true
    }

    private static var palette: String {
        UserDefaults(suiteName: "group.org.frcy.app.meteocool")?.string(forKey: "radarColorMapping") ?? "classic"
    }

    private func load() {
        guard let map, !loading else { return }
        loading = true
        map.fetch(map.endpoints.data.appendingPathComponent("cells/volumes")) { [weak self] data, _ in
            guard let self else { return }
            self.loading = false
            guard let data, let volumes = StormJSON.volumes(data) else { return }
            self.clouds = volumes
            // And for a storm opened on this map, the box its patch is in.
            self.map?.model.volumes = volumes
            self.redraw()
        }
    }

    private func redraw() {
        guard let map else { return }
        let zoom = map.zoomLevel
        let shown = map.model.capability == .radar && live && zoom > CloudHintRules.minZoom && !clouds.isEmpty
            && !map.model.hiddenStormMarks.contains(.volume)
        let scans = map.player.timeline.liveScans
        let tags = shown ? CloudHintRules.onePerStorm(clouds).map {
            CloudHintRules.Tag(cloud: $0, stale: CloudHintRules.isBehind($0, liveScans: scans))
        } : []
        let kept = CloudHintRules.thin(tags, zoom: zoom)
        let key = kept.map { "\($0.cloud.path):\($0.stale):\($0.cloud.peakDbz ?? 0)" }.joined(separator: ",")
            + "|\(map.model.isDark)|\(Self.palette)"
        guard key != drawnKey else { return }
        drawnKey = key
        map.mapView.removeAnnotations(drawn)
        drawn = kept.map(CloudHintAnnotation.init)
        map.mapView.addAnnotations(drawn)
    }
}
