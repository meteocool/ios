//
//  VectorTileOverlay.swift
//  meteocool
//
//  Mapbox vector tiles as a MapKit overlay: fetched, decoded, cached, and
//  drawn by whoever owns the overlay.
//

import MapKit
import UIKit

/// A vector tile source (`{z}/{x}/{y}` with XYZ y, 512 px tiles as
/// OpenLayers' `VectorTileSource` makes them), drawn by `draw`.
final class VectorTileOverlay: NSObject, MKOverlay, @unchecked Sendable {
    /// A tile's features in map points, ready to draw.
    struct Tile {
        let rect: MKMapRect
        let layers: [VectorTile.Layer]

        /// A feature's parts in map points.
        func points(_ feature: VectorTile.Feature, extent: Int) -> [[CGPoint]] {
            let scale = rect.width / Double(extent)
            return feature.parts.map { part in
                part.map { CGPoint(x: rect.minX + $0.x * scale, y: rect.minY + $0.y * scale) }
            }
        }
    }

    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let boundingMapRect = MKMapRect.world
    let minZoom: Int
    let maxZoom: Int
    /// Draws one tile into the renderer's context; called on drawing threads.
    let draw: @Sendable (Tile, MKZoomScale, CGContext) -> Void
    /// Called on the main queue when a tile arrived, with its rect.
    var onTile: (@MainActor (MKMapRect) -> Void)?

    private let lock = NSLock()
    private var template: String?
    private var tiles: [String: Tile] = [:]
    private var order: [String] = []
    private var loading = Set<String>()
    private var failed = Set<String>()
    private static let cacheSize = 96

    init(minZoom: Int = 0, maxZoom: Int, draw: @escaping @Sendable (Tile, MKZoomScale, CGContext) -> Void) {
        self.minZoom = minZoom
        self.maxZoom = maxZoom
        self.draw = draw
    }

    /// `…/{z}/{x}/{y}.pbf`; nil draws nothing. A new source forgets the old tiles.
    var urlTemplate: String? {
        get { lock.withLock { template } }
        set {
            lock.withLock {
                guard newValue != template else { return }
                template = newValue
                tiles = [:]
                order = []
                loading = []
                failed = []
            }
        }
    }

    /// The tiles for `mapRect` at the zoom MapKit draws, nearest coarser
    /// stand-ins for those still loading; asks for what is missing.
    func tiles(for mapRect: MKMapRect, zoomScale: MKZoomScale) -> [Tile] {
        let z = max(minZoom, min(maxZoom, RadarTileKey.zoom(forScale: Double(zoomScale))))
        guard let range = RadarTileKey.range(z: z, covering: mapRect) else { return [] }
        var out: [Tile] = []
        var missing: [(String, Int, Int, Int)] = []
        lock.withLock {
            guard template != nil else { return }
            for x in range.x {
                for y in range.y {
                    let key = "\(z)/\(x)/\(y)"
                    if let tile = tiles[key] {
                        out.append(tile)
                    } else if !failed.contains(key) {
                        if !loading.contains(key) { missing.append((key, z, x, y)) }
                        // A coarser tile meanwhile.
                        var (pz, px, py) = (z, x, y)
                        while pz > minZoom {
                            (pz, px, py) = (pz - 1, px / 2, py / 2)
                            if let parent = tiles["\(pz)/\(px)/\(py)"] {
                                if !out.contains(where: { MKMapRectEqualToRect($0.rect, parent.rect) }) { out.append(parent) }
                                break
                            }
                        }
                    }
                }
            }
        }
        for (key, z, x, y) in missing { load(key, z: z, x: x, y: y) }
        return out
    }

    private func load(_ key: String, z: Int, x: Int, y: Int) {
        let url: URL? = lock.withLock {
            guard let template, loading.insert(key).inserted else { return nil }
            return URL(string: template.replacingOccurrences(of: "{z}", with: "\(z)")
                .replacingOccurrences(of: "{x}", with: "\(x)").replacingOccurrences(of: "{y}", with: "\(y)"))
        }
        guard let url else { return }
        let source = lock.withLock { template }
        URLSession.shared.dataTask(with: url) { [weak self] data, response, _ in
            guard let self else { return }
            let status = (response as? HTTPURLResponse)?.statusCode
            let decoded = status == 200 ? data.flatMap { try? VectorTile(data: $0) } : nil
            let rect = RadarTileKey.mapRect(z: z, x: x, y: y)
            let changed: Bool = self.lock.withLock {
                guard self.template == source else { return false }
                self.loading.remove(key)
                guard let decoded else {
                    // Absent (404) is nothing to draw; a failure is tried again later.
                    if status == 404 { self.failed.insert(key) }
                    return false
                }
                self.tiles[key] = Tile(rect: rect, layers: decoded.layers)
                self.order.append(key)
                if self.order.count > Self.cacheSize { self.tiles[self.order.removeFirst()] = nil }
                return true
            }
            guard changed else { return }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.onTile?(rect) }
            }
        }.resume()
    }
}

final class VectorTileRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let source = overlay as? VectorTileOverlay else { return }
        context.clip(to: CGRect(x: mapRect.minX, y: mapRect.minY, width: mapRect.width, height: mapRect.height))
        for tile in source.tiles(for: mapRect, zoomScale: zoomScale) {
            context.saveGState()
            context.clip(to: CGRect(x: tile.rect.minX, y: tile.rect.minY, width: tile.rect.width, height: tile.rect.height))
            source.draw(tile, zoomScale, context)
            context.restoreGState()
        }
    }
}
