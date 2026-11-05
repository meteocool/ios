//
//  SnowOverlay.swift
//  meteocool
//
//  Where it snows: core's snow overlay (`RadarCapability.processSnowOverlay`).
//

import MapKit
import UIKit

/// `GET /v3/radar/snow` (404: no snow anywhere).
struct SnowState: Decodable, Equatable {
    let active: Bool
    let tileId: String
    let upstreamTime: Int?

    static func decode(_ data: Data) -> SnowState? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(SnowState.self, from: data)
    }
}

/// The snow areas on the live radar: polygons from vector tiles
/// (`{tiles}/meteoradar/{tile_id}/{z}/{x}/{y}.pbf`, zooms 0–5) filled with
/// core's snowflake pattern, half see-through past zoom 12.
@MainActor
final class SnowOverlay: NativeMapFeature {
    /// core's `DECREASE_SNOW_TRANSPARENCY_ZOOMLEVEL`.
    static let fadeZoom = 12.0
    nonisolated private static let pattern = UIImage(named: "MapSnow")?.cgImage

    private weak var map: NativeMapContext?
    private let overlay = VectorTileOverlay(maxZoom: 5) { tile, zoomScale, context in
        guard let pattern = SnowOverlay.pattern else { return }
        let path = CGMutablePath()
        for layer in tile.layers {
            for feature in layer.features where feature.type == .polygon {
                for ring in tile.points(feature, extent: layer.extent) where ring.count > 2 {
                    path.addLines(between: ring)
                    path.closeSubpath()
                }
            }
        }
        guard !path.isEmpty else { return }
        context.addPath(path)
        context.clip(using: .evenOdd)
        // The pattern at its own size on screen, whatever the zoom.
        let side = CGFloat(pattern.width) / zoomScale / 2
        let origin = CGPoint(x: floor(tile.rect.minX / side) * side, y: floor(tile.rect.minY / side) * side)
        context.draw(pattern, in: CGRect(origin: origin, size: CGSize(width: side, height: side)), byTiling: true)
    }
    private var state: SnowState?
    private var live = true
    private var added = false
    /// A past window's step on screen, and the snowfields of each step asked
    /// (nil where none was measured), so playing asks each once.
    private var windowStep: Int?
    private var past: [Int: SnowState?] = [:]
    private var asking = Set<Int>()

    func attach(to map: NativeMapContext) {
        self.map = map
        overlay.onTile = { [weak self] rect in
            guard let self, let map = self.map else { return }
            map.mapView.renderer(for: self.overlay)?.setNeedsDisplay(rect)
        }
    }

    func renderer(for overlay: MKOverlay) -> MKOverlayRenderer? {
        overlay === self.overlay ? VectorTileRenderer(overlay: overlay) : nil
    }

    func wake() { if windowStep == nil, map?.model.window == nil { load() } else { loadPast() } }

    func socketEvent(_ name: String, _ data: Data) {
        if name == "snow" { load() }
    }

    func stepDidChange(_ step: RadarStep) {
        live = step.time == nil || step.isLive
        windowStep = step.window != nil ? step.time : nil
        if windowStep != nil { loadPast() } else { update() }
    }

    func windowDidChange(_ window: RadarWindow?) {
        past = [:]
        asking = []
        windowStep = nil
        state = nil
        update()
    }

    /// `GET /v3/radar/snow?at=`: the snowfields measured at or before the
    /// window's step on screen (404 where there are none).
    private func loadPast() {
        guard let map, map.isOn(.snow), let step = windowStep else { return update() }
        if let held = past[step] {
            state = held
            return update()
        }
        guard !asking.contains(step) else { return }
        asking.insert(step)
        map.fetch(map.endpoints.snow(at: step)) { [weak self] data, status in
            guard let self else { return }
            self.asking.remove(step)
            if status == 404 {
                self.past[step] = .some(nil)
            } else if let data, let state = SnowState.decode(data) {
                self.past[step] = state
            } else {
                return
            }
            if self.past.count > 400 { self.past = [step: self.past[step]!] }
            if step == self.windowStep {
                self.state = self.past[step]!
                self.update()
            }
        }
    }

    func settingsDidChange() { if windowStep != nil { loadPast() } else { update() } }

    func regionDidChange() {
        guard let map, added else { return }
        map.mapView.renderer(for: overlay)?.alpha = map.zoomLevel > Self.fadeZoom ? 0.5 : 1
    }

    private func load() {
        guard let map, map.isOn(.snow), map.model.window == nil else { return }
        map.fetch(map.endpoints.snow) { [weak self] data, status in
            guard let self else { return }
            if status == 404 {
                self.state = nil
            } else if let data, let state = SnowState.decode(data) {
                self.state = state
            } else {
                return
            }
            self.update()
        }
    }

    private func update() {
        guard let map else { return }
        if let state, state.active, !state.tileId.isEmpty {
            overlay.urlTemplate = map.endpoints.tiles.appendingPathComponent("meteoradar/\(state.tileId)").absoluteString + "/{z}/{x}/{y}.pbf"
        } else {
            overlay.urlTemplate = nil
        }
        let show = map.isOn(.snow) && (live || windowStep != nil) && overlay.urlTemplate != nil && map.model.capability == .radar
        if show != added {
            added = show
            if show { map.mapView.addOverlay(overlay, level: .aboveRoads) } else { map.mapView.removeOverlay(overlay) }
        }
        if show { map.mapView.renderer(for: overlay)?.setNeedsDisplay() }
    }
}
