//
//  SiteMarks.swift
//  meteocool
//
//  A mark on every radar that has published sweeps lately (core's
//  `layers/radarSiteMarks.ts`), and the rings of beam height round the open
//  one (`layers/beamRings.ts`).
//

import MapKit
import UIKit

/// A radar on the map, the way into site mode.
final class RadarSiteAnnotation: NSObject, MKAnnotation {
    let site: ListedSite
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var open = false

    init(_ site: ListedSite) {
        self.site = site
        coordinate = CLLocationCoordinate2D(latitude: site.lat, longitude: site.lon)
    }

    /// The radar's place name, or its code where the table does not know it.
    static func name(_ code: String) -> String {
        RadarSites.all[code]?.name ?? code.uppercased()
    }
}

/// A small disc with a radar's dish drawn in it, unlike anything else on
/// the map; the open radar's filled. Decluttered among the marks, the open
/// one never giving way.
final class RadarSiteMarkView: MKAnnotationView {
    static let reuse = "radarSite"
    private static let disc: CGFloat = 22
    private var dark = false

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: Self.disc + 6, height: Self.disc + 6)
        collisionMode = .circle
        canShowCallout = false
        // Over the storms and the tags (850): a radar is a fixed place.
        zPriority = MKAnnotationViewZPriority(rawValue: 900)
        isAccessibilityElement = true
        accessibilityTraits = .button
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var annotation: MKAnnotation? { didSet { update() } }

    func setDark(_ dark: Bool) {
        guard dark != self.dark else { return }
        self.dark = dark
        update()
    }

    func update() {
        guard let mark = annotation as? RadarSiteAnnotation else { return }
        displayPriority = mark.open ? .required : .defaultHigh
        image = Self.picture(open: mark.open, dark: dark)
        accessibilityLabel = CoreStrings.t("site.title", ["name": RadarSiteAnnotation.name(mark.site.site)])
        accessibilityIdentifier = "nativeMap.site.\(mark.site.site)"
        accessibilityTraits = mark.open ? [.button, .selected] : .button
    }

    /// A finger's width round the disc, as the HIG asks: 44 pt across.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        hypot(point.x - bounds.midX, point.y - bounds.midY) <= 22
    }

    private static func picture(open: Bool, dark: Bool) -> UIImage {
        let side = disc + 6
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            let cg = context.cgContext
            let fill: UIColor = open ? (dark ? UIColor(red: 0.357, green: 0.608, blue: 1, alpha: 1) : UIColor(red: 0.165, green: 0.435, blue: 0.859, alpha: 1))
                : (dark ? UIColor(red: 0.094, green: 0.11, blue: 0.141, alpha: 0.92) : UIColor(white: 1, alpha: 0.94))
            let edge = dark ? UIColor(white: 1, alpha: 0.35) : UIColor(red: 0.067, green: 0.078, blue: 0.102, alpha: 0.35)
            let ink: UIColor = open ? .white : (dark ? UIColor(red: 0.949, green: 0.957, blue: 0.969, alpha: 1)
                                                     : UIColor(red: 0.067, green: 0.078, blue: 0.102, alpha: 1))
            cg.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: UIColor.black.withAlphaComponent(0.3).cgColor)
            let circle = CGRect(x: 3, y: 3, width: disc, height: disc).insetBy(dx: 1, dy: 1)
            cg.setFillColor(fill.cgColor)
            cg.fillEllipse(in: circle)
            cg.setShadow(offset: .zero, blur: 0, color: nil)
            cg.setStrokeColor(edge.cgColor)
            cg.setLineWidth(1)
            cg.strokeEllipse(in: circle)
            // core's dish, its arm and its feed, on a 22-point grid.
            cg.translateBy(x: 3, y: 3)
            cg.setStrokeColor(ink.cgColor)
            cg.setLineCap(.round)
            let dish = UIBezierPath()
            dish.addArc(withCenter: CGPoint(x: 10.25, y: 10.25), radius: 6.01, startAngle: .pi * 0.75, endAngle: .pi * 1.75, clockwise: true)
            cg.setLineWidth(1.8)
            cg.addPath(dish.cgPath)
            cg.strokePath()
            cg.setLineWidth(1.6)
            cg.move(to: CGPoint(x: 8.5, y: 13.5))
            cg.addLine(to: CGPoint(x: 14, y: 8))
            cg.move(to: CGPoint(x: 7, y: 16.5))
            cg.addLine(to: CGPoint(x: 12, y: 16.5))
            cg.strokePath()
            cg.setFillColor(ink.cgColor)
            cg.fillEllipse(in: CGRect(x: 14.6 - 1.4, y: 7.4 - 1.4, width: 2.8, height: 2.8))
        }
    }
}

/// A ring of beam height round the open radar.
final class BeamRing: MKPolyline {
    var dark = false
}

/// A ring's label, at its northernmost point.
final class BeamRingLabel: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let text: String
    let dark: Bool

    init(coordinate: CLLocationCoordinate2D, text: String, dark: Bool) {
        self.coordinate = coordinate
        self.text = text
        self.dark = dark
    }
}

final class BeamRingLabelView: MKAnnotationView {
    static let reuse = "beamRingLabel"

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        displayPriority = .defaultLow
        collisionMode = .rectangle
        isUserInteractionEnabled = false
        // Read with the ring it names, not on its own.
        isAccessibilityElement = false
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var annotation: MKAnnotation? { didSet { update() } }

    private func update() {
        guard let label = annotation as? BeamRingLabel else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: label.dark ? UIColor(red: 0.949, green: 0.957, blue: 0.969, alpha: 1) : UIColor(red: 0.067, green: 0.078, blue: 0.102, alpha: 1),
            .strokeColor: label.dark ? UIColor(red: 0.067, green: 0.078, blue: 0.102, alpha: 0.85) : UIColor(white: 1, alpha: 0.85),
            .strokeWidth: -3.0,
        ]
        let text = label.text as NSString
        let size = text.size(withAttributes: attributes)
        image = UIGraphicsImageRenderer(size: CGSize(width: size.width + 4, height: size.height + 2)).image { _ in
            text.draw(at: CGPoint(x: 2, y: 1), withAttributes: attributes)
        }
    }
}

enum BeamRings {
    /// Points on each ring: smooth at any zoom a sweep is read at.
    static let segments = 128

    /// The rings and their labels for a sweep.
    static func make(_ geometry: SweepGeometry, dark: Bool) -> (rings: [BeamRing], labels: [BeamRingLabel]) {
        var rings: [BeamRing] = []
        var labels: [BeamRingLabel] = []
        for ring in SweepGeometryRules.beamHeightRings(geometry) {
            let points = (0 ... segments).map { i -> CLLocationCoordinate2D in
                let at = SweepGeometryRules.destination(lon: geometry.lon, lat: geometry.lat, groundM: ring.groundM,
                                                        bearingDeg: 360 * Double(i) / Double(segments))
                return CLLocationCoordinate2D(latitude: at.lat, longitude: at.lon)
            }
            let line = BeamRing(coordinates: points, count: points.count)
            line.dark = dark
            rings.append(line)
            let km = ring.heightM / 1000
            labels.append(BeamRingLabel(coordinate: points[0], text: "\(km == km.rounded() ? String(Int(km)) : String(km)) km", dark: dark))
        }
        return (rings, labels)
    }

    static func renderer(_ ring: BeamRing) -> MKPolylineRenderer {
        let renderer = MKPolylineRenderer(polyline: ring)
        renderer.strokeColor = ring.dark ? UIColor(white: 1, alpha: 0.45) : UIColor(red: 0.067, green: 0.078, blue: 0.102, alpha: 0.45)
        renderer.lineWidth = 1
        renderer.lineDashPattern = [4, 4]
        return renderer
    }
}
