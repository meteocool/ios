//
//  RadarOverlay.swift
//  meteocool
//
//  The radar composite as one MapKit overlay.
//

import Foundation
import MapKit

/// What the radar overlay draws, shared between the main thread, which
/// moves it from step to step, and MapKit's drawing threads.
final class RadarScene: @unchecked Sendable {
    let compositor: RadarCompositor
    private let lock = NSLock()
    private var current = RadarFrameRef.none
    private var before: RadarFrameRef?
    private var drawnZoom: Int?

    init(compositor: RadarCompositor) {
        self.compositor = compositor
    }

    /// The step on screen, and the one before it: drawn where a picture of
    /// the step on screen is still missing, so nothing blinks.
    var frames: (current: RadarFrameRef, previous: RadarFrameRef?) {
        lock.withLock { (current, before) }
    }

    /// Shows a step; true when that changes anything.
    @discardableResult
    func show(_ frame: RadarFrameRef) -> Bool {
        lock.withLock {
            guard frame != current else { return false }
            before = current
            current = frame
            return true
        }
    }

    /// The tile zoom MapKit last drew at, which preparing follows.
    var zoom: Int? {
        get { lock.withLock { drawnZoom } }
        set { lock.withLock { drawnZoom = newValue } }
    }
}

final class RadarOverlay: NSObject, MKOverlay {
    let scene: RadarScene
    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let boundingMapRect = MKMapRect.world

    init(scene: RadarScene) {
        self.scene = scene
    }
}

/// Copies the step's pictures (`RadarCompositor`) onto the map, unsmoothed.
/// It never puts one together itself: drawing stays this cheap so MapKit
/// redraws every tile of a new step together, instead of one after another.
final class RadarRenderer: MKOverlayRenderer {
    private let scene: RadarScene

    init(radar: RadarOverlay) {
        scene = radar.scene
        super.init(overlay: radar)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let (frame, previous) = scene.frames
        let zoom = RadarTileKey.zoom(forScale: Double(zoomScale))
        scene.zoom = zoom
        guard !frame.layers.isEmpty else { return }
        context.interpolationQuality = .none
        let compositor = scene.compositor
        let z = frame.zoom(for: zoom)

        for (x, y) in frame.tiles(z: z, in: mapRect) {
            let rect = RadarTileKey.mapRect(z: z, x: x, y: y)
            switch compositor.cached(frame, z: z, x: x, y: y) {
            case .image(let image):
                RadarCompositor.drawTile(image, in: rect, context: context)
            case .empty:
                break
            case .pending:
                compositor.build(frame, z: z, x: x, y: y)
                drawStandIn(z: z, x: x, y: y, zoom: zoom, frame: frame, previous: previous, context: context)
            }
        }
    }

    /// Something to show while a picture waits for its tiles: the step
    /// before's, else a coarser one of this step's.
    private func drawStandIn(z: Int, x: Int, y: Int, zoom: Int, frame: RadarFrameRef, previous: RadarFrameRef?,
                             context: CGContext) {
        let compositor = scene.compositor
        let tile = RadarTileKey.mapRect(z: z, x: x, y: y)
        var candidates: [(RadarFrameRef, Int)] = []
        if let previous, previous.zoom(for: zoom) <= z { candidates.append((previous, previous.zoom(for: zoom))) }
        candidates += stride(from: z - 1, through: RadarLayer.minZoom, by: -1).map { (frame, $0) }
        for (stand, sz) in candidates {
            let (sx, sy) = (x >> (z - sz), y >> (z - sz))
            guard case .image(let image) = compositor.cached(stand, z: sz, x: sx, y: sy) else { continue }
            context.saveGState()
            context.clip(to: CGRect(x: tile.minX, y: tile.minY, width: tile.width, height: tile.height))
            RadarCompositor.drawTile(image, in: RadarTileKey.mapRect(z: sz, x: sx, y: sy), context: context)
            context.restoreGState()
            return
        }
    }
}
