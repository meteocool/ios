import CoreLocation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Where the widgets get their data: the forecast and the radar map at a
/// place, from the API of the deployment the app is set to, each kept in the
/// app group so a widget still has something to show when the network does
/// not answer.
///
/// Unlike a Live Activity, a widget may use the network while its timeline
/// is made. Several widgets showing the same place ask at about the same
/// time; a copy younger than `reuseAfter` answers them all.
enum WidgetStore {
    static let group = "group.org.frcy.app.meteocool"
    static var defaults: UserDefaults? { UserDefaults(suiteName: group) }

    /// The API of the deployment the app is set to. Read afresh each time:
    /// the extension outlives a change of Mode, which reloads the widgets.
    static var apiURL: URL { MeteocoolEnvironment.stored(in: defaults).apiBaseURL }

    /// A copy this young is used without asking again.
    static let reuseAfter: TimeInterval = 90
    /// Whether a copy saved at `saved` is recent enough to use as it is.
    private static func reusable(_ saved: Date) -> Bool {
        let requested = (defaults?.object(forKey: "widgetRefreshRequested") as? Double).map(Date.init(timeIntervalSince1970:))
        return Date().timeIntervalSince(saved) < reuseAfter && saved > requested ?? .distantPast
    }

    /// A forecast this old is not shown at all: it would place rain that has moved on.
    static let forecastExpiry: TimeInterval = 2 * 3600
    /// A map this old is not shown: the radar on it is no longer the weather.
    static let mapExpiry: TimeInterval = 6 * 3600

    private static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("Widgets", isDirectory: true)
    }

    // MARK: - Location

    /// The user's last known location: the widget's own, when the user lets
    /// widgets use it, or the last one the app saved, whichever is newer.
    static func currentLocation() -> CLLocation? {
        var candidates: [CLLocation] = []
        let manager = CLLocationManager()
        if manager.isAuthorizedForWidgetUpdates, let location = manager.location, location.horizontalAccuracy >= 0 {
            candidates.append(location)
        }
        if let defaults, let latitude = defaults.object(forKey: "lat") as? Double,
           let longitude = defaults.object(forKey: "lon") as? Double,
           CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: latitude, longitude: longitude)) {
            // Saved before the app kept the time: as old as can be, but known.
            let saved = (defaults.object(forKey: "locationTime") as? Double).map(Date.init(timeIntervalSince1970:)) ?? .distantPast
            candidates.append(CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                                         altitude: 0, horizontalAccuracy: defaults.double(forKey: "accuracy"),
                                         verticalAccuracy: -1, timestamp: saved))
        }
        return candidates.max { $0.timestamp < $1.timestamp }
    }

    // MARK: - Forecast

    /// The forecast at `location`, with `threshold` as the rain that counts,
    /// and the backend's headlines for it. Kept per threshold, language and
    /// details switch, since the headlines depend on them.
    static func forecast(at location: CLLocation, threshold: Double) async -> (forecast: RainForecast, fetched: Date)? {
        let wording = Wording.current(threshold: threshold)
        let file = directory?.appendingPathComponent(String(format: "forecast-%.3f,%.3f", location.coordinate.latitude,
                                                            location.coordinate.longitude) + "\(wording.key).json")
        var result = cached(file, expiry: forecastExpiry).flatMap { data, saved in
            (try? JSONDecoder().decode(RainForecast.self, from: data)).map { ($0, saved) }
        }
        if !(result.map { reusable($0.1) } ?? false),
           let fetched = await fetchForecast(at: location, wording: wording) {
            result = (fetched, Date())
            if let file, let data = try? JSONEncoder().encode(fetched) { save(data, to: file) }
        }
        guard var forecast = result?.0, let fetched = result?.1 else { return nil }
        forecast.threshold = threshold
        return (forecast, fetched)
    }

    private static func fetchForecast(at location: CLLocation, wording: Wording) async -> RainForecast? {
        var components = URLComponents(url: apiURL.appendingPathComponent("v3/radar/timeseries"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "lat", value: String(format: "%.4f", location.coordinate.latitude)),
            URLQueryItem(name: "lon", value: String(format: "%.4f", location.coordinate.longitude)),
        ] + wording.queryItems
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return RainForecast.fromTimeseries(data, threshold: wording.threshold)
    }

    /// What the backend words a forecast for: the rain that counts, the
    /// language (de or en, as the rain alerts) and the dBZ details switch.
    struct Wording {
        let threshold: Double
        let language: String
        let details: Bool

        static func current(threshold: Double) -> Wording {
            let language = Locale.preferredLanguages.first?.split(separator: "-").first == "de" ? "de" : "en"
            return Wording(threshold: threshold, language: language, details: defaults?.bool(forKey: "withDBZ") ?? false)
        }

        var queryItems: [URLQueryItem] {
            [URLQueryItem(name: "threshold", value: String(format: "%g", threshold)),
             URLQueryItem(name: "lang", value: language),
             URLQueryItem(name: "details", value: details ? "true" : "false")]
        }

        /// Part of the cache file's name.
        var key: String { String(format: "-%g-%@%@", threshold, language, details ? "-dbz" : "") }
    }

    // MARK: - Map

    /// The radar map around `location` from the API's preview images (the image
    /// the rain alerts attach), scaled to `pixels`, the widget's own size,
    /// drawn with the app's basemap and colour map. With Match System on, a
    /// light and a dark map, and the widget shows the one for its appearance.
    static func map(at location: CLLocation, zoom: Double, wide: Bool, pixels: CGSize) async -> MapSnapshot? {
        let card = PreviewCard(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                               zoom: zoom, wide: wide)
        let followsSystem = (defaults?.string(forKey: "baseLayer") ?? "system") == "system"
        guard let light = await map(card, style: MapStyle.stored(dark: false), pixels: pixels) else { return nil }
        let dark = followsSystem ? await map(card, style: MapStyle.stored(dark: true), pixels: pixels) : nil
        return MapSnapshot(image: light.image, darkImage: dark?.image, rendered: light.saved, card: card,
                           location: location.coordinate)
    }

    private static func map(_ card: PreviewCard, style: MapStyle, pixels: CGSize) async -> (image: UIImage, saved: Date)? {
        let file = directory?.appendingPathComponent("map-\(card.key)\(style.key).jpg")
        var image = cached(file, expiry: mapExpiry)
        if !(image.map { reusable($0.saved) } ?? false),
           let data = await fetchMap(card, style: style), let jpeg = downsampled(data, longestSide: card.wide ? 1200 : 1024) {
            if let file { save(jpeg, to: file) }
            image = (jpeg, Date())
        }
        guard let image, let picture = cropped(image.data, to: pixels) else { return nil }
        return (picture, image.saved)
    }

    private static func fetchMap(_ card: PreviewCard, style: MapStyle) async -> Data? {
        var components = URLComponents(url: apiURL.appendingPathComponent("v3/preview/og.png"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "latLonZ", value: String(format: "%.5f,%.5f,%.1f", card.latitude, card.longitude, card.zoom)),
            URLQueryItem(name: "aspectRatio", value: card.wide ? "wide" : "square"),
            URLQueryItem(name: "logo", value: "false"),
        ] + style.queryItems
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        // A cold render takes up to 20 s; past that the last map will do.
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    /// `data` as a JPEG at most `longestSide` pixels long, decoded no larger
    /// than that: a widget extension has about 30 MB in all.
    private static func downsampled(_ data: Data, longestSide: CGFloat) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: longestSide,
                kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    /// The middle of the image, filling `pixels`. WidgetKit refuses to draw
    /// a widget whose images have more pixels than the widget itself.
    private static func cropped(_ data: Data, to pixels: CGSize) -> UIImage? {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0,
              pixels.width > 0, pixels.height > 0 else { return nil }
        let scale = max(pixels.width / image.size.width, pixels.height / image.size.height)
        let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: pixels, format: format).image { _ in
            image.draw(in: CGRect(x: (pixels.width - drawn.width) / 2, y: (pixels.height - drawn.height) / 2,
                                  width: drawn.width, height: drawn.height))
        }
    }

    // MARK: - Files

    private static func cached(_ file: URL?, expiry: TimeInterval) -> (data: Data, saved: Date)? {
        guard let file, let data = try? Data(contentsOf: file),
              let saved = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              Date().timeIntervalSince(saved) < expiry else { return nil }
        return (data, saved)
    }

    private static func save(_ data: Data, to file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        prune()
    }

    /// Drops copies past the longest expiry, so places and zooms the widgets
    /// no longer show do not pile up.
    private static func prune() {
        guard let directory, let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for file in files {
            let saved = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(saved) > mapExpiry { try? FileManager.default.removeItem(at: file) }
        }
    }
}

/// A radar map ready to draw, cropped to the widget.
/// The app's map settings as the preview service takes them. Left out when
/// they are the service's defaults (Light, Classic), so the request is the
/// same as the rain alerts' and shares their cached render.
struct MapStyle: Equatable {
    /// light, dark, osm or cyclosm; never "system", which the widget resolves.
    let baseLayer: String
    let colormap: String

    static func stored(dark: Bool) -> MapStyle {
        let defaults = WidgetStore.defaults
        var baseLayer = defaults?.string(forKey: "baseLayer") ?? "system"
        if baseLayer == "system" { baseLayer = dark ? "dark" : "light" }
        return MapStyle(baseLayer: baseLayer, colormap: defaults?.string(forKey: "radarColorMapping") ?? "classic")
    }

    var queryItems: [URLQueryItem] {
        (baseLayer == "light" ? [] : [URLQueryItem(name: "baseLayer", value: baseLayer)])
            + (colormap == "classic" ? [] : [URLQueryItem(name: "colormap", value: colormap)])
    }

    /// Part of the cached file's name; empty for the defaults.
    var key: String {
        queryItems.isEmpty ? "" : "-\(baseLayer)-\(colormap)"
    }
}

struct MapSnapshot {
    let image: UIImage
    /// The dark basemap's map, when the widget follows the system's appearance.
    var darkImage: UIImage? = nil
    /// When it was rendered, or as near as the widget knows: when it arrived.
    let rendered: Date
    let card: PreviewCard
    /// The place the widget is for, which the card's centre is only near.
    let location: CLLocationCoordinate2D
}
