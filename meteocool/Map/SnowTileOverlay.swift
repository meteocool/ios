import CoreGraphics
import MapKit
import MVTTools
import UIKit

final class SnowTileOverlay: MKTileOverlay {
    private let renderQueue = DispatchQueue(label: "meteocool.snow.render", qos: .userInitiated)

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let url = self.url(forTilePath: path)
        URLSession.shared.dataTask(with: url) { data, _, error in
            guard let data else {
                result(nil, error)
                return
            }
            self.renderQueue.async {
                let imageData = SnowTileRenderer.render(tileData: data, tileX: path.x, tileY: path.y, zoom: path.z, tileSize: self.tileSize)
                result(imageData, nil)
            }
        }.resume()
    }
}

enum SnowTileRenderer {
    static func render(tileData: Data, tileX: Int, tileY: Int, zoom: Int, tileSize: CGSize) -> Data? {
        guard let tile = VectorTile(data: tileData, x: tileX, y: tileY, z: zoom, indexed: .hilbert) else {
            return nil
        }
        guard let geoData = tile.toGeoJson(prettyPrinted: false) else {
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: geoData, options: []),
              let dict = json as? [String: Any],
              let features = dict["features"] as? [[String: Any]] else {
            return nil
        }

        let renderer = UIGraphicsImageRenderer(size: tileSize)
        let image = renderer.image { ctx in
            ctx.cgContext.setFillColor(UIColor.white.withAlphaComponent(0.35).cgColor)
            let path = CGMutablePath()
            features.forEach { feature in
                guard let geometry = feature["geometry"] as? [String: Any],
                      let type = geometry["type"] as? String,
                      let coords = geometry["coordinates"] else { return }
                switch type {
                case "Polygon":
                    if let rings = coords as? [[[Double]]] {
                        addPolygon(rings: rings, path: path, tileX: tileX, tileY: tileY, zoom: zoom, tileSize: tileSize)
                    }
                case "MultiPolygon":
                    if let polygons = coords as? [[[[Double]]]] {
                        polygons.forEach { rings in
                            addPolygon(rings: rings, path: path, tileX: tileX, tileY: tileY, zoom: zoom, tileSize: tileSize)
                        }
                    }
                default:
                    break
                }
            }
            ctx.cgContext.addPath(path)
            ctx.cgContext.drawPath(using: .eoFill)
        }
        return image.pngData()
    }

    private static func addPolygon(rings: [[[Double]]], path: CGMutablePath, tileX: Int, tileY: Int, zoom: Int, tileSize: CGSize) {
        for ring in rings {
            guard let first = ring.first else { continue }
            let start = project(lon: first[0], lat: first[1], tileX: tileX, tileY: tileY, zoom: zoom, tileSize: tileSize)
            path.move(to: start)
            for coord in ring.dropFirst() {
                let point = project(lon: coord[0], lat: coord[1], tileX: tileX, tileY: tileY, zoom: zoom, tileSize: tileSize)
                path.addLine(to: point)
            }
            path.closeSubpath()
        }
    }

    private static func project(lon: Double, lat: Double, tileX: Int, tileY: Int, zoom: Int, tileSize: CGSize) -> CGPoint {
        let n = pow(2.0, Double(zoom))
        let x = (lon + 180.0) / 360.0 * n
        let latRad = lat * Double.pi / 180.0
        let y = (1.0 - log(tan(latRad) + 1.0 / cos(latRad)) / Double.pi) / 2.0 * n
        let pixelX = (x - Double(tileX)) * Double(tileSize.width)
        let pixelY = (y - Double(tileY)) * Double(tileSize.height)
        return CGPoint(x: pixelX, y: pixelY)
    }
}
