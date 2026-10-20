//
//  InspectRing.swift
//  meteocool
//
//  The ring on the point the radar's readings are for, when that is not the
//  user's own position (core's `LayerManager.ts:280-313`).
//

import MapKit
import UIKit

/// The inspected point (core's `inspectLatLon`), as a mark.
final class InspectedPointAnnotation: MKPointAnnotation {}

/// A ring rather than a pin: the reading belongs to the point at its
/// centre, and it stays legible over the radar's colours. White on a dark
/// halo, so it holds up over a light map; unlike the solid blue dot of the
/// user's position, which can be on screen beside it.
final class InspectRingView: MKAnnotationView {
    static let reuse = "inspectRing"

    private static let image: UIImage = {
        let size = CGSize(width: 32, height: 32)
        return UIGraphicsImageRenderer(size: size).image { renderer in
            let context = renderer.cgContext
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            func circle(_ radius: CGFloat) -> CGRect {
                CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
            }
            // The halo, the ring, the centre: r 11 at 5 pt, r 11 at 2.5 pt, r 2.5.
            context.setStrokeColor(UIColor(white: 0, alpha: 0.35).cgColor)
            context.setLineWidth(5)
            context.strokeEllipse(in: circle(11))
            context.setStrokeColor(UIColor.white.cgColor)
            context.setLineWidth(2.5)
            context.strokeEllipse(in: circle(11))
            context.setFillColor(UIColor.white.cgColor)
            context.fillEllipse(in: circle(2.5))
            context.setStrokeColor(UIColor(white: 0, alpha: 0.35).cgColor)
            context.setLineWidth(1)
            context.strokeEllipse(in: circle(2.5))
        }
    }()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        image = Self.image
        displayPriority = .required
        // Over the radar and the storms, under the user's own position.
        zPriority = MKAnnotationViewZPriority(rawValue: 900)
        canShowCallout = false
        collisionMode = .circle
        // Taps go through it to the map.
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = PointText.local("inspected_point")
        accessibilityIdentifier = "nativeMap.point.ring"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
