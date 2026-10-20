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

    /// DWD's tile extent, which its layer is cut to (core's `dwdRadarExtent`).
    static let dwdExtent: MKMapRect = {
        let topLeft = MKMapPoint(CLLocationCoordinate2D(latitude: 56.25, longitude: 2.8125))
        let bottomRight = MKMapPoint(CLLocationCoordinate2D(latitude: 45, longitude: 19.6875))
        return MKMapRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
    }()

    static let empty = RadarCoverage(domains: [:])

    init(domains: [String: Domain]) {
        self.domains = domains
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
        self.domains = domains
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
        }
    }
}
