import ImageIO
import MapKit
import UIKit

/// A MapKit basemap with the same value tiles, palette and coverage clipping
/// as the app. Only one radar tile is composed at a time; the interactive
/// map's large playback caches are never created in the widget extension.
enum NativeWidgetMap {
    struct Projection: Codable, Sendable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        func position(of coordinate: CLLocationCoordinate2D, image: CGSize, frame: CGSize) -> CGPoint {
            let point = MKMapPoint(coordinate)
            let scale = max(frame.width / image.width, frame.height / image.height)
            return CGPoint(x: frame.width / 2 + ((point.x - x) / width - 0.5) * image.width * scale,
                           y: frame.height / 2 + ((point.y - y) / height - 0.5) * image.height * scale)
        }
    }

    struct Picture: Codable, Sendable {
        let data: Data
        let projection: Projection
        let rendered: Date
    }

    @MainActor static func render(card: PreviewCard, pixels: CGSize, style: MapStyle,
                                  endpoints: NativeMapEndpoints, session: URLSession) async -> Picture? {
        guard pixels.width > 0, pixels.height > 0 else { return nil }
        let deadline = Date().addingTimeInterval(20)
        let product = RadarProduct(setting: style.product)
        let seriesURL = endpoints.timeseries(latitude: nil, longitude: nil, network: nil,
                                              products: product.timeseriesProducts)
        guard let data = await fetch(seriesURL, session: session, deadline: deadline),
              let series = try? RadarSeries.decode(data) else { return nil }
        let timeline = RadarTimeline(series: series, clock: series.serverTime, product: product)
        guard let now = timeline.now, let layers = timeline.layers[now], !layers.isEmpty,
              series.replay == true || abs(Int(Date().timeIntervalSince1970) - now) < RadarTimeline.networkFreshness else {
            return nil
        }

        // Match the preview card's geographic extent after its center crop.
        // Native snapshots use the widget's aspect ratio, including portrait XL.
        let crop = max(pixels.width / card.size.width, pixels.height / card.size.height)
        let units = MKMapSize.world.width / (256 * pow(2, card.zoom))
        let center = MKMapPoint(CLLocationCoordinate2D(latitude: card.latitude, longitude: card.longitude))
        let width = pixels.width / crop * units, height = pixels.height / crop * units
        let rect = MKMapRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
        let reduction = min(1, 1200 / max(pixels.width, pixels.height))
        let size = CGSize(width: (pixels.width * reduction).rounded() / 2,
                          height: (pixels.height * reduction).rounded() / 2)
        let options = MKMapSnapshotter.Options()
        options.mapRect = rect
        options.size = size
        options.scale = 2
        options.traitCollection = UITraitCollection { traits in
            traits.userInterfaceStyle = style.isDark ? .dark : .light
            traits.displayScale = 2
        }
        let busy = style.baseLayer == "osm" || style.baseLayer == "cyclosm"
        let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: busy ? .default : .muted)
        configuration.pointOfInterestFilter = style.baseLayer == "cyclosm"
            ? MKPointOfInterestFilter(including: [.park, .nationalPark, .campground, .beach]) : .excludingAll
        options.preferredConfiguration = configuration
        let snapshotter = MKMapSnapshotter(options: options)
        let timeout = Task {
            try await Task.sleep(for: .seconds(8))
            snapshotter.cancel()
        }
        defer { timeout.cancel() }
        guard let snapshot = try? await snapshotter.start(), let base = snapshot.image.cgImage,
              !Task.isCancelled else { return nil }
        timeout.cancel()

        // Derive the projection from MapKit's actual output, which can adjust
        // the requested extent. Use it for both the radar and the place marker.
        let top = snapshot.point(for: rect.origin.coordinate)
        let bottom = snapshot.point(for: MKMapPoint(x: rect.maxX, y: rect.maxY).coordinate)
        let sx = (bottom.x - top.x) / rect.width, sy = (bottom.y - top.y) / rect.height
        guard sx > 0, sy > 0 else { return nil }
        let projection = Projection(x: rect.minX - top.x / sx, y: rect.minY - top.y / sy,
                                    width: snapshot.image.size.width / sx, height: snapshot.image.size.height / sy)
        let visible = MKMapRect(x: projection.x, y: projection.y, width: projection.width, height: projection.height)
        let coverage = RadarCoverage.bundled()
        // Without the clipping document, adjacent countries would be missing.
        guard !coverage.domains.isEmpty else { return nil }
        let frame = RadarFrameRef(layers: layers, coverage: coverage)
        let z = frame.zoom(for: RadarTileKey.zoom(forScale: Double(base.width) / visible.width))
        let tiles = frame.tiles(z: z, in: visible)
        guard !tiles.isEmpty, tiles.count <= 36,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: base.width, height: base.height,
                                      bitsPerComponent: 8, bytesPerRow: base.width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        context.interpolationQuality = .none
        let palette = RadarLUT(palette: style.colormap)
        let pixelScale = Double(base.width) / snapshot.image.size.width
        for tile in tiles {
            let area = RadarTileKey.mapRect(z: z, x: tile.x, y: tile.y)
            var sources: [(RadarLayer, RadarTileKey, CGImage)] = []
            for layer in layers where coverage.bounds(of: layer.clip).intersects(area) {
                let sourceZ = min(z, layer.maxZoom)
                let key = RadarTileKey(layer, z: sourceZ, x: tile.x >> (z - sourceZ), y: tile.y >> (z - sourceZ))
                guard layer.index.has(z: key.z, x: key.x, y: key.y) else { continue }
                guard let png = await fetch(key.url(base: endpoints.tiles), session: session, deadline: deadline) else {
                    return nil // A partial picture must not look like dry weather.
                }
                if png.isEmpty { continue } // A 404 is an unpublished, empty tile.
                guard let source = CGImageSourceCreateWithData(png as CFData, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      properties[kCGImagePropertyPixelWidth] as? Int == 512,
                      properties[kCGImagePropertyPixelHeight] as? Int == 512,
                      let grey = GreyPNG.decode(png) else { return nil }
                if let image = palette.colour(grey) { sources.append((layer, key, image)) }
            }
            if sources.isEmpty { continue }
            guard let image = RadarCompositor.compose(sources, into: area, coverage: coverage) else { return nil }
            let a = snapshot.point(for: area.origin.coordinate)
            let b = snapshot.point(for: MKMapPoint(x: area.maxX, y: area.maxY).coordinate)
            context.setAlpha(0.75)
            context.draw(image, in: CGRect(x: a.x * pixelScale, y: Double(base.height) - b.y * pixelScale,
                                           width: (b.x - a.x) * pixelScale, height: (b.y - a.y) * pixelScale))
        }
        guard !Task.isCancelled, let image = context.makeImage(), let png = UIImage(cgImage: image).pngData() else { return nil }
        return Picture(data: png, projection: projection, rendered: Date(timeIntervalSince1970: Double(now)))
    }

    private static func fetch(_ url: URL, session: URLSession, deadline: Date) async -> Data? {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0, !Task.isCancelled else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = min(5, remaining)
        request.setValue(UserAgent.value, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 404, url.pathExtension == "png" { return Data() }
        return http.statusCode == 200 && !data.isEmpty ? data : nil
    }
}
