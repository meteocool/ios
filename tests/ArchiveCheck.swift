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
        edges()
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
        // A step as the volumes, cells and sweeps are asked for it.
        precondition(RadarWindow.at(utc("20261120T1405Z")) == "2026-11-20T14:05:00Z", RadarWindow.at(utc("20261120T1405Z")))
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
        // The frame's tab: the step with its weekday for VoiceOver; on a wide
        // screen the window's day and span, and the step by its clock, dated
        // once past the start's midnight.
        let weekday = RadarWindow.dateTime(utc("20261102T1405Z"), weekday: true, timeZone: zone, locale: locale)
        precondition(weekday == "Mon 2 Nov 14:05", weekday)
        let span = day.span(timeZone: zone, locale: locale)
        precondition(span == "Mon 2 Nov 14:00–17:00", span)
        let nightSpan = night.span(timeZone: zone, locale: locale)
        precondition(nightSpan == "Mon 2 Nov 22:00 – Tue 3 Nov 02:00", nightSpan)
        precondition(day.clock(utc("20261102T1505Z"), timeZone: zone, locale: locale) == "15:05")
        let past = night.clock(utc("20261103T0005Z"), timeZone: zone, locale: locale)
        precondition(past == "Tue 00:05", past)
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

    /// On a phone's strip a clock label gives way to the start's sooner
    /// (core's `windowEdgeClear`).
    static func edges() {
        let day = 1_793_491_200, hour = 3600
        // Three hours from 14:45: "15:00" is the fourth of 37 steps, 9.5% in.
        let window = RadarWindow(start: day + 14 * hour + 45 * 60, end: day + 17 * hour + 45 * 60)!
        func labels(_ clear: Double) -> [Int] {
            TimelinePhysics.axisTicks(steps: window.steps, gridNow: day, every: 60, clear: clear).map(\.step)
        }
        precondition(labels(RadarWindow.edgeClear(width: 1200, dated: false)).contains(day + 15 * hour))
        precondition(!labels(RadarWindow.edgeClear(width: 360, dated: false)).contains(day + 15 * hour))
        precondition(RadarWindow.edgeClear(width: 360, dated: true) > RadarWindow.edgeClear(width: 360, dated: false))
        precondition(RadarWindow.edgeClear(width: 0, dated: false) == RadarWindow.edgeClear(width: 10_000, dated: false))
    }

    static func coverage() {
        let json = #"{"since": 1790000100, "until": 1792678200, "step_seconds": 300, "history_days": 31}"#
        let archive = ArchiveCoverage.decode(Data(json.utf8))!
        precondition(archive == ArchiveCoverage(since: 1_790_000_100, until: 1_792_678_200))
        precondition(ArchiveCoverage.decode(Data(#"{"since": 5, "until": 5, "step_seconds": 300}"#.utf8)) == nil)
        precondition(ArchiveCoverage.decode(Data("nope".utf8)) == nil)
        picker()

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

    /// The picker (core's `archive.test.ts`): the window it opens, the days
    /// and start times it offers, where it starts.
    static func picker() {
        let day = 1_793_491_200, hour = 3600
        let archive = ArchiveCoverage(since: day - 30 * 24 * hour, until: day + 12 * hour)
        // A picked window runs its length from its start.
        precondition(archive.pick(start: day - 6 * hour, hours: 3) == RadarWindow(start: day - 6 * hour, end: day - 3 * hour))
        // A start off the grid is moved back onto it.
        precondition(archive.pick(start: day + 61, hours: 1) == RadarWindow(start: day, end: day + hour))
        // One running past the archive's newest step ends there.
        precondition(archive.pick(start: day + 11 * hour, hours: 6) == RadarWindow(start: day + 11 * hour, end: archive.until))
        // One starting before the oldest step starts there.
        precondition(archive.pick(start: archive.since - hour, hours: 3) == RadarWindow(start: archive.since, end: archive.since + 2 * hour))
        // One with nothing of it kept is none.
        precondition(archive.pick(start: archive.until + hour, hours: 1) == nil)

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        // Every day the archive keeps anything of.
        let days = ArchiveCoverage(since: day - 2 * 86_400 + 600, until: day + 3600).days(calendar: utc)
        precondition(days == [day - 2 * 86_400, day - 86_400, day], "\(days)")
        // A start may be any step of a whole day…
        precondition(archive.startMinutes(day: day - 86_400, calendar: utc) == 0 ... 1435)
        // …cut at the archive's ends on its first and last day.
        let ends = ArchiveCoverage(since: day - 86_400 + 7 * hour + 2 * 60, until: day + 9 * hour + 30 * 60)
        precondition(ends.startMinutes(day: day - 86_400, calendar: utc) == 7 * 60 + 5 ... 1435)
        precondition(ends.startMinutes(day: day, calendar: utc) == 0 ... 9 * 60 + 30)

        // It starts on the last three hours kept, or on the window open now
        // at the first length that holds it.
        let seed = archive.seed(open: nil)
        precondition(seed.start == archive.until - 3 * hour && seed.hours == 3)
        let open = RadarWindow(start: day - 5 * hour, end: day - 3 * hour)!
        precondition(archive.seed(open: open) == (day - 5 * hour, 3))
        precondition(archive.seed(open: RadarWindow(start: day - 13 * hour, end: day - 3 * hour)) == (day - 13 * hour, 12))
        // Never before the oldest step.
        let young = ArchiveCoverage(since: day, until: day + hour)
        precondition(young.seed(open: nil).start == day)
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
