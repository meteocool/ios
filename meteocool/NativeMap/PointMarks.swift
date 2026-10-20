//
//  PointMarks.swift
//  meteocool
//
//  Lightning strikes and mesocyclones on the native map: core's
//  `layers/lightning.ts` and `layers/mesocyclones.ts`.
//

import Foundation
import MapKit
import UIKit

/// EPSG:3857 metres, which the data service sends as `lat`/`lon`, to degrees.
enum WebMercator {
    static let radius = 6378137.0

    static func coordinate(x: Double, y: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: (2 * atan(exp(y / radius)) - .pi / 2) * 180 / .pi,
                               longitude: x / radius * 180 / .pi)
    }
}

// MARK: - Lightning

/// The strikes to draw, shared with MapKit's drawing threads.
final class LightningOverlay: NSObject, MKOverlay, @unchecked Sendable {
    struct Strike {
        let point: MKMapPoint
        let time: Date
    }

    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let boundingMapRect = MKMapRect.world
    private let lock = NSLock()
    private var current: [Strike] = []

    var strikes: [Strike] {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

/// Strikes drawn like core's lightning layer (`layers/lightning.ts`):
/// clustered on screen, the bolt larger the more strikes it stands for,
/// fading with their mean age. Drawn as an overlay, under the storms, as
/// core draws it, rather than as annotations, which MapKit would hide
/// wherever they meet a storm.
final class LightningRenderer: MKOverlayRenderer {
    /// Strikes this close on screen, in points, are one bolt.
    private static let cell: Double = 20
    private static let icon: CGImage? = UIImage(named: "MapLightning")?.cgImage

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let lightning = overlay as? LightningOverlay, let icon = Self.icon else { return }
        let cell = Self.cell / Double(zoomScale)
        // Whole cells around the tile, so a cluster on a tile's edge is the
        // same cluster in both tiles; and room for the largest bolt.
        let margin = 40 / Double(zoomScale)
        let x0 = floor((mapRect.minX - margin) / cell), x1 = ceil((mapRect.maxX + margin) / cell)
        let y0 = floor((mapRect.minY - margin) / cell), y1 = ceil((mapRect.maxY + margin) / cell)
        let area = MKMapRect(x: x0 * cell, y: y0 * cell, width: (x1 - x0) * cell, height: (y1 - y0) * cell)

        struct Cluster { var x = 0.0, y = 0.0, age = 0.0, count = 0 }
        var clusters: [Int64: Cluster] = [:]
        let now = Date()
        for strike in lightning.strikes where area.contains(strike.point) {
            let key = Int64(strike.point.x / cell) << 32 | Int64(strike.point.y / cell)
            var cluster = clusters[key] ?? Cluster()
            cluster.x += strike.point.x
            cluster.y += strike.point.y
            cluster.age += now.timeIntervalSince(strike.time)
            cluster.count += 1
            clusters[key] = cluster
        }

        let aspect = Double(icon.height) / Double(icon.width)
        for cluster in clusters.values {
            let n = cluster.count
            let size: Double = n > 13 ? 40 : n > 9 ? 34 : n > 3 ? 29 : 24
            let height = size * 0.2 / 40 * 206 / Double(zoomScale)
            let width = height / aspect
            let meanAge = cluster.age / Double(n) / 60
            var level = min(Int((meanAge / 2.5).rounded()) + 1, 20)
            if level < 5 { level = 0 }
            let alpha = max(0, min(1, 1 - Double(level) / 30 * 0.8 - 0.2))
            let center = CGPoint(x: cluster.x / Double(n), y: cluster.y / Double(n))
            context.saveGState()
            context.setAlpha(alpha)
            // Map points grow downwards, an image's rows upwards.
            context.translateBy(x: center.x - width / 2, y: center.y + height / 2)
            context.scaleBy(x: 1, y: -1)
            context.draw(icon, in: CGRect(x: 0, y: 0, width: width, height: height))
            context.restoreGState()
        }
    }
}

/// The strikes of the last half hour: backfilled from `/lightning_cache`,
/// then one by one from the socket (core's `StrikeManager`).
@MainActor
final class LightningMarks {
    static let maxAge: TimeInterval = 30 * 60
    static let maxCount = 1000

    let overlay = LightningOverlay()
    private weak var mapView: MKMapView?
    /// By time in milliseconds, which tells strikes apart.
    private var strikes: [Int: LightningOverlay.Strike] = [:]
    private var batchTimer: Timer?
    var visible = true {
        didSet {
            guard visible != oldValue, let mapView else { return }
            if visible { mapView.addOverlay(overlay, level: .aboveLabels) } else { mapView.removeOverlay(overlay) }
        }
    }

    init(mapView: MKMapView) {
        self.mapView = mapView
        mapView.addOverlay(overlay, level: .aboveLabels)
    }

    struct Wire: Decodable {
        let lat: Double
        let lon: Double
        let time: Double
    }

    /// Replaces everything with the cache's strikes.
    func load(_ data: Data) {
        guard let wires = try? JSONDecoder().decode([Wire].self, from: data) else { return }
        strikes = [:]
        for wire in wires { insert(wire) }
        publish()
    }

    /// One strike from the socket; drawn in half-second batches as core does.
    func add(_ data: Data) {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return }
        insert(wire)
        guard batchTimer == nil else { return }
        batchTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.batchTimer = nil
                self?.publish()
            }
        }
    }

    private func insert(_ wire: Wire) {
        guard wire.time.isFinite else { return }
        let id = Int(wire.time.rounded())
        guard strikes[id] == nil else { return }
        strikes[id] = LightningOverlay.Strike(point: MKMapPoint(WebMercator.coordinate(x: wire.lon, y: wire.lat)),
                                              time: Date(timeIntervalSince1970: Double(id) / 1000))
    }

    /// Drops what is older than half an hour, and the oldest past a
    /// thousand, and redraws.
    private func publish(now: Date = Date()) {
        strikes = strikes.filter { now.timeIntervalSince($0.value.time) <= Self.maxAge }
        if strikes.count > Self.maxCount {
            for id in strikes.keys.sorted().prefix(strikes.count - Self.maxCount) { strikes[id] = nil }
        }
        overlay.strikes = Array(strikes.values)
        (mapView?.renderer(for: overlay))?.setNeedsDisplay()
    }

    /// Fades the strikes as they age.
    func tick() {
        publish()
    }
}

// MARK: - Mesocyclones

final class MesocycloneAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let time: Date
    let intensity: Int
    let title: String?

    init(coordinate: CLLocationCoordinate2D, time: Date, intensity: Int) {
        self.coordinate = coordinate
        self.time = time
        self.intensity = intensity
        title = String(format: NSLocalizedString("native_map_mesocyclone", comment: ""), intensity)
    }
}

final class MesocycloneView: MKAnnotationView {
    static let reuse = "mesocyclone"
    private static let icon = UIImage(named: "MapMesocyclone")

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        displayPriority = .required
        canShowCallout = true
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var annotation: MKAnnotation? { didSet { update() } }

    /// Size by intensity from core's `mesocycloneStyle`.
    private func update() {
        guard let meso = annotation as? MesocycloneAnnotation, let icon = Self.icon else { return }
        let i = meso.intensity
        let size: CGFloat = i > 4 ? 55 : i > 3 ? 46 : i > 2 ? 38 : i > 1 ? 30 : 22
        let scaled = CGSize(width: size * 0.2 / 40 * icon.size.width, height: size * 0.2 / 40 * icon.size.height)
        image = UIGraphicsImageRenderer(size: scaled).image { _ in icon.draw(in: CGRect(origin: .zero, size: scaled)) }
    }
}

/// The mesocyclones of the last half hour: the socket always sends the
/// whole list (core's `MesoCycloneManager`).
@MainActor
final class MesocycloneMarks {
    private weak var mapView: MKMapView?
    private var shown: [MesocycloneAnnotation] = []
    private var all: [MesocycloneAnnotation] = []
    var visible = true {
        didSet { if visible != oldValue { show() } }
    }

    init(mapView: MKMapView) {
        self.mapView = mapView
    }

    struct Wire: Decodable {
        let lat: Double
        let lon: Double
        let time: Double?
        let intensity: Int?
    }

    func load(_ data: Data) {
        guard let wires = try? JSONDecoder().decode([Wire].self, from: data) else { return }
        let now = Date()
        all = wires.prefix(100).compactMap { wire in
            let time = Date(timeIntervalSince1970: (wire.time ?? now.timeIntervalSince1970 * 1000) / 1000)
            guard now.timeIntervalSince(time) < LightningMarks.maxAge else { return nil }
            return MesocycloneAnnotation(coordinate: WebMercator.coordinate(x: wire.lon, y: wire.lat),
                                         time: time, intensity: wire.intensity ?? 1)
        }
        show()
    }

    func tick() {
        let now = Date()
        let before = all.count
        all.removeAll { now.timeIntervalSince($0.time) >= LightningMarks.maxAge }
        if all.count != before { show() }
    }

    private func show() {
        mapView?.removeAnnotations(shown)
        shown = visible ? all : []
        mapView?.addAnnotations(shown)
    }
}
