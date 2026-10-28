//
//  StormLogRules.swift
//  meteocool
//
//  The storm log's rules: what ng's `/v4/storm-log` answers, how an entry is
//  told (distances, dBZ, echo tops, the time it passed), its severity's colour
//  and its share link on the app's own map host.
//
//  No app dependencies here: `scripts/check.sh` compiles this file alone.
//

import Foundation

/// A phone's storm log: the storms that passed over, or within 10 km of, its
/// registered location or one of its places, newest first. The backend
/// decides every entry; the app only shows them.
struct StormLog: Decodable, Equatable {
    let entries: [StormPassage]
}

/// One storm that passed the phone or one of its places.
struct StormPassage: Decodable, Equatable {
    let id: String
    let storm: String
    let predecessors: [String]
    /// A saved place's id and name; nil for the phone's own location.
    let place: String?
    let placeName: String?
    /// The point it passed.
    let lat: Double
    let lon: Double
    let startedAt: Date
    /// Nil while the storm is still near.
    let endedAt: Date?
    /// Whether the point was ever under the storm's core.
    let over: Bool
    let closestKm: Double
    let closestAt: Date
    let peakDbz: Double?
    /// The highest echo top above sea level, km; only where DWD rated the storm.
    let topKm: Double?
    let vilKgM2: Double?
    /// 0 to 3, coloured as the map colours storms.
    let severity: Int
    let hail: Bool
    let meso: Bool
    /// Lightning within 10 km of the point while the storm was near.
    let strikes: Int
    let track: StormTrack
    let shareUrl: String
}

/// The storm's way past the point: a GeoJSON line with a time per position.
struct StormTrack: Decodable, Equatable {
    let coordinates: [[Double]]
    let times: [Int]
}

enum StormLogRules {
    /// The route, under the API's root (`NetworkHelper.apiURL`).
    static let path = "v4/storm-log"
    /// The push token travels in a header, never in the URL, which proxies log.
    static let tokenHeader = "X-Push-Token"

    /// A request for the log (`GET`) or to wipe it (`DELETE`).
    static func request(api: URL, token: String, method: String) -> URLRequest {
        var request = URLRequest(url: api.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue(token, forHTTPHeaderField: tokenHeader)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// The answer, or nil for one that does not decode. Times are ISO 8601,
    /// with or without fractions of a second, as pydantic writes them.
    static func decode(_ data: Data) -> StormLog? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = date(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a time: \(text)"))
            }
            return date
        }
        return try? decoder.decode(StormLog.self, from: data)
    }

    static func date(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        // pydantic leaves the zone off a naive time; the backend's are UTC.
        return plain.date(from: text + "Z")
    }

    // MARK: Severity

    /// The map's storm colours (core's `layers/cells.ts`, `StormStyle`), weak to extreme.
    static let severityColors: [UInt32] = [0x2F9E44, 0xF0B429, 0xE03131, 0x9C36B5]
    /// core's band names, for `storm.storm_label.<band>` in `Core.strings`.
    static let bands = ["weak", "moderate", "strong", "extreme"]

    static func clamped(_ severity: Int) -> Int { min(max(severity, 0), 3) }
    static func color(_ severity: Int) -> UInt32 { severityColors[clamped(severity)] }
    static func band(_ severity: Int) -> String { bands[clamped(severity)] }

    // MARK: Numbers

    /// A distance as people say it: a decimal under 10 km, whole kilometres
    /// beyond, in the reader's own number format.
    static func kilometres(_ km: Double, locale: Locale = .current) -> String {
        let value = max(0, km)
        let digits = value < 10 ? 1 : 0
        return value.formatted(.number.precision(.fractionLength(digits)).locale(locale)) + " km"
    }

    /// An echo, to the whole dBZ.
    static func dbz(_ value: Double, locale: Locale = .current) -> String {
        value.formatted(.number.precision(.fractionLength(0)).locale(locale)) + " dBZ"
    }

    /// An echo top, km above sea level, to a tenth.
    static func top(_ km: Double, locale: Locale = .current) -> String {
        km.formatted(.number.precision(.fractionLength(1)).locale(locale)) + " km"
    }

    // MARK: Time

    /// When it passed: the day, and the time it came and went, or only came
    /// while it is still near. In the reader's zone and locale.
    static func when(_ passage: StormPassage, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        var day = Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale)
        day.timeZone = timeZone
        var clock = Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)
        clock.timeZone = timeZone
        let start = passage.startedAt.formatted(clock)
        guard let end = passage.endedAt, end > passage.startedAt else {
            return "\(passage.startedAt.formatted(day)), \(start)"
        }
        return "\(passage.startedAt.formatted(day)), \(start)–\(end.formatted(clock))"
    }

    // MARK: Map

    /// The track's positions as (latitude, longitude), any malformed one left out.
    static func trackPoints(_ track: StormTrack) -> [(lat: Double, lon: Double)] {
        track.coordinates.compactMap { position in
            guard position.count >= 2, (-90 ... 90).contains(position[1]), (-180 ... 180).contains(position[0]) else { return nil }
            return (position[1], position[0])
        }
    }

    /// The box the detail map shows: the track and the point, with a margin
    /// of a fifth on every side and at least `minimumDegrees` across.
    static func region(_ passage: StormPassage, minimumDegrees: Double = 0.08)
        -> (centerLat: Double, centerLon: Double, spanLat: Double, spanLon: Double) {
        let points = trackPoints(passage.track) + [(passage.lat, passage.lon)]
        let lats = points.map(\.lat), lons = points.map(\.lon)
        let south = lats.min()!, north = lats.max()!, west = lons.min()!, east = lons.max()!
        return ((south + north) / 2, (west + east) / 2,
                max((north - south) * 1.4, minimumDegrees), max((east - west) * 1.4, minimumDegrees))
    }

    // MARK: Sharing

    /// The entry's share link on the map host the app uses (`MeteocoolEnvironment.mapURL`):
    /// what the backend's link says, on the app's own deployment, so it opens
    /// in the app as a universal link and on the same backend as the map.
    /// Nil when the backend's link has no query to carry over.
    static func shareURL(_ passage: StormPassage, mapURL: URL) -> URL? {
        guard let given = URLComponents(string: passage.shareUrl),
              let query = given.percentEncodedQuery, !query.isEmpty,
              var components = URLComponents(url: mapURL, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/"
        components.percentEncodedQuery = query
        components.fragment = nil
        return components.url
    }
}
