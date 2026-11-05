import Foundation

/// Checks the archive on the native map: a past window's steps, labels and
/// ticks, the window a link or the picker opens, how the timeline composes
/// a window's series, which strikes a step draws and asks for, and the
/// window in a link both ways.
@main
struct ArchiveCheck {
    static func utc(_ text: String) -> Int { NativeMapLink.frameTime(text)! }

    static func main() {
        windows()
        labels()
        coverage()
        timeline()
        strikes()
        links()
        print("ArchiveCheck: ok")
    }

    static func windows() {
        // Both ends down onto the five-minute grid.
        let window = RadarWindow(start: utc("20261102T1402Z"), end: utc("20261102T1709Z"))!
        precondition(window.start == utc("20261102T1400Z") && window.end == utc("20261102T1705Z"))
        precondition(window.steps.count == 38 && window.steps.first == window.start && window.steps.last == window.end)
        precondition(window.contains(window.end) && !window.contains(window.end + 1) && !window.contains(window.start - 1))
        precondition(window.clamp(window.start - 3600) == window.start && window.clamp(window.end + 3600) == window.end)
        precondition(window.clamp(utc("20261102T1500Z") + 140) == utc("20261102T1500Z"))
        precondition(window.clamp(utc("20261102T1500Z") + 160) == utc("20261102T1505Z"))
        // One step is no window; nor is one ending before it starts.
        precondition(RadarWindow(start: window.start, end: window.start + 299) == nil)
        precondition(RadarWindow(start: window.end, end: window.start) == nil)
        // At most a thousand steps, as the route serves.
        precondition(RadarWindow(start: 0, end: 999 * 300)?.steps.count == 1000)
        precondition(RadarWindow(start: 0, end: 1000 * 300) == nil)
        // Every length the picker offers fits.
        for hours in RadarWindow.lengths { precondition(RadarWindow(ending: window.end, hours: hours)?.hours == Double(hours)) }
    }

    static func labels() {
        let zone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_GB")
        let day = RadarWindow(start: utc("20261102T1400Z"), end: utc("20261102T1700Z"))!
        // Clock times, 24-hour, without a day inside one day.
        precondition(!day.crossesMidnight(in: zone))
        precondition(day.label(utc("20261102T1405Z"), timeZone: zone, locale: locale) == "14:05",
                     day.label(utc("20261102T1405Z"), timeZone: zone, locale: locale))
        // 24-hour where the locale's clock is not.
        precondition(day.label(utc("20261102T1405Z"), timeZone: zone, locale: Locale(identifier: "en_US")) == "14:05")
        // Over midnight, the day in front.
        let night = RadarWindow(start: utc("20261102T2200Z"), end: utc("20261103T0200Z"))!
        precondition(night.crossesMidnight(in: zone))
        let late = night.label(utc("20261102T2355Z"), timeZone: zone, locale: locale)
        precondition(late.contains("Mon") && late.contains("23:55"), late)
        precondition(night.label(utc("20261103T0005Z"), timeZone: zone, locale: locale).contains("Tue"))
        // Where the reader is decides: three hours east, the same night is one day.
        precondition(!night.crossesMidnight(in: TimeZone(secondsFromGMT: 3 * 3600)!))
        let pill = RadarWindow.dateTime(utc("20261102T1405Z"), timeZone: zone, locale: locale)
        precondition(pill == "2 Nov 14:05", pill)
        precondition(RadarWindow.dateTime(utc("20261102T1405Z"), timeZone: zone, locale: Locale(identifier: "en_US")) == "Nov 2 14:05")
        let summary = day.summary(timeZone: zone, locale: locale)
        precondition(summary.contains("14:00") && summary.contains("17:00"), summary)
        // The strip: ticks spaced for the length, counted from the reader's midnight.
        precondition(day.anchor(timeZone: zone) == utc("20261102T0000Z"))
        let spacing = RadarWindow.lengths.map { RadarWindow(ending: day.end, hours: $0)! }.map { ($0.axisMinutes, $0.rulerMinutes, $0.majorMinutes) }
        precondition(spacing.map(\.0) == [15, 60, 120, 180, 360] && spacing.map(\.1) == [5, 5, 15, 30, 60]
            && spacing.map(\.2) == [30, 30, 60, 60, 180], "\(spacing)")
        // At most a handful of labels whatever the length.
        for hours in RadarWindow.lengths {
            let window = RadarWindow(ending: day.end, hours: hours)!
            let ticks = TimelinePhysics.axisTicks(steps: window.steps, gridNow: window.anchor(timeZone: zone), every: window.axisMinutes)
            precondition(ticks.count >= 2 && ticks.count <= 7, "\(hours) h: \(ticks.count)")
        }
    }

    static func coverage() {
        let json = #"{"since": 1790000100, "until": 1792678200, "step_seconds": 300, "history_days": 31}"#
        let archive = ArchiveCoverage.decode(Data(json.utf8))!
        precondition(archive == ArchiveCoverage(since: 1_790_000_100, until: 1_792_678_200))
        precondition(ArchiveCoverage.decode(Data(#"{"since": 5, "until": 5, "step_seconds": 300}"#.utf8)) == nil)
        precondition(ArchiveCoverage.decode(Data("nope".utf8)) == nil)
        // The picker's window: as asked inside the archive.
        let inside = archive.window(start: archive.since + 86400 + 120, hours: 3)!
        precondition(inside.start == archive.since + 86400 && inside.hours == 3)
        // Running past the newest step, moved back to keep its length.
        let newest = archive.window(start: archive.until - 3600, hours: 6)!
        precondition(newest.end == archive.until && newest.hours == 6)
        // Before the oldest, from the oldest.
        let oldest = archive.window(start: archive.since - 86400, hours: 12)!
        precondition(oldest.start == archive.since && oldest.hours == 12)
        // An archive shorter than the length asked: all of it.
        let short = ArchiveCoverage(since: 1_000_200, until: 1_000_200 + 3600)
        precondition(short.window(start: short.since, hours: 24) == RadarWindow(start: short.since, end: short.until))

        // A link's frame before the live strip opens the two hours up to it.
        let now = archive.until + 60
        let past = archive.until - 5 * 3600
        let opened = RadarWindow.forLink(time: past + 70, now: now, archive: archive)!
        precondition(opened.end == past && opened.start == past - 7200)
        // On the live strip, or with no archive, or outside it: none.
        precondition(RadarWindow.forLink(time: now - 3600, now: now, archive: archive) == nil)
        precondition(RadarWindow.forLink(time: past, now: now, archive: nil) == nil)
        precondition(RadarWindow.forLink(time: archive.since - 600, now: now, archive: archive) == nil)
        // Near the oldest step: cut at it; on it: the two hours after.
        precondition(RadarWindow.forLink(time: archive.since + 1800, now: now, archive: archive)!.start == archive.since)
        let first = RadarWindow.forLink(time: archive.since, now: now, archive: archive)!
        precondition(first.start == archive.since && first.end == archive.since + 7200)
    }

    static func timeline() {
        let end = 1_000_200
        let start = end - 3600
        func frame(_ id: String, _ source: String = "observation") -> String {
            """
            {"processed_time": 1, "upstream_time": null, "tile_id": "\(id)", "source": "\(source)", "filename": "x",
             "dbz": null, "tiles": null, "values": {"tile_id": "v-\(id)", "encoding": "rvp6-u8"}}
            """
        }
        // HX on most steps, one missing; a stray frame before the window and a
        // forecast after it, which a window never draws; Switzerland observed
        // on an earlier step only, France on the last.
        let json = """
        {"frames": {"\(start - 300)": \(frame("before")), "\(start)": \(frame("a")), "\(start + 300)": \(frame("b")),
                    "\(start + 600)": null, "\(end - 300)": \(frame("y")), "\(end)": \(frame("z")),
                    "\(end + 300)": \(frame("wn", "nowcast_phys"))},
         "networks": {"ch": {"\(start + 300)": \(frame("ch1"))}, "fr": {"\(end)": \(frame("fr1"))}},
         "products": {"merged": {"\(start)": \(frame("m0"))}},
         "server_time": \(end + 86400 * 3), "replay": false}
        """
        let series = try! RadarSeries.decode(Data(json.utf8))
        let window = RadarWindow(start: start, end: end)!
        let timeline = RadarTimeline(series: series, clock: end + 86400 * 3, window: window)
        precondition(timeline.window == window && timeline.steps == window.steps && timeline.steps.count == 13)
        // Its end is now; nothing after it; every step playable.
        precondition(timeline.now == end && timeline.gridNow == end && timeline.lastPlayable == end)
        precondition(timeline.steps.allSatisfy { !timeline.isForecast($0) && timeline.isPlayable($0) })
        precondition(timeline.nowcastDomains.isEmpty && timeline.liveScans.isEmpty && timeline.forecastGap == nil)
        func keys(_ step: Int) -> [String] { timeline.layers[step]!.map { "\($0.key):\($0.tileId)" } }
        precondition(keys(start) == ["de:v-a"], "\(keys(start))")
        precondition(keys(start + 300) == ["ch:v-ch1", "de:v-b"])
        // A missing scan plays on the one before it.
        precondition(keys(start + 600) == keys(start + 300))
        // The last step is matched like every other: Switzerland is not
        // carried onto it, France is there, and only France is holed.
        precondition(keys(end) == ["fr:v-fr1", "de:v-z"], "\(keys(end))")
        if case let .dwd(holes) = timeline.layers[end]!.last!.clip { precondition(holes == ["fr"]) } else { preconditionFailure() }
        // A step's label is its clock time.
        let label = timeline.offsetLabel(end, now: "Now", timeZone: TimeZone(identifier: "UTC")!, locale: Locale(identifier: "en_GB"))
        precondition(label == "13:50", label)
        // The same series live puts the newest network frames on its live step.
        let live = RadarTimeline(series: series, clock: end + 120)
        precondition(live.window == nil && live.steps.count == 49 && live.offsetLabel(live.gridNow, now: "Now") == "Now")
        // A product: drawn on the steps that have it, HX on the others; never
        // judged behind in the past.
        let merged = RadarTimeline(series: series, clock: end, product: .merged, window: window)
        precondition(merged.drawn == .merged && !merged.fellBack)
        precondition(merged.layers[start]!.map(\.key) == ["merged"] && merged.layers[end]!.last!.tileId == "v-z")
        // A product the window lacks: HX.
        precondition(RadarTimeline(series: series, clock: end, product: .colmax, window: window).drawn == .hx)
        // Nearest step stays inside.
        precondition(timeline.step(nearest: end + 3600) == end && timeline.step(nearest: start - 3600) == start)
    }

    static func strikes() {
        // Three-hour chunks on a fixed grid: the half hour before 10:10 is one.
        let tenTen = utc("20261102T1010Z")
        let far = tenTen + 86400
        precondition(ArchiveStrikes.chunks(at: tenTen, now: far)
            == [ArchiveStrikes.Chunk(since: utc("20261102T0900Z"), until: utc("20261102T1200Z"))])
        // Across a chunk's start, two; none ending after now.
        let nineTen = utc("20261102T0910Z")
        precondition(ArchiveStrikes.chunks(at: nineTen, now: far) == [
            ArchiveStrikes.Chunk(since: utc("20261102T0600Z"), until: utc("20261102T0900Z")),
            ArchiveStrikes.Chunk(since: utc("20261102T0900Z"), until: utc("20261102T1200Z")),
        ])
        let clipped = ArchiveStrikes.chunks(at: nineTen, now: nineTen + 600)
        precondition(clipped.last == ArchiveStrikes.Chunk(since: utc("20261102T0900Z"), until: nineTen + 600))
        for chunk in ArchiveStrikes.chunks(at: nineTen, now: far) {
            precondition(chunk.until - chunk.since <= ArchiveStrikes.chunkSeconds)
        }
        // Drawn: the half hour up to the step, not after it.
        let ms = { (seconds: Int) in Double(seconds) * 1000 }
        precondition(ArchiveStrikes.shown(ms(tenTen), at: tenTen) && ArchiveStrikes.shown(ms(tenTen - 1799), at: tenTen))
        precondition(!ArchiveStrikes.shown(ms(tenTen - 1800), at: tenTen) && !ArchiveStrikes.shown(ms(tenTen) + 1, at: tenTen))
        // Fading with age, as live: four fifths fresh, never brighter older.
        precondition(abs(StrikeFade.alpha(meanAgeMinutes: 0) - 0.8) < 1e-9 && StrikeFade.alpha(meanAgeMinutes: 8) == StrikeFade.alpha(meanAgeMinutes: 0))
        precondition(StrikeFade.alpha(meanAgeMinutes: 9) < StrikeFade.alpha(meanAgeMinutes: 8))
        precondition(abs(StrikeFade.alpha(meanAgeMinutes: 30) - (1 - 13.0 / 30 * 0.8 - 0.2)) < 1e-9)
        var previous = 1.0
        for minute in stride(from: 0.0, through: 60, by: 0.5) {
            let alpha = StrikeFade.alpha(meanAgeMinutes: minute)
            precondition(alpha <= previous && alpha > 0)
            previous = alpha
        }
    }

    static func links() {
        let search = "?latLonZ=48.10000,11.50000,8.00&from=20261102T1400Z&to=20261102T1700Z&t=20261102T1530Z"
        let link = NativeMapLink(search: search)!
        precondition(link.window == RadarWindow(start: utc("20261102T1400Z"), end: utc("20261102T1700Z")))
        precondition(link.time == utc("20261102T1530Z"))
        // Written back as core writes it.
        precondition(link.search == search, link.search)
        precondition(NativeMapLink(search: link.search) == link)
        precondition(NativeMapLink.windowParameters(link.window!) == ["from": "20261102T1400Z", "to": "20261102T1700Z"])
        // Both ends, in order, or no window; the view and frame still read.
        precondition(NativeMapLink(search: "?latLonZ=48,11,8&from=20261102T1400Z")!.window == nil)
        precondition(NativeMapLink(search: "?latLonZ=48,11,8&from=20261102T1700Z&to=20261102T1400Z")!.window == nil)
        precondition(NativeMapLink(search: "?latLonZ=48,11,8&from=junk&to=20261102T1400Z&t=20261102T1300Z")!.time != nil)
        precondition(NativeMapLink.window(from: "20261102T1400Z", to: "20261102T1700Z") == link.window)
        // A live link has none, and writes none.
        let live = NativeMapLink(latitude: 48, longitude: 11, zoom: 8)
        precondition(live.window == nil && !live.search.contains("from=") && !live.search.contains("to="))
    }
}
