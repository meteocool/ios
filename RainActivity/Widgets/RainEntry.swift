import CoreLocation
import MapKit
import UIKit
import WidgetKit

/// One place's rain, as a widget shows it at one moment.
struct PlaceRain: Identifiable {
    let id: String
    /// The place's name; for the user's location, the town it is in.
    let name: String
    let isCurrent: Bool
    let location: CLLocation?
    let forecast: RainForecast?
    /// When the forecast was fetched.
    let fetched: Date?

    var problem: WidgetProblem? {
        if location == nil { return .noLocation }
        guard let forecast, forecast.observed < forecast.dbz.count,
              forecast.dbz.dropFirst(forecast.nowIndex).allSatisfy({ $0?.isFinite == true }) else { return .noData }
        return nil
    }

    func advanced(to date: Date) -> PlaceRain {
        PlaceRain(id: id, name: name, isCurrent: isCurrent, location: location,
                  forecast: forecast.flatMap { date < $0.end ? $0.advanced(to: date) : nil }, fetched: fetched)
    }

    func withoutForecast() -> PlaceRain {
        PlaceRain(id: id, name: name, isCurrent: isCurrent, location: location, forecast: nil, fetched: nil)
    }

    /// The web map at this place, which a tap on the widget opens.
    func link(zoom: Double = 10) -> URL? {
        guard let location else { return nil }
        var components = URLComponents(url: MeteocoolEnvironment.stored(in: WidgetStore.defaults).mapURL,
                                       resolvingAgainstBaseURL: false)
        components?.path = "/"
        components?.queryItems = [URLQueryItem(name: "latLonZ", value: String(
            format: "%.4f,%.4f,%.1f", location.coordinate.latitude, location.coordinate.longitude, zoom))]
        return components?.url
    }
}

enum WidgetProblem {
    /// The user's location is wanted, and neither the widget nor the app has one.
    case noLocation
    /// The API did not answer, and nothing recent enough is kept.
    case noData
}

struct RainEntry: TimelineEntry {
    let date: Date
    /// The places the widget shows, the one it is about first.
    let places: [PlaceRain]
    var map: MapSnapshot?
    var relevance: TimelineEntryRelevance?

    var main: PlaceRain? { places.first }
}

/// Builds the entries all the widgets share.
enum RainTimeline {
    /// The next `count` moments a widget changes at: now, then every
    /// `spacing` seconds on the clock (step edges for 300).
    static func dates(from now: Date, spacing: TimeInterval, count: Int) -> [Date] {
        let first = (floor(now.timeIntervalSince1970 / spacing) + 1) * spacing
        return [now] + (0..<(count - 1)).map { Date(timeIntervalSince1970: first + Double($0) * spacing) }
    }

    static func entries(places: [PlaceRain], map: MapSnapshot?, now: Date = Date(),
                        spacing: TimeInterval = 300, count: Int = 7,
                        environment: MeteocoolEnvironment? = nil) -> [RainEntry] {
        let current = environment == nil || environment == MeteocoolEnvironment.stored(in: WidgetStore.defaults)
        let places = current ? places : places.map { $0.withoutForecast() }
        let map = current ? map : nil
        let ends = places.compactMap { $0.forecast?.end }.filter { $0 > now }
        let dates = dates(from: now, spacing: spacing, count: count).filter { $0 <= (ends.max() ?? now) }
        return Set(dates + ends).sorted().map { date in
            let advanced = places.map { $0.advanced(to: date) }
            return RainEntry(date: date, places: advanced, map: map, relevance: relevance(of: advanced.first?.forecast))
        }
    }

    /// Asks for a new timeline in a quarter of an hour; WidgetKit grants
    /// about that many a day to a widget the user looks at.
    static func policy(now: Date = Date()) -> TimelineReloadPolicy {
        .after(now.addingTimeInterval(15 * 60))
    }

    /// Rain on its way brings the widget to the top of a Smart Stack.
    static func relevance(of forecast: RainForecast?) -> TimelineEntryRelevance? {
        guard let forecast else { return nil }
        switch forecast.phase {
        case .raining: return TimelineEntryRelevance(score: 1)
        case .approaching(let arrival, _):
            let minutes = arrival.timeIntervalSince(forecast.now) / 60
            return TimelineEntryRelevance(score: minutes <= 30 ? 0.9 : 0.5)
        case .dry: return TimelineEntryRelevance(score: 0.05)
        }
    }

    // MARK: - Loading

    /// Each place's location, name and forecast.
    static func load(_ places: [WidgetPlace], threshold: Double,
                     environment: MeteocoolEnvironment = MeteocoolEnvironment.stored(in: WidgetStore.defaults)) async -> [PlaceRain] {
        WidgetPlaceQuery.remember(places)
        let loaded = await withTaskGroup(of: (Int, PlaceRain).self) { group in
            for (index, place) in places.enumerated() {
                group.addTask { (index, await load(place, threshold: threshold, environment: environment)) }
            }
            var loaded: [(Int, PlaceRain)] = []
            for await result in group { loaded.append(result) }
            return loaded.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return environment == MeteocoolEnvironment.stored(in: WidgetStore.defaults)
            ? loaded : loaded.map { $0.withoutForecast() }
    }

    private static func load(_ place: WidgetPlace, threshold: Double, environment: MeteocoolEnvironment) async -> PlaceRain {
        let location = place.coordinate?.location ?? WidgetStore.currentLocation()
        guard let location else {
            return PlaceRain(id: place.id, name: place.name, isCurrent: place.isCurrent, location: nil, forecast: nil, fetched: nil)
        }
        async let forecast = WidgetStore.forecast(at: location, threshold: threshold, environment: environment)
        async let name = place.isCurrent ? townName(at: location) : place.name
        let result = await forecast
        return PlaceRain(id: place.id, name: await name ?? place.name, isCurrent: place.isCurrent,
                         location: location, forecast: result?.forecast, fetched: result?.fetched)
    }

    /// The town the user is in, looked up once per kilometre or so.
    private static func townName(at location: CLLocation) async -> String? {
        let key = String(format: "widgetTown-%.2f,%.2f", location.coordinate.latitude, location.coordinate.longitude)
        if let name = WidgetStore.defaults?.string(forKey: key) { return name }
        var name: String?
        if #available(iOS 26.0, *) {
            if let request = MKReverseGeocodingRequest(location: location),
               let item = try? await request.mapItems.first {
                name = item.addressRepresentations?.cityName ?? item.name
            }
        } else {
            let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first
            name = placemark?.locality ?? placemark?.name
        }
        // Only the last town is kept: the key changes as the user moves.
        if let name, let defaults = WidgetStore.defaults {
            if let old = defaults.string(forKey: "widgetTownKey") { defaults.removeObject(forKey: old) }
            defaults.set(name, forKey: key)
            defaults.set(key, forKey: "widgetTownKey")
        }
        return name
    }

    /// The radar map for the first place.
    static func map(for place: PlaceRain?, zoom: Double, wide: Bool, size: CGSize) async -> MapSnapshot? {
        guard let location = place?.location, size.width > 0, size.height > 0 else { return nil }
        // Bound decoded memory for the light and dark images, including portrait XL.
        let pixels = CGSize(width: (size.width * 2).rounded(), height: (size.height * 2).rounded())
        return await WidgetStore.map(at: location, zoom: zoom, wide: wide, pixels: pixels)
    }

    /// The gallery uses a made-up forecast on a bundled demo radar map,
    /// with an Apple basemap when the app's Native Map setting is on.
    static func sample(places: Int = 1) -> RainEntry {
        let names = [String(localized: "Current Location"), "Munich", "Hamburg", "Berlin", "Cologne", "Vienna"]
        let rain = (0..<max(places, 1)).map { index in
            var forecast = RainForecast.sample()
            if index % 2 == 1 { forecast.dbz = forecast.dbz.map { $0.map { max($0 - 18, 0) } } }
            return PlaceRain(id: "sample-\(index)", name: names[index % names.count], isCurrent: index == 0,
                             location: CLLocation(latitude: 48.0, longitude: 11.85), forecast: forecast, fetched: Date())
        }
        let card = PreviewCard(latitude: 48.0, longitude: 11.85, zoom: 9, wide: false)
        let resource = WidgetStore.defaults?.bool(forKey: "nativeMap") == true ? "SampleNativeRadar" : "SampleRadar"
        let map = Bundle.main.url(forResource: resource, withExtension: "jpg")
            .flatMap { UIImage(contentsOfFile: $0.path) }
            .map { MapSnapshot(image: $0, rendered: Date(), card: card, location: CLLocationCoordinate2D(latitude: 48.0, longitude: 11.85)) }
        return RainEntry(date: Date(), places: rain, map: map, relevance: nil)
    }
}
