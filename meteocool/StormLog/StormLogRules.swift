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
    /// Roughly where the point it passed was: the centre of the grid cell,
    /// `cellDeg` a side, it fell in. The backend never keeps the point itself.
    let lat: Double
    let lon: Double
    /// That cell's side, degrees of latitude and of longitude; nil where the answer leaves it out.
    var cellDeg: Double? = nil
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

    /// The row's time: the clock alone today, the day earlier this year, the
    /// day and year before that.
    static func shortWhen(_ passage: StormPassage, now: Date = Date(), timeZone: TimeZone = .current,
                          locale: Locale = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = passage.startedAt
        var style: Date.FormatStyle
        if calendar.isDate(start, inSameDayAs: now) {
            style = Date.FormatStyle(date: .omitted, time: .shortened)
        } else if calendar.component(.year, from: start) == calendar.component(.year, from: now) {
            style = Date.FormatStyle().day().month(.abbreviated)
        } else {
            style = Date.FormatStyle(date: .abbreviated, time: .omitted)
        }
        style.timeZone = timeZone
        return start.formatted(style.locale(locale))
    }

    /// How long it stayed near, until now while it still is.
    static func duration(_ passage: StormPassage, now: Date = Date()) -> TimeInterval {
        max(0, (passage.endedAt ?? now).timeIntervalSince(passage.startedAt))
    }

    /// A finished passage's length in hours and minutes; nil for one seen at a
    /// single step or still near.
    static func durationText(_ passage: StormPassage, locale: Locale = .current) -> String? {
        guard passage.endedAt != nil else { return nil }
        let minutes = Int((duration(passage) / 60).rounded())
        guard minutes > 0 else { return nil }
        return Duration.seconds(minutes * 60)
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated).locale(locale))
    }

    // MARK: Sorting

    /// The list's orders, `recent` until the user picks another. Every one
    /// falls back to the newest first. Never the server's order, which the
    /// app does not rely on.
    enum Sort: String, CaseIterable {
        case recent, severity, closest, duration, lightning
    }

    static func sorted(_ passages: [StormPassage], by sort: Sort, now: Date = Date()) -> [StormPassage] {
        passages.sorted { a, b in
            switch sort {
            case .recent:
                // A storm still near comes first, then by the time it came, as the rows show it.
                if (a.endedAt == nil) != (b.endedAt == nil) { return a.endedAt == nil }
            case .severity:
                if clamped(a.severity) != clamped(b.severity) { return clamped(a.severity) > clamped(b.severity) }
                if (a.peakDbz ?? -.infinity) != (b.peakDbz ?? -.infinity) { return (a.peakDbz ?? -.infinity) > (b.peakDbz ?? -.infinity) }
            case .closest:
                let near = { (passage: StormPassage) in passage.over ? -1 : max(0, passage.closestKm) }
                if near(a) != near(b) { return near(a) < near(b) }
            case .duration:
                if duration(a, now: now) != duration(b, now: now) { return duration(a, now: now) > duration(b, now: now) }
            case .lightning:
                if a.strikes != b.strikes { return a.strikes > b.strikes }
            }
            return a.startedAt != b.startedAt ? a.startedAt > b.startedAt : a.id < b.id
        }
    }

    // MARK: Consent

    /// The log is off until the user turns it on (`StormLogOnboarding`): a
    /// Bool in the app group's defaults, which `LocationUpdater` sends along.
    static let enabledKey = "stormLogEnabled"
    /// Set when it is turned on: the log is wiped before it is first shown,
    /// so it holds nothing from before.
    static let wipePendingKey = "stormLogWipePending"
    /// The list's order, a `Sort`'s raw value.
    static let sortKey = "stormLogSort"

    // MARK: Map

    /// The track's positions as (latitude, longitude), any malformed one left out.
    static func trackPoints(_ track: StormTrack) -> [(lat: Double, lon: Double)] {
        track.coordinates.compactMap { position in
            guard position.count >= 2, (-90 ... 90).contains(position[1]), (-180 ... 180).contains(position[0]) else { return nil }
            return (position[1], position[0])
        }
    }

    /// The cell the backend keeps a point on, when an answer does not say: 0.1° a side.
    static let defaultCellDegrees = 0.1
    static let metresPerDegree = 111_195.0

    /// How far from the entry's position its point may have been, metres:
    /// half the cell's diagonal, so a circle this wide holds the whole cell.
    /// The map draws that area, never a pin, as the position is approximate.
    static func approximateRadius(_ passage: StormPassage) -> Double {
        let side = passage.cellDeg.flatMap { $0 > 0 && $0 <= 1 ? $0 : nil } ?? defaultCellDegrees
        let north = side / 2 * metresPerDegree
        let east = north * cos(passage.lat * .pi / 180)
        return (north * north + east * east).squareRoot()
    }

    /// The box the detail map shows: the track and the area round the point,
    /// with a margin of a fifth on every side and at least `minimumDegrees` across.
    static func region(_ passage: StormPassage, minimumDegrees: Double = 0.08)
        -> (centerLat: Double, centerLon: Double, spanLat: Double, spanLon: Double) {
        let radius = approximateRadius(passage)
        let dLat = radius / metresPerDegree
        let dLon = radius / (metresPerDegree * max(cos(passage.lat * .pi / 180), 0.01))
        let area = [(passage.lat - dLat, passage.lon - dLon), (passage.lat + dLat, passage.lon + dLon)]
        let points = trackPoints(passage.track) + area
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
