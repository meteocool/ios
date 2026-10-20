//
//  NativeMapEndpoints.swift
//  meteocool
//
//  The hosts the native map reads from.
//

import Foundation

/// Where the native map gets its data: the same hosts core's own build
/// uses (core's `src/urls.ts`).
///
/// The app's other features go through app.meteocool.com, whose Worker
/// forwards their paths. It does not forward tiles, coverage, `/storms` or
/// the socket, so the map talks to the cluster directly, as the web map at
/// app.meteocool.com does: it is core's staging build.
struct NativeMapEndpoints: Equatable, Sendable {
    /// `/v3/radar/timeseries`, `/v3/radar/coverage`, and the socket.
    let api: URL
    /// `/lightning_cache`, `/mesocyclones/all/`, `/storms`.
    let data: URL
    /// The value tiles.
    let tiles: URL

    static func of(_ environment: MeteocoolEnvironment) -> NativeMapEndpoints {
        switch environment {
        case .app, .staging:
            return NativeMapEndpoints(api: URL(string: "https://api-next.meteocool.com/")!,
                                      data: URL(string: "https://data-staging.meteocool.com/")!,
                                      tiles: URL(string: "https://assets-staging.meteocool.com/")!)
        case .demo:
            return NativeMapEndpoints(api: URL(string: "https://api-demo.meteocool.com/")!,
                                      data: URL(string: "https://data-demo.meteocool.com/")!,
                                      tiles: URL(string: "https://assets-demo.meteocool.com/")!)
        }
    }

    /// The radar's steps; with a point, its readings there, from `network`'s
    /// composite where the point is on that network's ground.
    func timeseries(latitude: Double?, longitude: Double?, network: String?, nowcast: Bool) -> URL {
        var components = URLComponents(url: api.appendingPathComponent("v3/radar/timeseries"), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = []
        if let latitude, let longitude {
            items.append(URLQueryItem(name: "lat", value: String(format: "%.4f", latitude)))
            items.append(URLQueryItem(name: "lon", value: String(format: "%.4f", longitude)))
        }
        if let network { items.append(URLQueryItem(name: "network", value: network)) }
        if nowcast { items.append(URLQueryItem(name: "products", value: "nowcast")) }
        components.queryItems = items.isEmpty ? nil : items
        return components.url!
    }

    var coverage: URL { api.appendingPathComponent("v3/radar/coverage") }
    var lightning: URL { data.appendingPathComponent("lightning_cache") }
    var mesocyclones: URL { data.appendingPathComponent("mesocyclones/all/") }

    /// Storms around a box, seen in the last three hours (core's `StormManager`).
    func storms(minLon: Double, minLat: Double, maxLon: Double, maxLat: Double, since: Date) -> URL {
        var components = URLComponents(url: data.appendingPathComponent("storms"), resolvingAgainstBaseURL: false)!
        let iso = ISO8601DateFormatter()
        components.queryItems = [
            URLQueryItem(name: "bbox", value: [minLon, minLat, maxLon, maxLat].map { String(format: "%.3f", $0) }.joined(separator: ",")),
            URLQueryItem(name: "since", value: iso.string(from: since)),
        ]
        return components.url!
    }
}
