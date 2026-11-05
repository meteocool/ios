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

    /// The switchable overlays of either map, in the order a link lists
    /// them: the radar map's storms, strikes, cyclones, radars' marks and
    /// weather stations, and the 3D map's KONRAD3D tiers.
    static let overlayNames = ["cells", "lightning", "mesocyclones", "sites", "stations", "tiers"]

    /// What a link could name before 2026-10-29, when it listed only the ones on.
    static let firstOverlays = ["cells", "lightning", "mesocyclones"]

    /// The overlays each map has, all of which a link from that map names.
    static let mapOverlays: [String: [String]] = [
        "radar": ["cells", "lightning", "mesocyclones", "sites", "stations"],
        "cells3d": ["tiers"],
    ]

    /// A link's `overlays=` (core's `parseOverlays`): `cells,-stations` is the
    /// storms on and the stations off, and one it does not name is the
    /// reader's own. A list that could have been written before the minus
    /// (only the first three, none off) is the old form: one of those three
    /// it leaves out is off. `none` is the first three off. Nil where absent
    /// or naming nothing this app has (a typo, not "all off").
    static func overlayStates(_ text: String?) -> [String: Bool]? {
        guard let text else { return nil }
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if parts == ["none"] { return Dictionary(uniqueKeysWithValues: firstOverlays.map { ($0, false) }) }
        var named: [String: Bool] = [:]
        for part in parts {
            let off = part.hasPrefix("-")
            let name = off ? String(part.dropFirst()) : part
            if overlayNames.contains(name) { named[name] = !off }
        }
        guard !named.isEmpty else { return nil }
        let old = parts.allSatisfy { !$0.hasPrefix("-") } && named.keys.allSatisfy(firstOverlays.contains)
        var states: [String: Bool] = [:]
        for overlay in overlayNames {
            if let on = named[overlay] { states[overlay] = on } else if old, firstOverlays.contains(overlay) { states[overlay] = false }
        }
        return states
    }

    /// `cells,-stations`: each overlay the states name, in order; nil for none.
    static func overlaysValue(_ states: [String: Bool]) -> String? {
        let named = overlayNames.filter { states[$0] != nil }
        return named.isEmpty ? nil : named.map { states[$0]! ? $0 : "-" + $0 }.joined(separator: ",")
    }

    /// The storm marks the key can put away, in the order a link lists them.
    static let stormMarks = ["dwd", "meteocool", "weak", "moderate", "strong", "extreme",
                             "live", "path", "join", "hail", "rotation", "forecast", "volume"]

    /// `hide=weak,path`, or `none` for nothing put away; a list naming none
    /// the key has is dropped.
    static func hidden(_ text: String?) -> [String]? {
        guard let text else { return nil }
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if parts == ["none"] { return [] }
        let known = stormMarks.filter(parts.contains)
        return known.isEmpty ? nil : known
    }

    static func hiddenValue(_ marks: [String]) -> String {
        let known = stormMarks.filter(marks.contains)
        return known.isEmpty ? "none" : known.joined(separator: ",")
    }

    /// A weather station's id, DWD's `02290`: a plain word, safe in a path.
    static func validStation(_ text: String) -> Bool {
        (1 ... 16).contains(text.count) && text.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
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

    /// A storm core's volume in a link (`cloud`, core's `cloudLink`): its
    /// scan and name, `20260924T194500/de-T100054400355`, for its path
    /// `meteoradar/volumes/<scan>/<name>.mcvx`. Nil for a path laid out
    /// some other way.
    static func cloudLink(_ path: String) -> String? {
        guard let match = path.wholeMatch(of: cloudPathPattern) else { return nil }
        return "\(match.1)/\(match.2)"
    }

    /// The volume's path back from its link form (`cloudPath`).
    static func cloudPath(_ link: String) -> String? {
        guard let match = link.wholeMatch(of: cloudLinkPattern) else { return nil }
        return "meteoradar/volumes/\(match.1)/\(match.2).mcvx"
    }

    /// A tile's name, a position's from before tiles, or the bare one before
    /// networks (`CLOUD_NAME`).
    nonisolated(unsafe) private static let cloudLinkPattern = #/(\d{8}T\d{6})/((?:[a-z]{2}-)?(?:T\d{12}|G\d{10}|R\d{1,12}))/#
    nonisolated(unsafe) private static let cloudPathPattern =
        #/meteoradar/volumes/(\d{8}T\d{6})/((?:[a-z]{2}-)?(?:T\d{12}|G\d{10}|R\d{1,12}))\.mcvx/#

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

/// How long ago a link was shared, when that is long enough to say
/// (core's `lib/shareLink.ts`: 15 minutes, with five of clock skew forgiven).
enum ShareAge {
    static let staleAfter = 900
    static let skew = 300

    /// "2 hours ago"-style text, or nil for a fresh link.
    static func text(sharedAt: Int, now: Int, locale: Locale = .current) -> String? {
        let age = now - sharedAt
        guard age >= staleAfter, age > -skew else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        var components = DateComponents()
        if age < 3600 { components.minute = -(age / 60) } else if age < 48 * 3600 { components.hour = -(age / 3600) } else { components.day = -(age / 86400) }
        return formatter.localizedString(from: components)
    }
}
