//
//  RadarWash.swift
//  meteocool
//
//  The light wash over where no radar reaches: core's `layers/dwd.ts`
//  "no-radar wash".
//

import MapKit
import UIKit

final class RadarWashOverlay: NSObject, MKOverlay, @unchecked Sendable {
    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let boundingMapRect = MKMapRect.world
    private let lock = NSLock()
    private var current: (path: CGPath, holes: [CGPath], alpha: CGFloat)?

    /// What to fill: a reach's inverse, less more ground (the nowcast
    /// domains on a forecast step), at an opacity.
    var fill: (path: CGPath, holes: [CGPath], alpha: CGFloat)? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

final class RadarWashRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let fill = (overlay as? RadarWashOverlay)?.fill else { return }
        let area = CGRect(x: mapRect.minX, y: mapRect.minY, width: mapRect.width, height: mapRect.height)
        context.beginTransparencyLayer(in: area, auxiliaryInfo: nil)
        context.addPath(fill.path)
        context.setFillColor(UIColor(white: 0, alpha: fill.alpha).cgColor)
        context.fillPath(using: .evenOdd)
        context.setBlendMode(.clear)
        for hole in fill.holes where hole.boundingBoxOfPath.intersects(area) {
            context.addPath(hole)
            context.fillPath(using: .evenOdd)
        }
        context.endTransparencyLayer()
    }
}

/// Washes out where there is no radar, so an empty map there does not read
/// as dry weather: 10 % black on a light map, 40 % on a dark one; on a
/// forecast step only DWD's reach and the nowcast domains count.
@MainActor
final class RadarWash: NativeMapFeature {
    private weak var map: NativeMapContext?
    private let overlay = RadarWashOverlay()
    private var forecast = false
    private var added = false

    func attach(to map: NativeMapContext) {
        self.map = map
        update()
    }

    func renderer(for overlay: MKOverlay) -> MKOverlayRenderer? {
        overlay === self.overlay ? RadarWashRenderer(overlay: overlay) : nil
    }

    func stepDidChange(_ step: RadarStep) {
        forecast = step.isForecast
        update()
    }

    func settingsDidChange() { update() }

    private func update() {
        guard let map, let reach = RadarReach.bundled else { return }
        let show = map.model.capability == .radar
        let alpha: CGFloat = map.model.isDark ? 0.4 : 0.1
        if forecast {
            // The nowcast domains drawn on this step forecast too.
            let holes = map.radar.shownLayers.compactMap { layer -> CGPath? in
                if case .exclusive(let code) = layer.clip { return map.radar.coverage.domains[code]?.exclusive }
                return nil
            }
            overlay.fill = (reach.dwd, holes, alpha)
        } else {
            overlay.fill = (reach.radar, [], alpha)
        }
        if show != added {
            added = show
            if show { map.mapView.addOverlay(overlay, level: .aboveLabels) } else { map.mapView.removeOverlay(overlay) }
        }
        map.mapView.renderer(for: overlay)?.setNeedsDisplay()
    }
}
