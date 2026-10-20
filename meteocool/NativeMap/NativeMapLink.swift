//
//  NativeMapLink.swift
//  meteocool
//
//  The parts of core's deep links the native map reads and writes.
//

import Foundation

/// `latLonZ` and `t` from a map link (core's `lib/deepLink.ts`): where the
/// map looks, at OpenLayers' zoom, and which frame it shows.
///
/// No app dependencies here: `scripts/check.sh` compiles this file alone.
struct NativeMapLink: Equatable {
    var latitude: Double
    var longitude: Double
    var zoom: Double
    /// A frame's unix second, nil for the live one.
    var time: Int?

    /// Reads a link's search (`?latLonZ=48.1,11.5,9&t=20260924T1945Z`).
    /// Nil without a usable view.
    init?(search: String) {
        let query = search.hasPrefix("?") ? String(search.dropFirst()) : search
        guard let items = URLComponents(string: "?" + query)?.queryItems,
              let view = items.first(where: { $0.name == "latLonZ" })?.value else { return nil }
        let parts = view.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 3, let lat = parts[0], let lon = parts[1], let zoom = parts[2],
              lat.isFinite, lon.isFinite, zoom.isFinite, abs(lat) <= 85.06, abs(lon) <= 180 else { return nil }
        latitude = lat
        longitude = lon
        self.zoom = min(max(zoom, 3), 20)
        time = items.first(where: { $0.name == "t" })?.value.flatMap(Self.frameTime)
    }

    init(latitude: Double, longitude: Double, zoom: Double, time: Int? = nil) {
        (self.latitude, self.longitude, self.zoom, self.time) = (latitude, longitude, zoom, time)
    }

    /// Every parameter of a link's search, first value of each.
    static func parameters(_ search: String) -> [String: String] {
        let query = search.hasPrefix("?") ? String(search.dropFirst()) : search
        var out: [String: String] = [:]
        for item in URLComponents(string: "?" + query)?.queryItems ?? [] where out[item.name] == nil {
            out[item.name] = item.value ?? ""
        }
        return out
    }

    /// The link's search, spelled as core writes it.
    var search: String {
        var search = "?latLonZ=" + [String(format: "%.5f", latitude), String(format: "%.5f", longitude), String(format: "%.2f", zoom)]
            .joined(separator: ",")
        if let time { search += "&t=" + Self.frameLink(time) }
        return search
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// `20260924T1945Z` to a unix second.
    static func frameTime(_ text: String) -> Int? {
        let chars = Array(text)
        guard chars.count == 14, chars[8] == "T", chars[13] == "Z" else { return nil }
        func number(_ range: Range<Int>) -> Int? { Int(String(chars[range])) }
        guard let year = number(0 ..< 4), let month = number(4 ..< 6), let day = number(6 ..< 8),
              let hour = number(9 ..< 11), let minute = number(11 ..< 13) else { return nil }
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        guard let date = utc.date(from: components) else { return nil }
        let back = utc.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard back.year == year, back.month == month, back.day == day, back.hour == hour, back.minute == minute else { return nil }
        return Int(date.timeIntervalSince1970)
    }

    static func frameLink(_ unixSeconds: Int) -> String {
        let c = utc.dateComponents([.year, .month, .day, .hour, .minute], from: Date(timeIntervalSince1970: TimeInterval(unixSeconds)))
        return String(format: "%04d%02d%02dT%02d%02dZ", c.year!, c.month!, c.day!, c.hour!, c.minute!)
    }
}
