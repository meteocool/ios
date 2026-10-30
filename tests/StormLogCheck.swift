import Foundation

// Checks StormLogRules: decoding ng's /v4/storm-log, the request, the numbers,
// the severity colours, the share link and the list's orders; and that every
// language has the storm log's strings. Compiled with StormLogRules.swift alone.

@inline(__always) func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition {
        FileHandle.standardError.write("StormLogCheck line \(line): \(message)\n".data(using: .utf8)!)
        exit(1)
    }
}

@main
enum StormLogCheck {
    static func main() {
        let answer = """
        {"entries": [
          {"id": "t/-/S2/20261028T142000Z", "storm": "01JBX7Q6ZK4V9T3M2N8P5R0W1C", "predecessors": ["01JBX7Q6ZK4V9T3M2N8P5R0W1D"],
           "place": null, "place_name": null, "lat": 48.15, "lon": 11.55, "cell_deg": 0.1,
           "started_at": "2026-10-28T14:20:00Z", "ended_at": "2026-10-28T14:55:00Z", "over": true, "closest_km": 0.0,
           "closest_at": "2026-10-28T14:35:00Z", "peak_dbz": 58.5, "top_km": 11.25, "vil_kg_m2": 31.0, "severity": 2,
           "hail": true, "meso": false, "strikes": 14,
           "track": {"type": "LineString", "coordinates": [[11.4, 48.1], [11.5, 48.12], [11.6, 48.14]], "times": [1793197200, 1793197500, 1793197800]},
           "share_url": "https://meteocool.com/?layer=radar&latLonZ=48.12000,11.50000,9.00&overlays=cells,lightning&t=20261028T1435Z&shared=20261028T1435Z"},
          {"id": "t/cabin/S1/20261027T100000Z", "storm": "S1", "predecessors": [], "place": "cabin", "place_name": "Cabin",
           "lat": 47.65, "lon": 12.05, "started_at": "2026-10-27T10:00:00.123456Z", "ended_at": null, "over": false,
           "closest_km": 6.42, "closest_at": "2026-10-27T10:05:00Z", "peak_dbz": null, "top_km": null, "vil_kg_m2": null,
           "severity": 0, "hail": false, "meso": false, "strikes": 0,
           "track": {"type": "LineString", "coordinates": [[12.1, 47.6], [12.1, 47.6]], "times": [1793095200, 1793095200]},
           "share_url": "https://meteocool.com/?layer=radar&latLonZ=47.60000,12.10000,9.00&overlays=cells,lightning&t=20261027T1005Z&shared=20261027T1005Z"}
        ]}
        """

        guard let log = StormLogRules.decode(answer.data(using: .utf8)!) else {
            check(false, "the backend's answer decodes")
            return
        }
        check(log.entries.count == 2, "both entries")
        let first = log.entries[0], second = log.entries[1]
        check(first.place == nil && second.placeName == "Cabin", "places")
        check(first.peakDbz == 58.5 && first.topKm == 11.25 && first.vilKgM2 == 31.0, "readings")
        check(first.endedAt != nil && second.endedAt == nil, "an open entry has no end")
        check(second.startedAt.timeIntervalSince1970.rounded() == 1793095200, "fractional seconds decode")
        check(StormLogRules.decode(Data("{\"entries\": [{\"id\": 1}]}".utf8)) == nil, "a malformed answer is nil, not a crash")
        check(StormLogRules.decode(Data("{\"entries\": []}".utf8))?.entries.isEmpty == true, "an empty log")

        // The request carries the token in a header, never in the URL.
        let token = String(repeating: "a", count: 64)
        let request = StormLogRules.request(api: URL(string: "https://app.meteocool.com/")!, token: token, method: "DELETE")
        check(request.url?.absoluteString == "https://app.meteocool.com/v4/storm-log", "the route")
        check(request.httpMethod == "DELETE", "the method")
        check(request.value(forHTTPHeaderField: "X-Push-Token") == token, "the token header")
        check(!(request.url?.absoluteString.contains(token) ?? true), "no token in the URL")

        // Severity: the map's colours and core's bands, clamped.
        check(StormLogRules.color(2) == 0xE03131 && StormLogRules.color(9) == 0x9C36B5 && StormLogRules.color(-1) == 0x2F9E44, "colours")
        check(StormLogRules.band(1) == "moderate" && StormLogRules.band(7) == "extreme", "bands")

        // Numbers in the reader's format.
        let english = Locale(identifier: "en_GB"), german = Locale(identifier: "de_DE")
        check(StormLogRules.kilometres(6.42, locale: english) == "6.4 km", "a near distance: \(StormLogRules.kilometres(6.42, locale: english))")
        check(StormLogRules.kilometres(6.42, locale: german) == "6,4 km", "German decimals")
        check(StormLogRules.kilometres(12.6, locale: english) == "13 km", "whole kilometres beyond 10")
        check(StormLogRules.kilometres(-1, locale: english) == "0.0 km", "never negative")
        check(StormLogRules.dbz(58.5, locale: english) == "58 dBZ" || StormLogRules.dbz(58.5, locale: english) == "59 dBZ", "dBZ")
        check(StormLogRules.top(11.25, locale: german) == "11,2 km" || StormLogRules.top(11.25, locale: german) == "11,3 km", "echo top")

        // When: the day and both times, or the start alone while it is near.
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        let passed = StormLogRules.when(first, timeZone: berlin, locale: english)
        check(passed.contains("15:20") && passed.contains("15:55") && passed.contains("–"), "a passage: \(passed)")
        let ongoing = StormLogRules.when(second, timeZone: berlin, locale: english)
        check(ongoing.contains("11:00") && !ongoing.contains("–"), "an ongoing one: \(ongoing)")

        // The point is a coarse cell's centre, drawn as a circle that holds the whole cell.
        check(first.lat == 48.15 && first.cellDeg == 0.1 && second.cellDeg == nil, "the cell")
        let radius = StormLogRules.approximateRadius(first)
        check(abs(radius - 6_700) < 150, "half the cell's diagonal at 48° N: \(radius)")
        check(StormLogRules.approximateRadius(second) > 6_000, "an answer without the cell's size falls back to 0.1°")

        // The map: positions as latitude first, and a box round the track and the point's area.
        let points = StormLogRules.trackPoints(first.track)
        check(points.count == 3 && points[0].lat == 48.1 && points[0].lon == 11.4, "track points")
        check(StormLogRules.trackPoints(StormTrack(coordinates: [[1], [200, 1], [11, 48]], times: [0, 0, 0])).count == 1, "malformed positions dropped")
        let box = StormLogRules.region(second)
        check(box.spanLat >= 0.08 && box.spanLon >= 0.08, "a box at least the minimum across")
        let areaLat = StormLogRules.approximateRadius(second) / StormLogRules.metresPerDegree, areaLon = areaLat / cos(47.65 * .pi / 180)
        check(box.centerLat - box.spanLat / 2 <= 47.65 - areaLat && box.centerLat + box.spanLat / 2 >= 47.65 + areaLat
              && box.centerLon - box.spanLon / 2 <= 12.05 - areaLon && box.centerLon + box.spanLon / 2 >= 12.05 + areaLon,
              "the box holds the point's whole area")
        let wide = StormLogRules.region(first)
        // The track runs 11.4 to 11.6 east; the area round 11.55 reaches past its eastern end.
        let areaEast = 11.55 + radius / (StormLogRules.metresPerDegree * cos(48.15 * .pi / 180))
        check(areaEast > 11.6 && abs(wide.centerLon - (11.4 + areaEast) / 2) < 1e-9
              && abs(wide.spanLon - (areaEast - 11.4) * 1.4) < 1e-9, "a box round the track and the area: \(wide)")

        // The share link: the backend's query, on the app's own map host.
        let shared = StormLogRules.shareURL(first, mapURL: URL(string: "https://app.meteocool.com")!)
        check(shared?.absoluteString == "https://app.meteocool.com/?layer=radar&latLonZ=48.12000,11.50000,9.00&overlays=cells,lightning&t=20261028T1435Z&shared=20261028T1435Z",
              "the share link: \(shared?.absoluteString ?? "nil")")
        let bare = StormPassage(id: "x", storm: "x", predecessors: [], place: nil, placeName: nil, lat: 0, lon: 0,
                                startedAt: Date(), endedAt: nil, over: false, closestKm: 1, closestAt: Date(), peakDbz: nil,
                                topKm: nil, vilKgM2: nil, severity: 0, hail: false, meso: false, strikes: 0,
                                track: StormTrack(coordinates: [], times: []), shareUrl: "https://meteocool.com/")
        check(StormLogRules.shareURL(bare, mapURL: URL(string: "https://app.meteocool.com")!) == nil, "a link without a view is no link")

        // How long it stayed near: a finished one in hours and minutes, none while it is near.
        check(StormLogRules.duration(first) == 35 * 60, "35 minutes near")
        check(StormLogRules.duration(second, now: second.startedAt.addingTimeInterval(600)) == 600, "an open one runs until now")
        let length = StormLogRules.durationText(first, locale: english)
        check(length?.contains("35") == true && length?.contains("min") == true, "a passage's length: \(length ?? "nil")")
        check(StormLogRules.durationText(second, locale: english) == nil, "no length while it is near")

        // The row's time: the clock today, the day this year, the year before.
        let sameDay = StormLogRules.shortWhen(first, now: first.startedAt.addingTimeInterval(3600), timeZone: berlin, locale: english)
        check(sameDay == "15:20", "today, the clock: \(sameDay)")
        let thisYear = StormLogRules.shortWhen(first, now: first.startedAt.addingTimeInterval(5 * 86400), timeZone: berlin, locale: english)
        check(thisYear.contains("28") && thisYear.contains("Oct") && !thisYear.contains("2026"), "this year, the day: \(thisYear)")
        let lastYear = StormLogRules.shortWhen(first, now: first.startedAt.addingTimeInterval(100 * 86400), timeZone: berlin, locale: english)
        check(lastYear.contains("2026"), "another year names it: \(lastYear)")

        // Sorting: each order, ties and the rest newest first.
        func passage(_ id: String, start: TimeInterval, minutes: Double?, severity: Int, peak: Double?, over: Bool = false,
                     km: Double, strikes: Int) -> StormPassage {
            let started = Date(timeIntervalSince1970: 1_793_000_000 + start)
            return StormPassage(id: id, storm: id, predecessors: [], place: nil, placeName: nil, lat: 48, lon: 11,
                                startedAt: started, endedAt: minutes.map { started.addingTimeInterval($0 * 60) }, over: over,
                                closestKm: km, closestAt: started, peakDbz: peak, topKm: nil, vilKgM2: nil, severity: severity,
                                hail: false, meso: false, strikes: strikes, track: StormTrack(coordinates: [], times: []),
                                shareUrl: "https://meteocool.com/")
        }
        let log3 = [
            passage("old-strong", start: 0, minutes: 90, severity: 2, peak: 55, km: 4, strikes: 3),
            passage("new-weak", start: 7200, minutes: 10, severity: 0, peak: nil, over: true, km: 0, strikes: 0),
            passage("mid-strong", start: 3600, minutes: 20, severity: 2, peak: 61, km: 8, strikes: 40),
            passage("near", start: 5400, minutes: nil, severity: 1, peak: 50, km: 0.5, strikes: 3),
        ]
        let now = Date(timeIntervalSince1970: 1_793_000_000 + 9000)
        let order = { (sort: StormLogRules.Sort) in StormLogRules.sorted(log3, by: sort, now: now).map(\.id) }
        check(order(.recent) == ["near", "new-weak", "mid-strong", "old-strong"], "still near first, then newest: \(order(.recent))")
        check(StormLogRules.sorted(log3.reversed(), by: .recent, now: now).map(\.id) == order(.recent), "whatever order the server sends")
        check(order(.severity) == ["mid-strong", "old-strong", "near", "new-weak"], "strongest first, then the higher echo: \(order(.severity))")
        check(order(.closest) == ["new-weak", "near", "old-strong", "mid-strong"], "overhead, then nearest: \(order(.closest))")
        // The open one has been near for an hour by now.
        check(order(.duration) == ["old-strong", "near", "mid-strong", "new-weak"], "longest first: \(order(.duration))")
        check(order(.lightning) == ["mid-strong", "near", "old-strong", "new-weak"], "most strikes, ties newest first: \(order(.lightning))")
        check(StormLogRules.Sort(rawValue: "severity") == .severity && StormLogRules.Sort(rawValue: "bogus") == nil, "a stored order")

        // Every language words the whole storm log, its opt-in page included.
        // Run from the repository's root, as scripts/check.sh does.
        let words = NSDictionary(contentsOfFile: "meteocool/en.lproj/Localizable.strings") as? [String: String] ?? [:]
        let keys = words.keys.filter { $0.hasPrefix("storm_log_") }
        check(keys.count > 40 && keys.contains("storm_log_onboarding_server_text"), "English has the storm log's strings")
        for language in ["de", "da", "et", "fi", "hr", "lt", "nb", "nl", "sv"] {
            let strings = NSDictionary(contentsOfFile: "meteocool/\(language).lproj/Localizable.strings") as? [String: String] ?? [:]
            let missing = keys.filter { strings[$0] == nil }.sorted()
            check(missing.isEmpty, "\(language) lacks \(missing)")
            for key in keys {
                let placeholders = { (text: String) in text.filter { $0 == "%" }.count }
                check(placeholders(strings[key]!) == placeholders(words[key]!), "\(language)'s \(key) keeps its placeholders")
            }
        }

        print("StormLogCheck passed")
    }
}
