//
//  RadarWash.swift
//  meteocool
//
//  The light wash over where no radar reaches: core's `layers/dwd.ts`
//  "no-radar wash".
//

import MapKit
import UIKit

/// Where the radars reach, as core cuts them out of its wash
/// (`radarCoverageInv`, `dwdCoverageInv` in `layers/extents.ts`), from
/// `radar-wash.json` (`scripts/radar-wash.py`).
struct RadarReach: @unchecked Sendable {
    /// The world with every network's reach cut out.
    let radar: CGPath
    /// The world with DWD's reach cut out: on forecast steps only DWD's WN
    /// and the nowcast domains forecast.
    let dwd: CGPath

    static let bundled: RadarReach? = {
        guard let url = Bundle.main.url(forResource: "radar-wash", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return RadarReach(json: data)
    }()

    init?(json: Data) {
        struct Document: Decodable {
            let crs: String
            let radar: [[[Double]]]
            let dwd: [[[Double]]]
        }
        guard let document = try? JSONDecoder().decode(Document.self, from: json), document.crs == "EPSG:3857" else { return nil }
        radar = Self.world(minus: document.radar)
        dwd = Self.world(minus: document.dwd)
    }

    private static let halfWorld = 20037508.342789244

    private static func world(minus rings: [[[Double]]]) -> CGPath {
        let path = CGMutablePath()
        path.addRect(CGRect(x: 0, y: 0, width: MKMapSize.world.width, height: MKMapSize.world.height))
        let scale = MKMapSize.world.width / (2 * halfWorld)
        for ring in rings where ring.count > 2 {
            path.addLines(between: ring.map { CGPoint(x: ($0[0] + halfWorld) * scale, y: (halfWorld - $0[1]) * scale) })
            path.closeSubpath()
        }
        return path
    }
}

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
