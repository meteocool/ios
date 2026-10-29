//
//  RadarTileStore.swift
//  meteocool
//
//  Fetches, decodes and colours the radar's value tiles for the native map.
//

import Foundation
import MapKit

/// One value tile: `{tiles}/{bucket}/{tile_id}/{z}/{x}/{-y}.png` (core's
/// `layers/dwd.ts`), 512 px, Web Mercator, TMS y in the URL.
struct RadarTileKey: Hashable, Sendable {
    let bucket: String
    let tileId: String
    let z: Int
    let x: Int
    /// XYZ, top row 0.
    let y: Int

    init(_ layer: RadarLayer, z: Int, x: Int, y: Int) {
        (bucket, tileId, self.z, self.x, self.y) = (layer.bucket, layer.tileId, z, x, y)
    }

    func url(base: URL) -> URL {
        base.appendingPathComponent("\(bucket)/\(tileId)/\(z)/\(x)/\((1 << z) - 1 - y).png")
    }

    var mapRect: MKMapRect { Self.mapRect(z: z, x: x, y: y) }

    static func mapRect(z: Int, x: Int, y: Int) -> MKMapRect {
        let size = MKMapSize.world.width / Double(1 << z)
        return MKMapRect(x: Double(x) * size, y: Double(y) * size, width: size, height: size)
    }

    /// The tiles of zoom `z` that `rect` touches.
    static func range(z: Int, covering rect: MKMapRect) -> (x: ClosedRange<Int>, y: ClosedRange<Int>)? {
        guard !rect.isNull, !rect.isEmpty else { return nil }
        let n = 1 << z
        let size = MKMapSize.world.width / Double(n)
        let x0 = max(0, Int(floor(rect.minX / size))), x1 = min(n - 1, Int(floor((rect.maxX - 1e-6) / size)))
        let y0 = max(0, Int(floor(rect.minY / size))), y1 = min(n - 1, Int(floor((rect.maxY - 1e-6) / size)))
        guard x0 <= x1, y0 <= y1 else { return nil }
        return (x0 ... x1, y0 ... y1)
    }

    /// The zoom whose 512 px tiles come closest to one tile pixel per point
    /// at `zoomScale` (points per map point), as OpenLayers picks it.
    /// A scale of zero or less, or none at all, is zoom 0, not a trap.
    static func zoom(forScale zoomScale: Double) -> Int {
        let zoom = log2(MKMapSize.world.width * zoomScale / 512)
        guard zoom.isFinite else { return 0 }
        return Int(zoom.rounded())
    }
}

/// Tiles for the native radar map: fetched a few at a time, nearest frame
/// first; kept compressed, and decoded and coloured on demand, from the
/// renderer's drawing threads.
final class RadarTileStore: @unchecked Sendable {
    enum Lookup {
        case image(CGImage)
        /// Nothing to draw there: blank, or not published (404).
        case empty
        case pending
    }

    /// Called on the main queue when a tile has arrived or turned out empty.
    var onTile: (@MainActor (RadarTileKey) -> Void)?

    private let lock = NSLock()
    private let session: URLSession
    private var base: URL
    private var lut: RadarLUT
    /// Compressed PNGs, small: what the network delivered.
    private let pngs = NSCache<NSString, NSData>()
    /// Coloured tiles, a megabyte each, in the current palette.
    private let images = NSCache<NSString, ImageBox>()
    private var missing = Set<RadarTileKey>()
    private var pending: [RadarTileKey: Int] = [:]
    private var running = Set<RadarTileKey>()
    private static let concurrency = 8

    private final class ImageBox {
        let image: CGImage?
        init(_ image: CGImage?) { self.image = image }
    }

    init(base: URL, palette: String) {
        self.base = base
        lut = RadarLUT(palette: palette)
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = Self.concurrency
        // A tile's URL names its frame, so what was fetched once never changes.
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("NativeRadarTiles")
        configuration.urlCache = URLCache(memoryCapacity: 8 << 20, diskCapacity: 128 << 20, directory: cacheDirectory)
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
        pngs.totalCostLimit = 48 << 20
        // Only on their way into a step's picture (`RadarCompositor`).
        images.totalCostLimit = 48 << 20
    }

    deinit {
        session.invalidateAndCancel()
    }

    /// The palette and its ink, as the caches key them.
    var paletteName: String { lock.withLock { lut.id } }

    func setPalette(_ palette: String, ink: RadarLUT.Ink? = nil) {
        let changed = lock.withLock { () -> Bool in
            let next = RadarLUT(palette: palette, ink: ink)
            guard next.id != lut.id else { return false }
            lut = next
            return true
        }
        if changed { images.removeAllObjects() }
    }

    func setBase(_ url: URL) {
        lock.withLock {
            guard url != base else { return }
            base = url
            pending.removeAll()
            missing.removeAll()
        }
    }

    /// The tile as it can be drawn now, without waiting for the network.
    func lookup(_ key: RadarTileKey) -> Lookup {
        let (name, lut, isMissing) = lock.withLock { (cacheName(key), self.lut, missing.contains(key)) }
        if isMissing { return .empty }
        if let box = images.object(forKey: name) { return box.image.map(Lookup.image) ?? .empty }
        guard let png = pngs.object(forKey: cacheName(key, palette: false)) else { return .pending }
        let image = GreyPNG.decode(png as Data).flatMap(lut.colour)
        images.setObject(ImageBox(image), forKey: name, cost: image == nil ? 1 : (image!.bytesPerRow * image!.height))
        return image.map(Lookup.image) ?? .empty
    }

    /// Fetches what is missing of `keys`, sooner for a lower `priority`.
    func request(_ keys: [RadarTileKey], priority: Int) {
        lock.withLock {
            for key in keys where !missing.contains(key) && !running.contains(key) {
                guard pngs.object(forKey: cacheName(key, palette: false)) == nil else { continue }
                pending[key] = min(pending[key] ?? .max, priority)
            }
        }
        pump()
    }

    /// Replaces what waits to be fetched by a new plan (a moved map, another
    /// frame); fetches already under way finish.
    func replacePlan(_ plan: [RadarTileKey: Int]) {
        lock.withLock {
            pending = plan.filter { key, _ in
                !missing.contains(key) && !running.contains(key) && pngs.object(forKey: cacheName(key, palette: false)) == nil
            }
        }
        pump()
    }

    private func pump() {
        let next: [(RadarTileKey, URL)] = lock.withLock {
            var picked: [(RadarTileKey, URL)] = []
            while running.count < Self.concurrency, let key = pending.min(by: { $0.value < $1.value })?.key {
                pending[key] = nil
                running.insert(key)
                picked.append((key, key.url(base: base)))
            }
            return picked
        }
        for (key, url) in next {
            let task = session.dataTask(with: url) { [weak self] data, response, error in
                self?.finished(key, data: data, status: (response as? HTTPURLResponse)?.statusCode, failed: error != nil)
            }
            task.resume()
        }
    }

    private func finished(_ key: RadarTileKey, data: Data?, status: Int?, failed: Bool) {
        var notify = false
        lock.withLock {
            running.remove(key)
            if let status, status == 404 || status == 403 {
                // Not published: a tile with nothing in it.
                if missing.count > 20_000 { missing.removeAll() }
                missing.insert(key)
                notify = true
            } else if !failed, status == 200, let data {
                pngs.setObject(data as NSData, forKey: cacheName(key, palette: false), cost: data.count)
                notify = true
            }
        }
        pump()
        guard notify else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onTile?(key) }
        }
    }

    private func cacheName(_ key: RadarTileKey, palette: Bool = true) -> NSString {
        "\(palette ? lut.id : "png")/\(key.bucket)/\(key.tileId)/\(key.z)/\(key.x)/\(key.y)" as NSString
    }
}
