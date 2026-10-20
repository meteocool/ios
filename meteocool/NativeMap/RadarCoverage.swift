//
//  RadarCoverage.swift
//  meteocool
//
//  Where each radar network is the one drawn: core's `spec/coverage.json`.
//

import Foundation
import MapKit

/// Each network's ground as paths in map points, ready to clip a layer to.
///
/// `exclusive` is where a network's own composite is drawn; `dwdHole` is
/// what DWD's composite gives up to it. Rings are EPSG:3857 metres in the
/// document, the same projection as MapKit's map points up to scale.
struct RadarCoverage: @unchecked Sendable {
    struct Domain {
        let exclusive: CGPath
        let exclusiveBounds: MKMapRect
        let dwdHole: CGPath
    }

    let domains: [String: Domain]
    /// Every network's ground in one path (core's `AROUND_DMAX`).
    let allNetworks: CGPath
    let allNetworksBounds: MKMapRect

    /// Each network's grid as lon/lat boxes (core's `layers/extents.ts`):
    /// where the "no radar here" notice looks, and what a product of every
    /// network covers.
    static let extents: [String: (minLon: Double, minLat: Double, maxLon: Double, maxLat: Double)] = [
        "de": (2.8125, 45, 19.6875, 56.25), "ch": (2.8, 43.7, 13.1, 49.6), "fr": (-8.1, 39.6, 12.7, 52.5),
        "cz": (10.1, 47.1, 20.5, 52.1), "pl": (12.0, 47.8, 25.6, 56.8), "be": (-0.6, 47.6, 9.1, 53.5),
        "sk": (13.8, 46.0, 24.3, 51.5), "lt": (18.2, 52.3, 29.1, 57.9), "ee": (20.1, 56.2, 29.9, 61.7),
        "ie": (-12.7, 50.4, -2.4, 55.7), "hr": (10.9, 40.6, 21.9, 48.2), "dk": (4.8, 52.9, 18.7, 59.7),
        "nl": (1.0, 49.5, 8.8, 55.3), "fi": (17.0, 57.8, 34.7, 70.8), "se": (8.8, 54.0, 27.2, 70.0),
        "no": (0.4, 56.2, 35.5, 72.8),
    ]

    static func mapRect(minLon: Double, minLat: Double, maxLon: Double, maxLat: Double) -> MKMapRect {
        let topLeft = MKMapPoint(CLLocationCoordinate2D(latitude: maxLat, longitude: minLon))
        let bottomRight = MKMapPoint(CLLocationCoordinate2D(latitude: minLat, longitude: maxLon))
        return MKMapRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
    }

    /// The extent of every network's grid (core's `EUROPE.extent`).
    static let wholeExtent: MKMapRect = extents.values.reduce(MKMapRect.null) {
        $0.union(mapRect(minLon: $1.minLon, minLat: $1.minLat, maxLon: $1.maxLon, maxLat: $1.maxLat))
    }

    /// Whether `rect` touches any network's grid (core's `overlaps`): the
    /// "no radar here" notice shows only when it touches none.
    static func touchesRadar(_ rect: MKMapRect) -> Bool {
        extents.values.contains { rect.intersects(mapRect(minLon: $0.minLon, minLat: $0.minLat, maxLon: $0.maxLon, maxLat: $0.maxLat)) }
    }

    /// DWD's tile extent, which its layer is cut to (core's `dwdRadarExtent`).
    static let dwdExtent: MKMapRect = {
        let topLeft = MKMapPoint(CLLocationCoordinate2D(latitude: 56.25, longitude: 2.8125))
        let bottomRight = MKMapPoint(CLLocationCoordinate2D(latitude: 45, longitude: 19.6875))
        return MKMapRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
    }()

    static let empty = RadarCoverage(domains: [:])

    init(domains: [String: Domain]) {
        self.domains = domains
        let all = CGMutablePath()
        for code in RadarTimeline.networks { if let domain = domains[code] { all.addPath(domain.exclusive) } }
        allNetworks = all
        allNetworksBounds = Self.mapRect(all.boundingBoxOfPath)
    }

    /// Reads the document (`GET /v3/radar/coverage`, or the copy in the app).
    init?(json: Data) {
        struct Document: Decodable {
            struct Domain: Decodable {
                let exclusive: [[[Double]]]
                let dwdHole: [[[Double]]]?
            }
            let crs: String
            let domains: [String: Domain]
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let document = try? decoder.decode(Document.self, from: json), document.crs == "EPSG:3857" else { return nil }
        var domains: [String: Domain] = [:]
        for (code, domain) in document.domains {
            let exclusive = Self.path(domain.exclusive)
            domains[code] = Domain(exclusive: exclusive, exclusiveBounds: Self.mapRect(exclusive.boundingBoxOfPath),
                                   dwdHole: Self.path(domain.dwdHole ?? []))
        }
        self.init(domains: domains)
    }

    /// The copy of core's `spec/coverage.json` built into the app, for before
    /// the API has answered.
    static func bundled() -> RadarCoverage {
        guard let url = Bundle.main.url(forResource: "radar-coverage", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return .empty }
        return RadarCoverage(json: data) ?? .empty
    }

    /// Half the Web Mercator world's width, in metres.
    private static let halfWorld = 20037508.342789244

    private static func path(_ rings: [[[Double]]]) -> CGPath {
        let path = CGMutablePath()
        let scale = MKMapSize.world.width / (2 * halfWorld)
        for ring in rings where ring.count > 2 {
            let points = ring.compactMap { pair -> CGPoint? in
                guard pair.count >= 2 else { return nil }
                return CGPoint(x: (pair[0] + halfWorld) * scale, y: (halfWorld - pair[1]) * scale)
            }
            path.addLines(between: points)
            path.closeSubpath()
        }
        return path
    }

    private static func mapRect(_ rect: CGRect) -> MKMapRect {
        rect.isNull ? .null : MKMapRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    /// The network whose own ground `point` is on (core's `networkAt`), nil
    /// on DWD's or nobody's.
    func network(at point: MKMapPoint) -> String? {
        let p = CGPoint(x: point.x, y: point.y)
        return RadarTimeline.networks.first { code in
            guard let domain = domains[code], domain.exclusiveBounds.contains(point) else { return false }
            return domain.exclusive.contains(p, using: .evenOdd)
        }
    }

    /// Where a layer may draw at all, to skip tiles it would cut away.
    func bounds(of clip: RadarClip) -> MKMapRect {
        switch clip {
        case .dwd: return Self.dwdExtent
        case .exclusive(let code): return domains[code]?.exclusiveBounds ?? .null
        case .allNetworks: return allNetworksBounds
        case .whole: return Self.wholeExtent
        }
    }
}
