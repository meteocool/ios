import AppIntents
import CoreLocation
import MapKit

/// A place a widget shows: the user's location, or one picked by name in the
/// widget's settings.
///
/// A picked place carries its coordinates and name in its identifier, so
/// nothing has to be stored for the widget to find it again; the last few
/// are remembered only to be suggested first.
struct WidgetPlace: AppEntity, Hashable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Place"
    static let defaultQuery = WidgetPlaceQuery()

    let id: String
    let name: String
    /// Where the place is, to tell places of one name apart: "Bavaria, Germany".
    let region: String?
    /// Nil for the user's location.
    let coordinate: Coordinate?

    struct Coordinate: Hashable {
        let latitude: Double
        let longitude: Double

        var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
    }

    static let current = WidgetPlace(id: "current", name: String(localized: "Current Location"), region: nil, coordinate: nil)

    /// Separates the name from the region in an identifier.
    private static let separator: Character = "\u{1F}"

    var isCurrent: Bool { coordinate == nil }

    init(id: String, name: String, region: String?, coordinate: Coordinate?) {
        self.id = id
        self.name = name
        self.region = region
        self.coordinate = coordinate
    }

    init(name: String, region: String?, latitude: Double, longitude: Double) {
        // Four decimals are about 10 m, far finer than a radar pixel.
        let label = region.map { name + String(Self.separator) + $0 } ?? name
        self.init(id: String(format: "place:%.4f,%.4f:", latitude, longitude) + label,
                  name: name, region: region, coordinate: Coordinate(latitude: latitude, longitude: longitude))
    }

    /// The place an identifier names, or nil if it names none.
    init?(id: String) {
        if id == Self.current.id {
            self = .current
            return
        }
        let parts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "place" else { return nil }
        let numbers = parts[1].split(separator: ",").compactMap { Double($0) }
        guard numbers.count == 2, (-90...90).contains(numbers[0]), (-180...180).contains(numbers[1]) else { return nil }
        let label = parts[2].split(separator: Self.separator, maxSplits: 1).map(String.init)
        self.init(id: id, name: label.first ?? "", region: label.count > 1 ? label[1] : nil,
                  coordinate: Coordinate(latitude: numbers[0], longitude: numbers[1]))
    }

    var displayRepresentation: DisplayRepresentation {
        if isCurrent {
            return DisplayRepresentation(title: "Current Location", image: .init(systemName: "location.fill"))
        }
        return DisplayRepresentation(title: "\(name)", subtitle: region.map { "\($0)" },
                                     image: .init(systemName: "mappin.and.ellipse"))
    }
}

/// Finds places by name with MapKit's search, and offers the user's location
/// and the places picked before.
struct WidgetPlaceQuery: EntityStringQuery {
    /// How many picked places are suggested.
    static let recentCount = 8

    func entities(for identifiers: [WidgetPlace.ID]) async throws -> [WidgetPlace] {
        identifiers.compactMap(WidgetPlace.init(id:))
    }

    func suggestedEntities() async throws -> [WidgetPlace] {
        [.current] + Self.recent
    }

    func defaultResult() async -> WidgetPlace? {
        .current
    }

    func entities(matching string: String) async throws -> [WidgetPlace] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return try await suggestedEntities() }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.address, .pointOfInterest]
        guard let response = try? await MKLocalSearch(request: request).start() else { return [] }
        let places = response.mapItems.compactMap { item -> WidgetPlace? in
            let coordinate = Self.coordinate(of: item)
            guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
            return WidgetPlace(name: item.name ?? query, region: Self.region(of: item),
                               latitude: coordinate.latitude, longitude: coordinate.longitude)
        }
        var seen = Set<String>()
        return places.filter { seen.insert($0.name + ($0.region ?? "")).inserted }
    }

    private static func coordinate(of item: MKMapItem) -> CLLocationCoordinate2D {
        if #available(iOS 26.0, *) {
            return item.location.coordinate
        }
        return item.placemark.coordinate
    }

    /// The town, state and country around a result, without its own name.
    private static func region(of item: MKMapItem) -> String? {
        let parts: [String?]
        if #available(iOS 26.0, *) {
            parts = [item.addressRepresentations?.cityWithContext]
        } else {
            parts = [item.placemark.locality, item.placemark.administrativeArea, item.placemark.country]
        }
        let region = parts.compactMap { $0 }.filter { !$0.isEmpty && $0 != item.name }
        return region.isEmpty ? nil : region.joined(separator: ", ")
    }

    /// The places picked before, newest first.
    static var recent: [WidgetPlace] {
        (WidgetStore.defaults?.stringArray(forKey: "widgetRecentPlaces") ?? []).compactMap(WidgetPlace.init(id:))
    }

    /// Remembers `places` as the newest picks.
    static func remember(_ places: [WidgetPlace]) {
        let picked = places.filter { !$0.isCurrent }.map(\.id)
        guard !picked.isEmpty else { return }
        let old = WidgetStore.defaults?.stringArray(forKey: "widgetRecentPlaces") ?? []
        let ids = picked + old.filter { !picked.contains($0) }
        WidgetStore.defaults?.set(Array(ids.prefix(recentCount)), forKey: "widgetRecentPlaces")
    }
}
