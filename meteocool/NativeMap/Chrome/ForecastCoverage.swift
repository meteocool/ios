//
//  ForecastCoverage.swift
//  meteocool
//
//  Whether anything forecasts the view (core's `lib/forecastCoverage.ts`),
//  and how much of it a stalled network draws (`NowcastPlayback.svelte`).
//

import MapKit

/// The share of the view no forecast reaches: a 12×12 sample, even in
/// Mercator, against DWD's reach and the nowcast runs' ground.
enum ForecastCoverage {
    static let samples = 12

    @MainActor
    static func uncoveredShare(_ visible: MKMapRect, radar: RadarEngine, domains: [String]) -> Double {
        guard let reach = RadarReach.bundled, !visible.isEmpty else { return 0 }
        // ±85°, where Mercator ends.
        let top = MKMapPoint(CLLocationCoordinate2D(latitude: 85, longitude: 0)).y
        let bottom = MKMapPoint(CLLocationCoordinate2D(latitude: -85, longitude: 0)).y
        let minY = max(visible.minY, top), maxY = min(visible.maxY, bottom)
        guard maxY > minY else { return 1 }
        let paths = domains.compactMap { radar.coverage.domains[$0]?.exclusive }
        var uncovered = 0
        for i in 0 ..< samples {
            for j in 0 ..< samples {
                let point = CGPoint(x: visible.minX + visible.width * (Double(i) + 0.5) / Double(samples),
                                    y: minY + (maxY - minY) * (Double(j) + 0.5) / Double(samples))
                // The DWD wash fills where DWD does not reach.
                let dwd = !reach.dwd.contains(point, using: .evenOdd)
                if !dwd, !paths.contains(where: { $0.contains(point, using: .evenOdd) }) { uncovered += 1 }
            }
        }
        return Double(uncovered) / Double(samples * samples)
    }

    /// The share of the view that these networks' own ground takes, by the
    /// same sample: where a network whose radar has stopped draws.
    @MainActor
    static func share(_ visible: MKMapRect, radar: RadarEngine, domains: [String]) -> Double {
        guard !visible.isEmpty, !domains.isEmpty else { return 0 }
        let top = MKMapPoint(CLLocationCoordinate2D(latitude: 85, longitude: 0)).y
        let bottom = MKMapPoint(CLLocationCoordinate2D(latitude: -85, longitude: 0)).y
        let minY = max(visible.minY, top), maxY = min(visible.maxY, bottom)
        guard maxY > minY else { return 0 }
        let grounds = domains.compactMap { radar.coverage.domains[$0] }
        var inside = 0
        for i in 0 ..< samples {
            for j in 0 ..< samples {
                let point = MKMapPoint(x: visible.minX + visible.width * (Double(i) + 0.5) / Double(samples),
                                       y: minY + (maxY - minY) * (Double(j) + 0.5) / Double(samples))
                if grounds.contains(where: { $0.exclusiveBounds.contains(point) && $0.exclusive.contains(CGPoint(x: point.x, y: point.y), using: .evenOdd) }) {
                    inside += 1
                }
            }
        }
        return Double(inside) / Double(samples * samples)
    }
}
