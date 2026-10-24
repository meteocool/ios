//
//  SiteSweepOverlay.swift
//  meteocool
//
//  One radar's sweep drawn in its own polar bins (core's
//  `layers/siteSweep.ts`).
//

import MapKit

/// What the sweep overlay draws, shared between the main thread and
/// MapKit's drawing threads.
final class SiteSweepScene: @unchecked Sendable {
    /// A sweep as drawn: its bins, the palette for them, and for
    /// storm-relative velocity each ray's share of the storm's motion.
    struct Drawn {
        let sweep: Sweep
        let geometry: SweepGeometry
        let reachM: Double
        /// Premultiplied RGBA per byte, R first in memory.
        let palette: [UInt32]
        /// The storm's speed along each ray, m/s, for storm-relative velocity.
        let motionAlong: [Double]?
    }

    private let lock = NSLock()
    private var current: Drawn?
    private var darkVeil = false

    var drawn: (Drawn?, Bool) { lock.withLock { (current, darkVeil) } }

    func show(_ drawn: Drawn?) {
        lock.withLock { current = drawn }
    }

    func setDark(_ dark: Bool) {
        lock.withLock { darkVeil = dark }
    }

    /// The drawing for a sweep: reflectivity in the reader's palette,
    /// velocity in its own, and SRV with the motion taken out per ray.
    static func drawing(_ sweep: Sweep, quantity: SiteQuantity, motion: StormMotion?, reflectivity: RadarLUT) -> Drawn {
        let geometry = sweep.header.geometry
        let palette = sweep.header.isVelocity ? velocityEntries : reflectivity.entries
        var along: [Double]?
        if quantity == .srv, let motion, sweep.header.isVelocity {
            along = (0 ..< geometry.nrays).map { ray in
                let azimuth = geometry.azimuth0Deg + Double(ray) * geometry.azimuthStepDeg
                return motion.speedMs * cos((azimuth - motion.headingDeg) * .pi / 180)
            }
        }
        return Drawn(sweep: sweep, geometry: geometry, reachM: SweepGeometryRules.reachM(geometry), palette: palette, motionAlong: along)
    }

    private static let velocityEntries: [UInt32] = VelocityPalette.table.map { c in
        let a = UInt32(c.a)
        return UInt32(c.r) * a / 255 | (UInt32(c.g) * a / 255) << 8 | (UInt32(c.b) * a / 255) << 16 | a << 24
    }
}

final class SiteSweepOverlay: NSObject, MKOverlay {
    let scene = SiteSweepScene()
    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let boundingMapRect = MKMapRect.world
}

/// Maps each pixel of a tile back to the bin under it, as core's fragment
/// shader does: Mercator to longitude and latitude, to the ground distance
/// and bearing from the site, along the 4/3-earth beam to a slant range, to
/// a bin and a ray, to a byte, to a colour. Past the last bin the map is
/// greyed, so the radar's reach reads at a glance.
final class SiteSweepRenderer: MKOverlayRenderer {
    private let scene: SiteSweepScene

    /// The grey past a sweep's reach, premultiplied, on a light map and a dark one.
    private static let lightVeil = premultiplied(96, 100, 108, 140)
    private static let darkVeil = premultiplied(0, 0, 0, 120)
    /// The most pixels a tile is drawn with across.
    private static let maxSide = 512

    init(sweep: SiteSweepOverlay) {
        scene = sweep.scene
        super.init(overlay: sweep)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let (drawn, dark) = scene.drawn
        guard let drawn else { return }
        let veil = dark ? Self.darkVeil : Self.lightVeil
        let rect = self.rect(for: mapRect)
        let g = drawn.geometry

        // A tile wholly past the reach is the veil alone.
        let north = MKMapPoint(x: mapRect.midX, y: mapRect.minY).coordinate.latitude
        let south = MKMapPoint(x: mapRect.midX, y: mapRect.maxY).coordinate.latitude
        let west = MKMapPoint(x: mapRect.minX, y: mapRect.midY).coordinate.longitude
        let east = MKMapPoint(x: mapRect.maxX, y: mapRect.midY).coordinate.longitude
        let nearest = SweepGeometryRules.fromSite(lon: g.lon, lat: g.lat, lon: min(max(g.lon, west), east), lat: min(max(g.lat, south), north))
        if nearest.groundM > drawn.reachM * 1.05 + 5000 {
            context.setFillColor(Self.cgColor(veil))
            context.fill(rect)
            return
        }

        let side = max(1, min(Self.maxSide, Int((mapRect.width * Double(zoomScale) * Double(contentScaleFactor)).rounded(.up))))
        guard let image = Self.render(drawn, mapRect: mapRect, side: side, veil: veil) else { return }
        context.interpolationQuality = .none
        RadarCompositor.drawTile(image, in: mapRect, context: context)
    }

    /// The tile's pixels, north row first.
    private static func render(_ drawn: SiteSweepScene.Drawn, mapRect: MKMapRect, side: Int, veil: UInt32) -> CGImage? {
        let g = drawn.geometry
        let rad = Double.pi / 180
        let earth = SweepGeometryRules.earthRadiusM
        let effective = SweepGeometryRules.effectiveRadiusM
        let siteLat = g.lat * rad
        let sinSite = sin(siteLat), cosSite = cos(siteLat)
        let elevation = g.elevationDeg * rad
        let step = mapRect.width / Double(side)

        // Longitude per column and latitude per row: Mercator keeps them apart.
        var sinHalfLon = [Double](repeating: 0, count: side)
        var sinLon = [Double](repeating: 0, count: side)
        var cosLon = [Double](repeating: 0, count: side)
        for i in 0 ..< side {
            let lon = MKMapPoint(x: mapRect.minX + (Double(i) + 0.5) * step, y: mapRect.midY).coordinate.longitude
            let d = (lon - g.lon) * rad
            sinHalfLon[i] = pow(sin(d / 2), 2)
            sinLon[i] = sin(d)
            cosLon[i] = cos(d)
        }

        var pixels = [UInt32](repeating: 0, count: side * side)
        drawn.sweep.bins.withUnsafeBufferPointer { bins in
            drawn.palette.withUnsafeBufferPointer { palette in
                for j in 0 ..< side {
                    let lat = MKMapPoint(x: mapRect.midX, y: mapRect.minY + (Double(j) + 0.5) * step).coordinate.latitude * rad
                    let cosLat = cos(lat), sinLat = sin(lat)
                    let sinHalfLat = pow(sin((lat - siteLat) / 2), 2)
                    let row = j * side
                    for i in 0 ..< side {
                        let a = sinHalfLat + cosSite * cosLat * sinHalfLon[i]
                        let ground = 2 * earth * asin(min(1, a.squareRoot()))
                        let s = ground / effective
                        let slant = effective * sin(s) / cos(elevation + s)
                        let binF = ((slant - g.rangeStartM) / g.rangeStepM).rounded(.down)
                        if !(slant >= 0) || binF >= Double(g.nbins) {
                            pixels[row + i] = veil
                            continue
                        }
                        if binF < 0 { continue }
                        let bearing = atan2(sinLon[i] * cosLat, cosSite * sinLat - sinSite * cosLat * cosLon[i]) / rad
                        let steps = ((bearing - g.azimuth0Deg) / g.azimuthStepDeg + 0.5).rounded(.down)
                        var ray = Int(steps.truncatingRemainder(dividingBy: Double(g.nrays)))
                        if ray < 0 { ray += g.nrays }
                        var index = Int(bins[ray * g.nbins + Int(binF)])
                        if let along = drawn.motionAlong, index >= 2, index <= 254 {
                            let relative = Double(index - Sweep.vradZero) * Sweep.vradStep - along[ray]
                            index = Int(min(254, max(2, (relative / Sweep.vradStep + 0.5).rounded(.down) + Double(Sweep.vradZero))))
                        }
                        pixels[row + i] = palette[index]
                    }
                }
            }
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private static func premultiplied(_ r: UInt32, _ g: UInt32, _ b: UInt32, _ a: UInt32) -> UInt32 {
        r * a / 255 | (g * a / 255) << 8 | (b * a / 255) << 16 | a << 24
    }

    private static func cgColor(_ packed: UInt32) -> CGColor {
        let a = Double(packed >> 24) / 255
        guard a > 0 else { return CGColor(gray: 0, alpha: 0) }
        // Back from premultiplied.
        return CGColor(srgbRed: Double(packed & 0xFF) / 255 / a, green: Double((packed >> 8) & 0xFF) / 255 / a,
                       blue: Double((packed >> 16) & 0xFF) / 255 / a, alpha: a)
    }
}
