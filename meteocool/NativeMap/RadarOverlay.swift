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

    /// Something to show while a picture waits for its tiles, of the same
    /// time where there is any (core's `lib/frameSwitch.ts`): a coarser
    /// picture of this step, a few zooms up; zooming out, the finer ones;
    /// only then the step before's.
    private func drawStandIn(z: Int, x: Int, y: Int, zoom: Int, frame: RadarFrameRef, previous: RadarFrameRef?,
                             context: CGContext) {
        let compositor = scene.compositor
        let tile = RadarTileKey.mapRect(z: z, x: x, y: y)
        func picture(_ of: RadarFrameRef, _ at: FrameSwitchRules.Tile) -> RadarCompositor.Result {
            compositor.cached(of, z: at.z, x: at.x, y: at.y)
        }
        // Ready: a picture, or known to have nothing to draw.
        func ready(_ at: FrameSwitchRules.Tile) -> Bool {
            if case .pending = picture(frame, at) { return false }
            return true
        }
        func draw(_ of: RadarFrameRef, _ at: FrameSwitchRules.Tile) {
            guard case .image(let image) = picture(of, at) else { return }
            context.saveGState()
            context.clip(to: CGRect(x: tile.minX, y: tile.minY, width: tile.width, height: tile.height))
            RadarCompositor.drawTile(image, in: RadarTileKey.mapRect(z: at.z, x: at.x, y: at.y), context: context)
            context.restoreGState()
        }
        let here = FrameSwitchRules.Tile(z: z, x: x, y: y)
        if let up = FrameSwitchRules.ancestor(of: here, minZ: RadarLayer.minZoom, depth: FrameSwitchRules.ancestorReach, has: ready) {
            return draw(frame, up)
        }
        let children = FrameSwitchRules.children(of: here, maxZ: frame.deepest, has: ready)
        if !children.isEmpty { return children.forEach { draw(frame, $0) } }
        // The step before, where this one has nothing yet (it waited as
        // long as it may, `RadarEngine.linger`).
        guard let previous else { return }
        let pz = previous.zoom(for: zoom)
        guard pz <= z else { return }
        draw(previous, FrameSwitchRules.Tile(z: pz, x: x >> (z - pz), y: y >> (z - pz)))
    }
}
