//
//  ReverseGeocoder.swift
//  meteocool
//
//  A held point, the user's position or the view's centre, named: core's
//  `lib/reverseGeocode.ts`.
//

import Foundation

/// How much ground a name covers (core's `GeocodeScale`): a point's town, a
/// view's state, or its country.
enum GeocodeScale: String, Sendable {
    case local, regional, country

    /// The scale a map at this zoom is showing (core's `scaleForZoom`).
    static func forZoom(_ zoom: Double) -> GeocodeScale {
        zoom >= 9 ? .local : zoom >= 6 ? .regional : .country
    }

    /// What Nominatim's `zoom` asks for: a settlement, a state, a country.
    var nominatimZoom: Int {
        switch self {
        case .local: return 12
        case .regional: return 8
        case .country: return 3
        }
    }

    /// The fields a name is picked from, first non-empty wins (core's `ORDER`).
    var order: [KeyPath<GeoPlace, String?>] {
        switch self {
        case .local: return [\.city, \.locality, \.principalSubdivision, \.countryName, \.sea]
        case .regional: return [\.principalSubdivision, \.city, \.countryName, \.sea]
        case .country: return [\.countryName, \.principalSubdivision, \.sea]
        }
    }
}

/// Where someone is: the settlement and its district (core's `NearPlace`).
struct NearPlace: Equatable, Sendable {
    let name: String
    /// The suburb or quarter; nil in a village or where there is none.
    let district: String?

    /// The strip's title: "District, Name" when there is room, else "Name".
    func title(withDistrict: Bool) -> String {
        if withDistrict, let district { return "\(district), \(name)" }
        return name
    }
}

/// The fields a name is built from, BigDataCloud's names (core's `Place`).
struct GeoPlace: Equatable, Sendable {
    var city: String?
    var locality: String?
    var principalSubdivision: String?
    var countryName: String?
    var county: String?
    var sea: String?

    /// The first non-empty field for `scale` (core's `pickLabel`).
    func label(_ scale: GeocodeScale) -> String? {
        for path in scale.order {
            if let value = self[keyPath: path]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { return value }
        }
        return nil
    }

    /// The settlement and its district (core's `nearPlace`).
    var near: NearPlace? {
        guard let name = label(.local) else { return nil }
        let district = locality?.trimmingCharacters(in: .whitespacesAndNewlines)
        return NearPlace(name: name, district: district.flatMap { $0.isEmpty || $0 == name ? nil : $0 })
    }

    /// Nominatim's jsonv2 answer (core's `asPlace`); nil for "Unable to geocode".
    static func nominatim(_ data: Data) -> GeoPlace? {
        struct Body: Decodable {
            struct Address: Decodable {
                let city, town, village, municipality, hamlet, suburb, county, state, country: String?
            }
            let address: Address?
        }
        guard let address = (try? JSONDecoder().decode(Body.self, from: data))?.address else { return nil }
        return GeoPlace(city: address.city ?? address.town ?? address.village ?? address.municipality,
                        locality: address.suburb ?? address.hamlet,
                        principalSubdivision: address.state ?? address.county,
                        countryName: address.country,
                        county: address.county)
    }

    /// BigDataCloud's answer (core's `fromBigDataCloudBody`): at sea, the
    /// locality is an economic zone and the sea's own name stands in.
    static func bigDataCloud(_ data: Data) -> GeoPlace? {
        struct Body: Decodable {
            struct Area: Decodable {
                let name: String?
                let description: String?
                let adminLevel: Int?
            }
            struct Info: Decodable {
                let administrative: [Area]?
                let informative: [Area]?
            }
            let city, locality, principalSubdivision, countryName: String?
            let localityInfo: Info?
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else { return nil }
        func blank(_ text: String?) -> Bool { (text ?? "").isEmpty }
        let atSea = blank(body.city) && blank(body.principalSubdivision) && blank(body.countryName)
        return GeoPlace(city: body.city,
                        locality: atSea ? nil : body.locality,
                        principalSubdivision: body.principalSubdivision,
                        countryName: body.countryName,
                        county: body.localityInfo?.administrative?.first { $0.adminLevel == 6 }?.name,
                        sea: atSea ? body.localityInfo?.informative?.first {
                            !blank($0.description) && !($0.name ?? "").contains("/")
                        }?.name : nil)
    }
}

/// Names places: meteocool's own Nominatim first, BigDataCloud where it has
/// no answer (core's `reverseGeocode`, `nearPlace`). Cached by about 100 m,
/// a failure not; a newer lookup on the same channel ("point-menu",
/// "forecast", "compare", "lightning") cancels that channel's older one,
/// which then answers nil. Never throws.
///
/// No app dependencies here: `scripts/check.sh` compiles this file alone.
actor ReverseGeocoder {
    /// meteocool's Nominatim, on the staging cluster the native map reads
    /// from (core's `geocodingUrl`); nil goes straight to BigDataCloud.
    static let shared = ReverseGeocoder(nominatim: URL(string: "https://geocoding-staging.meteocool.com"))
    static let bigDataCloud = URL(string: "https://api.bigdatacloud.net/data/reverse-geocode-client")!
    static let cacheSize = 200

    enum Answer: Equatable, Sendable {
        case label(String)
        case near(NearPlace)
    }

    private let nominatim: URL?
    private let session: URLSession
    /// By key; a nil answer is "nothing here", kept as well.
    private var cache: [String: Answer?] = [:]
    private var order: [String] = []
    private var inFlight: [String: (id: UUID, task: Task<Answer??, Never>)] = [:]

    init(nominatim: URL?, session: URLSession = .shared) {
        self.nominatim = nominatim
        self.session = session
    }

    /// core's cache key: three decimals, about 100 m.
    static func key(latitude: Double, longitude: Double, language: String, kind: String) -> String {
        String(format: "%.3f,%.3f,", latitude, longitude) + "\(language),\(kind)"
    }

    /// Some locales arrive as "de-DE"; the providers take the bare language.
    static func language(_ locale: String) -> String {
        String(locale.prefix(2)).lowercased()
    }

    static func nominatimURL(base: URL, latitude: Double, longitude: Double, language: String, zoom: Int) -> URL? {
        var components = URLComponents(url: base.appendingPathComponent("reverse"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "lat", value: String(latitude)),
            URLQueryItem(name: "lon", value: String(longitude)),
            URLQueryItem(name: "format", value: "jsonv2"),
            URLQueryItem(name: "zoom", value: String(zoom)),
            URLQueryItem(name: "accept-language", value: language),
        ]
        return components?.url
    }

    static func bigDataCloudURL(latitude: Double, longitude: Double, language: String) -> URL? {
        var components = URLComponents(url: bigDataCloud, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "localityLanguage", value: language),
        ]
        return components?.url
    }

    /// The name at a point at `scale`, nil without one.
    func name(latitude: Double, longitude: Double, language: String, scale: GeocodeScale = .local,
              channel: String = "place") async -> String? {
        let answer = await lookUp(latitude: latitude, longitude: longitude, language: language, kind: scale.rawValue,
                                  zoom: scale.nominatimZoom, channel: channel) { place in place.label(scale).map(Answer.label) }
        if case .label(let name) = answer { return name }
        return nil
    }

    /// The settlement and its district at a point (the strip's title).
    func nearPlace(latitude: Double, longitude: Double, language: String, channel: String = "place") async -> NearPlace? {
        let answer = await lookUp(latitude: latitude, longitude: longitude, language: language, kind: "near",
                                  zoom: GeocodeScale.local.nominatimZoom, channel: channel) { place in place.near.map(Answer.near) }
        if case .near(let place) = answer { return place }
        return nil
    }

    private func lookUp(latitude: Double, longitude: Double, language: String, kind: String, zoom: Int, channel: String,
                        read: @escaping @Sendable (GeoPlace) -> Answer?) async -> Answer? {
        let lang = Self.language(language)
        let key = Self.key(latitude: latitude, longitude: longitude, language: lang, kind: kind)
        if let cached = cache[key] { return cached }

        inFlight[channel]?.task.cancel()
        let id = UUID()
        let nominatim = self.nominatim
        let session = self.session
        let task = Task<Answer??, Never> {
            // Ours being down or knowing nothing here sends the lookup on.
            if let nominatim, let url = Self.nominatimURL(base: nominatim, latitude: latitude, longitude: longitude,
                                                          language: lang, zoom: zoom) {
                if let data = await Self.get(url, session: session), let place = GeoPlace.nominatim(data),
                   let answer = read(place) {
                    return .some(answer)
                }
                if Task.isCancelled { return nil }
            }
            guard let url = Self.bigDataCloudURL(latitude: latitude, longitude: longitude, language: lang),
                  let data = await Self.get(url, session: session), !Task.isCancelled else { return nil }
            // Not cached as an answer when the body is not one.
            guard let place = GeoPlace.bigDataCloud(data) else { return nil }
            return .some(read(place))
        }
        inFlight[channel] = (id, task)
        let result = await task.value
        if inFlight[channel]?.id == id { inFlight[channel] = nil }
        guard let result else { return nil }
        // Oldest out first.
        if cache[key] == nil {
            if order.count >= Self.cacheSize { cache[order.removeFirst()] = nil }
            order.append(key)
        }
        cache[key] = .some(result)
        return result
    }

    /// A 2xx body, nil for anything else.
    private static func get(_ url: URL, session: URLSession) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, response) = try? await session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode, (200 ..< 300).contains(status) else { return nil }
        return data
    }
}
