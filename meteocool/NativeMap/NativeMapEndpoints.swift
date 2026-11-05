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
    func timeseries(latitude: Double?, longitude: Double?, network: String?, products: [String] = []) -> URL {
        var components = URLComponents(url: api.appendingPathComponent("v3/radar/timeseries"), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = []
        if let latitude, let longitude {
            items.append(URLQueryItem(name: "lat", value: String(format: "%.4f", latitude)))
            items.append(URLQueryItem(name: "lon", value: String(format: "%.4f", longitude)))
        }
        if let network { items.append(URLQueryItem(name: "network", value: network)) }
        for product in products + ["nowcast"] { items.append(URLQueryItem(name: "products", value: product)) }
        components.queryItems = items.isEmpty ? nil : items
        return components.url!
    }

    /// A past window's steps (`start`, `end`): observed only, so no
    /// nowcast; no point, so no readings.
    func timeseries(window: RadarWindow, network: String?, products: [String] = []) -> URL {
        var components = URLComponents(url: api.appendingPathComponent("v3/radar/timeseries"), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "start", value: String(window.start)), URLQueryItem(name: "end", value: String(window.end))]
        if let network { items.append(URLQueryItem(name: "network", value: network)) }
        for product in products { items.append(URLQueryItem(name: "products", value: product)) }
        components.queryItems = items
        return components.url!
    }

    /// What the archive covers (404 while it keeps nothing).
    var archive: URL { api.appendingPathComponent("v3/archive") }

    /// The strikes from `since` up to `until`, unix seconds, at most three hours apart.
    func strikes(since: Int, until: Int) -> URL {
        query(api.appendingPathComponent("v3/lightning/strikes"), ["since": String(since), "until": String(until)])
    }

    /// The snowfields or the precipitation types measured at or before `at`.
    func snow(at: Int) -> URL { query(snow, ["at": String(at)]) }
    func classification(at: Int?) -> URL {
        let url = api.appendingPathComponent("v3/radar/classification")
        return at.map { query(url, ["at": String($0)]) } ?? url
    }

    private func query(_ url: URL, _ items: [String: String]) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = items.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }

    /// Every radar in a box that has published sweeps lately, or one radar
    /// alone, with each tilt's newest sweeps (site mode). A sweep itself is
    /// fetched from `tiles` by its `path`.
    func sweeps(bbox: String) -> URL { sweeps(["bbox": bbox]) }
    func sweeps(site: String) -> URL { sweeps(["site": site]) }

    private func sweeps(_ query: [String: String]) -> URL {
        var components = URLComponents(url: data.appendingPathComponent("sweeps"), resolvingAgainstBaseURL: false)!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }

    var coverage: URL { api.appendingPathComponent("v3/radar/coverage") }
    var snow: URL { api.appendingPathComponent("v3/radar/snow") }
    var lightning: URL { data.appendingPathComponent("lightning_cache") }
    var mesocyclones: URL { data.appendingPathComponent("mesocyclones/all/") }

    /// Storms around a box, seen in the last three hours (core's `StormManager`);
    /// with `until`, every storm that overlapped a past window.
    func storms(minLon: Double, minLat: Double, maxLon: Double, maxLat: Double, since: Date, until: Date? = nil) -> URL {
        var components = URLComponents(url: data.appendingPathComponent("storms"), resolvingAgainstBaseURL: false)!
        let iso = ISO8601DateFormatter()
        components.queryItems = [
            URLQueryItem(name: "bbox", value: [minLon, minLat, maxLon, maxLat].map { String(format: "%.3f", $0) }.joined(separator: ",")),
            URLQueryItem(name: "since", value: iso.string(from: since)),
        ] + (until.map { [URLQueryItem(name: "until", value: iso.string(from: $0))] } ?? [])
        return components.url!
    }
}
