import CoreGraphics
import CoreLocation
import Foundation

/// A square or wide preview card, as the API's preview images
/// (`/v3/preview/og.png`) snap it: the zoom to half steps, the centre
/// to a 32-pixel grid at that zoom. Asking for the snapped card means the
/// widgets share the service's cache with every rain alert near by, and
/// tells the widget where on the image the place itself is.
struct PreviewCard: Hashable {
    let latitude: Double
    let longitude: Double
    let zoom: Double
    let wide: Bool

    /// The captured page, in CSS pixels.
    var size: CGSize { wide ? CGSize(width: 1200, height: 630) : CGSize(width: 1024, height: 1024) }

    static let snapPixels = 32.0

    init(latitude: Double, longitude: Double, zoom: Double, wide: Bool) {
        let zoom = min(max((zoom * 2).rounded() / 2, 5.5), 18)
        let world = Self.world(zoom)
        let point = Self.project(latitude: latitude, longitude: longitude, world: world)
        let snapped = CGPoint(x: (point.x / Self.snapPixels).rounded() * Self.snapPixels,
                              y: (point.y / Self.snapPixels).rounded() * Self.snapPixels)
        self.longitude = snapped.x / world * 360 - 180
        self.latitude = atan(sinh(.pi * (1 - 2 * snapped.y / world))) * 180 / .pi
        self.zoom = zoom
        self.wide = wide
    }

    var key: String {
        String(format: "%.5f,%.5f,%.1f,%@", latitude, longitude, zoom, wide ? "wide" : "square")
    }

    /// Where `coordinate` is on the card, as a fraction of its size from the
    /// top left: (0.5, 0.5) is the centre.
    func position(of coordinate: CLLocationCoordinate2D) -> CGPoint {
        let world = Self.world(zoom)
        let centre = Self.project(latitude: latitude, longitude: longitude, world: world)
        let point = Self.project(latitude: coordinate.latitude, longitude: coordinate.longitude, world: world)
        return CGPoint(x: 0.5 + (point.x - centre.x) / size.width, y: 0.5 + (point.y - centre.y) / size.height)
    }

    private static func world(_ zoom: Double) -> Double { 256 * pow(2, zoom) }

    private static func project(latitude: Double, longitude: Double, world: Double) -> CGPoint {
        let sine = sin(min(max(latitude, -85), 85) * .pi / 180)
        return CGPoint(x: (longitude + 180) / 360 * world,
                       y: (0.5 - log((1 + sine) / (1 - sine)) / (4 * .pi)) * world)
    }
}
