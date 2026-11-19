//
//  MotionArrows.swift
//  meteocool
//
//  The rain's motion over the radar map: core's `layers/motionArrows.ts`
//  and `lib/MotionArrowManager.ts`.
//

import MapKit
import UIKit

/// `GET /v3/motion/layer`, and the `motion` event: the newest tile set of the
/// arrows, and the motion field it was drawn from.
struct MotionLayer: Decodable, Equatable {
    let tileId: String
    let validAt: Int?

    static func decode(_ data: Data) -> MotionLayer? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(MotionLayer.self, from: data)
    }
}

/// The rain's motion arrows: one arrow per block of the map, the block's
/// mean motion, from a vector tile set the server renders from every
/// domain's newest motion field. Off unless turned on (`layerMotion`).
///
/// Each zoom draws the arrows of one block size, its `level`, so they stay
/// about as far apart on the screen at every zoom and nothing here thins or
/// declutters them. The tiles stop at zoom 8 and hold the levels of the
/// zooms past it too; the drawing picks the zoom's own. They are drawn in
/// the map's own space, so they turn with it.
///
/// The arrows are the newest motion, whatever step the timeline shows; they
/// go faint on an observed step well before them (`MotionArrowRules.stale`).
/// The tile set is asked for when they come on and on a wake; the `motion`
/// event names each new one, which is switched to without asking. A backend
/// with no arrows is no arrows, and a past window has none.
@MainActor
final class MotionArrows: NativeMapFeature {
    /// How faint the arrows are while they are not the shown step's motion.
    static let staleOpacity: CGFloat = 0.35

    private weak var map: NativeMapContext?
    private let style = MotionArrowStyle()
    private lazy var overlay: VectorTileOverlay = {
        let style = self.style
        // The server's zooms, one block size each, are 256-pixel tiles': at
        // 512 a phone screen held too few arrows to see the field turn.
        // The tile set's deepest zoom is 8: past it, its tiles are drawn bigger.
        return VectorTileOverlay(maxZoom: 8, tileSize: 256) { tile, zoomScale, context in
            style.draw(tile, zoomScale: zoomScale, in: context)
        }
    }()
    private var shown = false
    private var added = false
    private var layer: MotionLayer?
    /// Bumped by every fetch, so an answer that lands after a newer one is dropped.
    private var generation = 0
    private var step: RadarStep?

    func attach(to map: NativeMapContext) {
        self.map = map
        overlay.onTile = { [weak self] rect in
            guard let self, let map = self.map else { return }
            map.mapView.renderer(for: self.overlay)?.setNeedsDisplay(rect.insetBy(dx: -rect.width / 4, dy: -rect.height / 4))
        }
    }

    func renderer(for overlay: MKOverlay) -> MKOverlayRenderer? {
        guard overlay === self.overlay else { return nil }
        let renderer = MotionArrowRenderer(overlay: overlay)
        renderer.alpha = stale ? Self.staleOpacity : 1
        return renderer
    }

    func wake() { if shown { fetch() } }
    func settingsDidChange() { update() }
    func capabilityDidChange(_ capability: NativeMapModel.Capability) { update() }
    func windowDidChange(_ window: RadarWindow?) { update() }

    func stepDidChange(_ step: RadarStep) {
        self.step = step
        restyle()
    }

    /// A new tile set was drawn: switch to it, if the arrows are on.
    func socketEvent(_ name: String, _ data: Data) {
        guard name == "motion", shown, let next = MotionLayer.decode(data) else { return }
        // Newer than any answer still on its way.
        generation += 1
        use(next)
    }

    /// The newest motion field alone is drawn: not in a past window, and only
    /// over the radar map.
    private func update() {
        guard let map else { return }
        style.dark = map.model.isDark
        let next = map.isOn(.motion) && map.model.capability == .radar && map.model.window == nil
        if next != shown {
            shown = next
            if shown { fetch() } else { use(nil) }
        }
        show()
    }

    private func fetch() {
        guard let map else { return }
        generation += 1
        let generation = self.generation
        map.fetch(map.endpoints.motionLayer) { [weak self] data, _ in
            guard let self, generation == self.generation, self.shown else { return }
            // None published yet, or the backend has none: no arrows, and the
            // next `motion` event brings the first.
            self.use(data.flatMap(MotionLayer.decode))
        }
    }

    private func use(_ next: MotionLayer?) {
        guard let map else { return }
        layer = next
        overlay.urlTemplate = next.map {
            map.endpoints.tiles.appendingPathComponent("meteoradar/\($0.tileId)").absoluteString + "/{z}/{x}/{y}.pbf"
        }
        show()
    }

    private func show() {
        guard let map else { return }
        let visible = shown && overlay.urlTemplate != nil
        if visible != added {
            added = visible
            // Over the radar, under the storm marks: either is what a tap is for.
            if visible { map.mapView.insertOverlay(overlay, above: map.radar.overlay) } else { map.mapView.removeOverlay(overlay) }
        }
        if visible { map.mapView.renderer(for: overlay)?.setNeedsDisplay() }
        restyle()
    }

    private var stale: Bool {
        MotionArrowRules.stale(frame: step?.time, arrows: layer?.validAt, onForecast: step?.isForecast ?? false)
    }

    private func restyle() {
        guard let map, added else { return }
        map.mapView.renderer(for: overlay)?.alpha = stale ? Self.staleOpacity : 1
    }
}

/// How the arrows are drawn, read on MapKit's drawing threads.
final class MotionArrowStyle: @unchecked Sendable {
    private let lock = NSLock()
    private var isDark = false

    /// On the dark map, light ink cased in dark; on the light one the other
    /// way round (core's `casing.ts`).
    var dark: Bool {
        get { lock.withLock { isDark } }
        set { lock.withLock { isDark = newValue } }
    }

    /// The farthest an arrow reaches from its block's middle, with its casing, in points.
    static let reach = MotionArrowRules.size.longest / 2 + 3

    /// Every arrow whose middle is on `tile`, at its size on screen.
    func draw(_ tile: VectorTileOverlay.Tile, zoomScale: MKZoomScale, in context: CGContext) {
        let dark = self.dark
        let ink = dark ? CGColor(red: 1, green: 1, blue: 1, alpha: 0.95) : CGColor(red: 17 / 255, green: 20 / 255, blue: 26 / 255, alpha: 0.9)
        let casing = dark ? CGColor(red: 12 / 255, green: 16 / 255, blue: 22 / 255, alpha: 0.75) : CGColor(red: 1, green: 1, blue: 1, alpha: 0.75)
        let points = 1 / Double(zoomScale)
        // The whole zoom of 256-pixel tiles drawn here, nearer in, and its level.
        let zoom = Int((log2(MKMapSize.world.width * Double(zoomScale) / 256) - 1e-9).rounded(.up))
        let level = MotionArrowRules.level(atZoom: min(MotionArrowRules.finestZoom, max(0, zoom)))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for layer in tile.layers {
            for feature in layer.features where feature.type == .point {
                // A tile set from before the levels were sent has one level a zoom already.
                if let own = feature.properties["level"]?.number, Int(own) != level { continue }
                guard let east = feature.properties["e"]?.number, let north = feature.properties["n"]?.number,
                      let shape = MotionArrowRules.arrow(east: east, north: north) else { continue }
                // A tile's buffer repeats its neighbours' arrows: each is drawn from its own tile.
                for part in feature.parts {
                    for at in part where at.x >= 0 && at.y >= 0 && at.x < Double(layer.extent) && at.y < Double(layer.extent) {
                        let scale = tile.rect.width / Double(layer.extent)
                        context.saveGState()
                        context.translateBy(x: tile.rect.minX + at.x * scale, y: tile.rect.minY + at.y * scale)
                        context.scaleBy(x: points, y: points)
                        // Twice: the casing wide underneath, then the ink.
                        for (colour, width) in [(casing, 4.5), (ink, 2.0)] {
                            context.setStrokeColor(colour)
                            context.setFillColor(colour)
                            context.setLineWidth(width)
                            context.strokeLineSegments(between: [shape.shaft.0, shape.shaft.1])
                            context.beginPath()
                            context.addLines(between: [shape.head.0, shape.head.1, shape.head.2])
                            context.closePath()
                            context.drawPath(using: .fillStroke)
                        }
                        context.restoreGState()
                    }
                }
            }
        }
    }
}

/// Draws the arrows of every tile near the part of the map asked for, uncut
/// at tile edges: an arrow is drawn whole wherever its middle falls.
final class MotionArrowRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let source = overlay as? VectorTileOverlay else { return }
        let reach = MotionArrowStyle.reach / Double(zoomScale)
        for tile in source.tiles(for: mapRect.insetBy(dx: -reach, dy: -reach), zoomScale: zoomScale) {
            source.draw(tile, zoomScale, context)
        }
    }
}
