//
//  RadarCompositor.swift
//  meteocool
//
//  Each step's picture, tile by tile, put together before it is shown.
//

import Foundation
import MapKit

/// One step's layers, named so its pictures can be kept and found again.
struct RadarFrameRef: Sendable, Equatable {
    let key: String
    let layers: [RadarLayer]
    /// Where any of its layers may draw.
    let bounds: MKMapRect
    /// The deepest zoom any of its layers has tiles at.
    let deepest: Int

    static let none = RadarFrameRef(layers: [], coverage: .empty)

    init(layers: [RadarLayer], coverage: RadarCoverage) {
        self.layers = layers
        key = layers.map { "\($0.key):\($0.tileId)" }.joined(separator: ",")
        bounds = layers.reduce(MKMapRect.null) { $0.union(coverage.bounds(of: $1.clip)) }
        deepest = layers.map(\.maxZoom).max() ?? RadarLayer.minZoom
    }

    static func == (a: RadarFrameRef, b: RadarFrameRef) -> Bool { a.key == b.key }

    /// The tile zoom its picture is put together at for MapKit's `zoom`:
    /// past its deepest tiles, those are drawn larger.
    func zoom(for zoom: Int) -> Int { max(RadarLayer.minZoom, min(zoom, deepest)) }

    /// Its tiles inside `rect` at tile zoom `z`.
    func tiles(z: Int, in rect: MKMapRect) -> [(x: Int, y: Int)] {
        guard let range = RadarTileKey.range(z: z, covering: bounds.intersection(rect)) else { return [] }
        return range.x.flatMap { x in range.y.map { y in (x, y) } }
    }
}

/// Puts a step's layers together into one image per tile, the way core's
/// flat map stacks them: each network cut to its own ground, DWD to its
/// extent with the networks' ground cut out, pixels unsmoothed.
///
/// Doing it ahead of time keeps the renderer to copying finished images,
/// so a new step replaces the old one everywhere at once instead of tile by
/// tile, and playback waits for a step until its pictures are ready.
final class RadarCompositor: @unchecked Sendable {
    enum Result {
        case image(CGImage)
        case empty
        case pending
    }

    let store: RadarTileStore
    /// Called on the main queue when pictures were put together ahead.
    var onPrepared: (@MainActor () -> Void)?
    /// Called on the main queue with a picture `build` put together.
    var onBuilt: (@MainActor (RadarFrameRef, MKMapRect) -> Void)?

    private let lock = NSLock()
    private var coverage: RadarCoverage
    private let pictures = NSCache<NSString, Box>()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()
    /// Pictures the map is waiting for, put together before anything ahead.
    private let urgent: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInteractive
        return queue
    }()
    private var building = Set<String>()
    private var generation = 0

    private final class Box {
        let image: CGImage?
        init(_ image: CGImage?) { self.image = image }
    }

    /// Pixels per tile side, as the tiles come.
    private static let side = 512

    init(store: RadarTileStore, coverage: RadarCoverage) {
        self.store = store
        self.coverage = coverage
        pictures.totalCostLimit = 192 << 20
    }

    func setCoverage(_ coverage: RadarCoverage) {
        lock.withLock { self.coverage = coverage }
        clear()
    }

    /// Forgets every picture: the palette or the ground changed.
    func clear() {
        pictures.removeAllObjects()
    }

    /// The picture as already put together; nothing is fetched or drawn.
    func cached(_ frame: RadarFrameRef, z: Int, x: Int, y: Int) -> Result {
        guard let box = pictures.object(forKey: name(frame, z, x, y)) else { return .pending }
        return box.image.map(Result.image) ?? .empty
    }

    /// The picture, put together now if every tile it needs is here; asks
    /// for the missing ones otherwise.
    func picture(_ frame: RadarFrameRef, z: Int, x: Int, y: Int, priority: Int = 0) -> Result {
        let name = name(frame, z, x, y)
        if let box = pictures.object(forKey: name) { return box.image.map(Result.image) ?? .empty }

        let rect = RadarTileKey.mapRect(z: z, x: x, y: y)
        let coverage = lock.withLock { self.coverage }
        var sources: [(RadarLayer, RadarTileKey, CGImage)] = []
        var waiting: [RadarTileKey] = []
        for layer in frame.layers where coverage.bounds(of: layer.clip).intersects(rect) {
            let sz = max(RadarLayer.minZoom, min(z, layer.maxZoom))
            let key = RadarTileKey(layer, z: sz, x: x >> (z - sz), y: y >> (z - sz))
            guard layer.index.has(z: key.z, x: key.x, y: key.y) else { continue }
            switch store.lookup(key) {
            case .image(let image): sources.append((layer, key, image))
            case .empty: break
            case .pending: waiting.append(key)
            }
        }
        if !waiting.isEmpty {
            store.request(waiting, priority: priority)
            return .pending
        }
        let image = sources.isEmpty ? nil : Self.compose(sources, into: rect, coverage: coverage)
        pictures.setObject(Box(image), forKey: name, cost: image == nil ? 1 : image!.bytesPerRow * image!.height)
        return image.map(Result.image) ?? .empty
    }

    /// Puts a picture together off the drawing thread, for a tile the map
    /// drew without it; `onBuilt` says when to draw it again.
    func build(_ frame: RadarFrameRef, z: Int, x: Int, y: Int) {
        let name = name(frame, z, x, y) as String
        guard lock.withLock({ building.insert(name).inserted }) else { return }
        urgent.addOperation { [weak self] in
            guard let self else { return }
            let result = self.picture(frame, z: z, x: x, y: y)
            self.lock.withLock { _ = self.building.remove(name) }
            if case .pending = result { return }
            let rect = RadarTileKey.mapRect(z: z, x: x, y: y)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.onBuilt?(frame, rect) }
            }
        }
    }

    /// Whether every picture of `frame` in `rect` is ready to show.
    func isReady(_ frame: RadarFrameRef, zoom: Int, in rect: MKMapRect) -> Bool {
        let z = frame.zoom(for: zoom)
        return frame.tiles(z: z, in: rect).allSatisfy { tile in
            if case .pending = cached(frame, z: z, x: tile.x, y: tile.y) { return false }
            return true
        }
    }

    /// At most this many pictures (a megabyte each) are put together ahead,
    /// well inside the cache, so preparing never pushes out what is on screen.
    static let prepareBudget = 120

    /// Puts frames' pictures together in the background, in the order given,
    /// as many as `prepareBudget` allows; replaces what was still waiting
    /// from the last call.
    func prepare(_ frames: [RadarFrameRef], zoom: Int, in rect: MKMapRect) {
        queue.cancelAllOperations()
        let generation = lock.withLock { () -> Int in
            self.generation += 1
            return self.generation
        }
        var priority = 0
        var budget = Self.prepareBudget
        for frame in frames where !frame.layers.isEmpty {
            let z = frame.zoom(for: zoom)
            let tiles = frame.tiles(z: z, in: rect)
            guard tiles.count <= budget else { break }
            budget -= tiles.count
            for tile in tiles {
                let distance = priority
                queue.addOperation { [weak self] in
                    guard let self, self.lock.withLock({ self.generation == generation }) else { return }
                    if case .pending = self.cached(frame, z: z, x: tile.x, y: tile.y) {
                        if case .image = self.picture(frame, z: z, x: tile.x, y: tile.y, priority: distance) {
                            self.notifyPrepared()
                        }
                    }
                }
            }
            priority += 1
        }
    }

    private var notifyScheduled = false

    /// Coalesces the main-queue callbacks of a burst of finished pictures.
    private func notifyPrepared() {
        let schedule = lock.withLock { () -> Bool in
            guard !notifyScheduled else { return false }
            notifyScheduled = true
            return true
        }
        guard schedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.notifyScheduled = false }
            MainActor.assumeIsolated { self.onPrepared?() }
        }
    }

    private func name(_ frame: RadarFrameRef, _ z: Int, _ x: Int, _ y: Int) -> NSString {
        "\(store.paletteName)|\(frame.key)|\(z)/\(x)/\(y)" as NSString
    }

    /// The layers on one tile, in map points, onto a bitmap of the tile.
    private static func compose(_ sources: [(RadarLayer, RadarTileKey, CGImage)], into rect: MKMapRect,
                                coverage: RadarCoverage) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let scale = Double(side) / rect.width
        // Map points grow downwards, the bitmap's rows upwards.
        context.translateBy(x: 0, y: CGFloat(side))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        context.interpolationQuality = .none
        let area = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)

        for (layer, key, image) in sources {
            context.saveGState()
            switch layer.clip {
            case .exclusive(let code):
                guard let domain = coverage.domains[code] else { context.restoreGState(); continue }
                context.addPath(domain.exclusive)
                context.clip(using: .evenOdd)
                drawTile(image, in: key.mapRect, context: context)
            case .allNetworks:
                context.addPath(coverage.allNetworks)
                context.clip(using: .evenOdd)
                drawTile(image, in: key.mapRect, context: context)
            case .whole:
                let extent = RadarCoverage.wholeExtent
                context.clip(to: CGRect(x: extent.minX, y: extent.minY, width: extent.width, height: extent.height))
                drawTile(image, in: key.mapRect, context: context)
            case .dwd(let holes):
                let extent = RadarCoverage.dwdExtent
                context.clip(to: CGRect(x: extent.minX, y: extent.minY, width: extent.width, height: extent.height))
                context.beginTransparencyLayer(in: area, auxiliaryInfo: nil)
                drawTile(image, in: key.mapRect, context: context)
                // Erase the networks' ground, each on its own: their holes
                // overlap where two networks meet.
                context.setBlendMode(.clear)
                for code in holes {
                    guard let hole = coverage.domains[code]?.dwdHole, !hole.isEmpty,
                          hole.boundingBoxOfPath.intersects(area) else { continue }
                    context.addPath(hole)
                    context.fillPath(using: .evenOdd)
                }
                context.endTransparencyLayer()
            }
            context.restoreGState()
        }
        return context.makeImage()
    }

    /// Draws a tile image into its map rect, rows flipped to map points.
    static func drawTile(_ image: CGImage, in rect: MKMapRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        context.restoreGState()
    }
}
