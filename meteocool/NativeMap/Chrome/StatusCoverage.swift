//
//  StatusCoverage.swift
//  meteocool
//
//  Each domain's ground, as the backend's status is read against it (core's
//  `layers/statusCoverage.ts`).
//

import MapKit

extension RadarCoverage {
    /// Each domain's ground as `StatusRules` asks for it: the ground the map
    /// draws that domain's radar on. A network's is its exclusive coverage,
    /// the shape its layer is cut to; Germany's is DWD's reach (`dwdReach`,
    /// the world with that reach cut out, as `RadarReach.dwd` is) less every
    /// network's, which is where DWD's tiles draw. Without the reach,
    /// Germany's is its tile extent less the networks'.
    func statusCoverage(dwdReach: CGPath?) -> StatusRules.Coverage {
        func point(_ lon: Double, _ lat: Double) -> MKMapPoint {
            MKMapPoint(CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }
        var coverage: StatusRules.Coverage = [:]
        for (code, domain) in domains where code != "de" {
            guard let box = Self.extents[code] else { continue }
            coverage[code] = StatusRules.DomainCoverage(extent: StatusRules.Extent(box.minLon, box.minLat, box.maxLon, box.maxLat)) { lon, lat in
                let p = point(lon, lat)
                return domain.exclusiveBounds.contains(p) && domain.exclusive.contains(CGPoint(x: p.x, y: p.y), using: .evenOdd)
            }
        }
        if let box = Self.extents["de"] {
            coverage["de"] = StatusRules.DomainCoverage(extent: StatusRules.Extent(box.minLon, box.minLat, box.maxLon, box.maxLat)) { lon, lat in
                let p = point(lon, lat)
                let reached = dwdReach.map { !$0.contains(CGPoint(x: p.x, y: p.y), using: .evenOdd) } ?? Self.dwdExtent.contains(p)
                return reached && network(at: p) == nil
            }
        }
        return coverage
    }
}
