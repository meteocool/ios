//
//  StormMarks.swift
//  meteocool
//
//  Tracked storms on the native map: core's `StormManager` and
//  `lib/stormMarks.ts`, the live picture without the selected storm's
//  forecast.
//

import Foundation
import MapKit
import UIKit

/// `/storms` (core's `spec/data.openapi.json`, `StormCollection`), EPSG:4326.
struct StormCollection: Decodable {
    let features: [Feature]?

    struct Feature: Decodable {
        let id: String
        let geometry: Geometry
        let properties: Properties
    }

    struct Properties: Decodable {
        let id: String
        let bornAt: String
        let lastSeen: String
        let status: String
        let severity: Int?
        let hail: Bool?
        let meso: Bool?
        let path: Geometry
        let peakDbz: Double?
        let headingDeg: Double?
        let speedKmh: Double?
        let placement: Placement?
    }

    struct Placement: Decodable {
        let place: String
        let distanceKm: Double
        let direction: String?
    }

    /// A Point or a LineString, as `[lon, lat]` pairs.
    struct Geometry: Decodable {
        let coordinates: [CLLocationCoordinate2D]

        enum CodingKeys: String, CodingKey { case type, coordinates }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let line = try? c.decode([[Double]].self, forKey: .coordinates) {
                coordinates = line.compactMap { $0.count >= 2 ? CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) : nil }
            } else {
                let point = try c.decode([Double].self, forKey: .coordinates)
                coordinates = point.count >= 2 ? [CLLocationCoordinate2D(latitude: point[1], longitude: point[0])] : []
            }
        }
    }

    static func decode(_ data: Data) -> StormCollection? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(StormCollection.self, from: data)
    }
}

/// Severity colours and age fade from core's `stormMarks.ts`.
enum StormStyle {
    static let colours: [UIColor] = [
        UIColor(red: 0x2f / 255, green: 0x9e / 255, blue: 0x44 / 255, alpha: 1),
        UIColor(red: 0xf0 / 255, green: 0xb4 / 255, blue: 0x29 / 255, alpha: 1),
        UIColor(red: 0xe0 / 255, green: 0x31 / 255, blue: 0x31 / 255, alpha: 1),
        UIColor(red: 0x9c / 255, green: 0x36 / 255, blue: 0xb5 / 255, alpha: 1),
    ]
    static let hail = colours[2]

    static func colour(_ severity: Int) -> UIColor { colours[max(0, min(severity, 3))] }

    static func fade(age: TimeInterval) -> CGFloat {
        switch age / 60 {
        case ..<20: return 1
        case ..<40: return 0.6
        case ..<60: return 0.35
        default: return 0.15
        }
    }

    // ISO8601DateFormatter is thread-safe.
    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoPlain = ISO8601DateFormatter()

    static func date(_ text: String) -> Date? { iso.date(from: text) ?? isoPlain.date(from: text) }
}

final class StormAnnotation: NSObject, MKAnnotation {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let severity: Int
    let hail: Bool
    let meso: Bool
    let lastSeen: Date
    let title: String?
    let subtitle: String?

    init(_ feature: StormCollection.Feature, at coordinate: CLLocationCoordinate2D, lastSeen: Date) {
        let p = feature.properties
        id = p.id
        self.coordinate = coordinate
        severity = p.severity ?? 0
        hail = p.hail ?? false
        meso = p.meso ?? false
        self.lastSeen = lastSeen
        if let placement = p.placement {
            title = String(format: NSLocalizedString("native_map_storm_near", comment: ""), placement.place)
        } else {
            title = NSLocalizedString("native_map_storm", comment: "")
        }
        var details: [String] = []
        if let speed = p.speedKmh, let heading = p.headingDeg {
            let arrows = ["↑", "↗", "→", "↘", "↓", "↙", "←", "↖"]
            details.append("\(arrows[Int(((heading.truncatingRemainder(dividingBy: 360) + 360 + 22.5) / 45)) % 8]) \(Int(speed.rounded())) km/h")
        }
        if let dbz = p.peakDbz { details.append("\(Int(dbz.rounded())) dBZ") }
        if hail { details.append(NSLocalizedString("native_map_hail", comment: "")) }
        subtitle = details.isEmpty ? nil : details.joined(separator: " · ")
    }
}

/// A storm's centroid: a disc by severity, outlined red for hail, with a
/// badge for rotation (↻) or hail (✦).
final class StormView: MKAnnotationView {
    static let reuse = "storm"

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        displayPriority = .required
        canShowCallout = true
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var annotation: MKAnnotation? { didSet { update() } }

    private func update() {
        guard let storm = annotation as? StormAnnotation else { return }
        let radius = 6 + 2 * CGFloat(min(max(storm.severity, 0), 3))
        let badge = storm.meso ? "↻" : storm.hail ? "✦" : nil
        let side = (radius + 3) * 2
        let size = CGSize(width: max(side, 24), height: side + (badge == nil ? 0 : 32))
        image = UIGraphicsImageRenderer(size: size).image { context in
            let center = CGPoint(x: size.width / 2, y: size.height - side / 2)
            let disc = UIBezierPath(arcCenter: center, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: true)
            StormStyle.colour(storm.severity).withAlphaComponent(0.75).setFill()
            disc.fill()
            (storm.hail ? StormStyle.hail : UIColor.white).setStroke()
            disc.lineWidth = storm.hail ? 3 : 2
            disc.stroke()
            if let badge {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 15, weight: .bold),
                    .foregroundColor: StormStyle.colour(storm.severity),
                    .strokeColor: UIColor.white,
                    .strokeWidth: -3.0,
                ]
                let text = badge as NSString
                let textSize = text.size(withAttributes: attributes)
                text.draw(at: CGPoint(x: center.x - textSize.width / 2, y: center.y - radius - 16 - textSize.height / 2),
                          withAttributes: attributes)
            }
        }
        // The disc's centre on the storm.
        centerOffset = CGPoint(x: 0, y: -(size.height - side) / 2)
        alpha = StormStyle.fade(age: Date().timeIntervalSince(storm.lastSeen))
        accessibilityLabel = [storm.title, storm.subtitle].compactMap { $0 }.joined(separator: ", ")
    }
}

/// A storm's path, oldest centroid first.
final class StormPath: MKPolyline {
    var severity = 0
    var fade: CGFloat = 1
}

/// The storms around the map, seen in the last three hours, refetched when
/// the map leaves what was fetched (core's `StormManager`).
@MainActor
final class StormMarks: NativeMapFeature {
    private weak var map: NativeMapContext?
    private var mapView: MKMapView? { map?.mapView }
    private var annotations: [StormAnnotation] = []
    private var paths: [StormPath] = []
    private var fetched: MKMapRect = .null
    private var task: URLSessionDataTask?
    private var lastFetch = Date.distantPast
    private var endpoints: NativeMapEndpoints?
    /// The storms on screen are the live picture: hidden on a forecast step.
    private var visible = false {
        didSet { if visible != oldValue { redraw() } }
    }
    private var live = true
    /// Storms not seen for ten minutes show only from zoom 10 up.
    private var zoom: Double = 6 {
        didSet { if (zoom >= 10) != (oldValue >= 10) { redraw() } }
    }
    private var collection: StormCollection?

    func attach(to map: NativeMapContext) {
        self.map = map
        endpoints = map.endpoints
        map.mapView.register(StormView.self, forAnnotationViewWithReuseIdentifier: StormView.reuse)
        settingsDidChange()
    }

    func settingsDidChange() {
        if let map, map.endpoints != endpoints {
            endpoints = map.endpoints
            refresh(force: true)
        }
        visible = (map?.isOn(.storms) ?? false) && live && map?.model.capability == .radar
    }

    func stepDidChange(_ step: RadarStep) {
        live = step.time == nil || step.isLive
        settingsDidChange()
    }

    func regionDidChange() {
        zoom = map?.zoomLevel ?? zoom
        refresh()
    }

    func wake() { refresh(force: true) }
    func tick() { refresh() }

    func socketEvent(_ name: String, _ data: Data) {
        if name == "storms" { refresh(force: true) }
    }

    func view(for annotation: MKAnnotation, in mapView: MKMapView) -> MKAnnotationView? {
        annotation is StormAnnotation ? mapView.dequeueReusableAnnotationView(withIdentifier: StormView.reuse, for: annotation) : nil
    }

    func renderer(for overlay: MKOverlay) -> MKOverlayRenderer? {
        guard let path = overlay as? StormPath else { return nil }
        return Self.renderer(for: path, dark: map?.model.isDark ?? false)
    }

    /// Fetches again when the map left the fetched box, or when told to.
    func refresh(force: Bool = false) {
        guard let mapView, mapView.bounds.width > 0, let endpoints else { return }
        let visibleRect = mapView.visibleMapRect
        if !force, fetched.contains(visibleRect), Date().timeIntervalSince(lastFetch) < 120 { return }
        let padded = visibleRect.insetBy(dx: -visibleRect.width / 4, dy: -visibleRect.height / 4)
        let region = MKCoordinateRegion(padded)
        let url = endpoints.storms(minLon: region.center.longitude - region.span.longitudeDelta / 2,
                                   minLat: region.center.latitude - region.span.latitudeDelta / 2,
                                   maxLon: region.center.longitude + region.span.longitudeDelta / 2,
                                   maxLat: region.center.latitude + region.span.latitudeDelta / 2,
                                   since: Date().addingTimeInterval(-180 * 60))
        task?.cancel()
        lastFetch = Date()
        task = URLSession.shared.dataTask(with: url) { [weak self] data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode
            Task { @MainActor in
                guard let self else { return }
                if status == 404 {
                    self.fetched = padded
                    self.collection = nil
                    self.redraw()
                } else if status == 200, let data, let collection = StormCollection.decode(data) {
                    self.fetched = padded
                    self.collection = collection
                    self.redraw()
                }
            }
        }
        task?.resume()
    }

    func redraw() {
        guard let mapView else { return }
        mapView.removeAnnotations(annotations)
        mapView.removeOverlays(paths)
        annotations = []
        paths = []
        guard visible, let features = collection?.features else { return }
        let now = Date()
        for feature in features {
            let p = feature.properties
            guard p.status != "merged", let seen = StormStyle.date(p.lastSeen),
                  let centroid = feature.geometry.coordinates.last else { continue }
            if now.timeIntervalSince(seen) > 600, zoom < 10 { continue }
            annotations.append(StormAnnotation(feature, at: centroid, lastSeen: seen))
            var coordinates = p.path.coordinates
            if coordinates.count > 1 {
                let path = StormPath(coordinates: &coordinates, count: coordinates.count)
                path.severity = p.severity ?? 0
                path.fade = StormStyle.fade(age: now.timeIntervalSince(seen))
                paths.append(path)
            }
        }
        mapView.addOverlays(paths, level: .aboveLabels)
        mapView.addAnnotations(annotations)
    }

    /// The path's renderer: a casing four points wider under the line.
    static func renderer(for path: StormPath, dark: Bool) -> MKOverlayRenderer {
        let renderer = StormPathRenderer(polyline: path)
        renderer.dark = dark
        renderer.alpha = path.fade
        return renderer
    }
}

/// Inherits MKPolylineRenderer's initialisers: MapKit calls `init(overlay:)`.
private final class StormPathRenderer: MKPolylineRenderer {
    var dark = false

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        if path == nil { createPath() }
        guard let path else { return }
        let severity = min(max((overlay as? StormPath)?.severity ?? 0, 0), 3)
        let width = (2 + CGFloat(severity)) / zoomScale
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(path)
        context.setStrokeColor(dark ? UIColor(red: 12 / 255, green: 16 / 255, blue: 22 / 255, alpha: 0.75).cgColor
                                    : UIColor(white: 1, alpha: 0.75).cgColor)
        context.setLineWidth(width + 4 / zoomScale)
        context.strokePath()
        context.addPath(path)
        context.setStrokeColor(StormStyle.colour(severity).cgColor)
        context.setLineWidth(width)
        context.strokePath()
    }
}
