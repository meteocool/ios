//
//  RadarWindow.swift
//  meteocool
//
//  A past window on the native map: the archive (ng's `doc/archive.md`,
//  core's `lib/archive.ts`).
//

import Foundation

/// A window of the past the map is used in as it is live: its steps from
/// `start` to `end`, both on the five-minute grid, at most 1,000 of them
/// (`/v3/radar/timeseries?start=&end=`). Its end stands where "now" stands
/// live; there is no forecast after it.
///
/// No app dependencies here: `scripts/check.sh` compiles this file alone.
struct RadarWindow: Equatable, Hashable, Sendable {
    static let stepSeconds = 300
    /// The most steps the timeline route serves at once.
    static let maxSteps = 1000
    /// The lengths the picker offers, in hours (`WINDOW_HOURS`).
    static let lengths = [1, 3, 6, 12, 24]
    /// The length the picker starts on (`DEFAULT_WINDOW_HOURS`).
    static let defaultHours = 3
    /// The length the picker shows for a window open now: the first offered
    /// that holds it.
    var pickerHours: Int { Self.lengths.first { Double($0) >= hours.rounded() } ?? Self.defaultHours }
    /// How long a window a link's past frame opens, ending at that frame.
    static let linkHours = 2

    /// Unix seconds of the first and the last step.
    let start: Int
    let end: Int

    /// Both ends on the grid, earlier minutes down; nil for a window of a
    /// single step, one ending before it starts, or one longer than the
    /// route serves.
    init?(start: Int, end: Int) {
        let first = Self.grid(start), last = Self.grid(end)
        guard last > first, (last - first) / Self.stepSeconds + 1 <= Self.maxSteps else { return nil }
        self.start = first
        self.end = last
    }

    /// `hours` long, ending at `end`.
    init?(ending end: Int, hours: Int) {
        self.init(start: end - hours * 3600, end: end)
    }

    /// A unix second down onto the five-minute grid.
    static func grid(_ seconds: Int) -> Int {
        Int((Double(seconds) / Double(stepSeconds)).rounded(.down)) * stepSeconds
    }

    var steps: [Int] { Array(stride(from: start, through: end, by: Self.stepSeconds)) }
    var seconds: Int { end - start }
    var hours: Double { Double(seconds) / 3600 }

    func contains(_ time: Int) -> Bool { time >= start && time <= end }

    /// The window's step nearest `time`.
    func clamp(_ time: Int) -> Int {
        let on = Int((Double(time) / Double(Self.stepSeconds)).rounded()) * Self.stepSeconds
        return max(start, min(end, on))
    }

    /// The window a link's frame opens (`t=` with no `from=`/`to=`): none
    /// while the frame is on the live strip, two hours either side of
    /// `now`; a two-hour window ending at it while the archive keeps it.
    static func forLink(time: Int, now: Int, archive: ArchiveCoverage?) -> RadarWindow? {
        let live = grid(now)
        guard time < live - 2 * 3600, let archive else { return nil }
        let end = grid(time)
        guard end >= archive.since, end <= archive.until else { return nil }
        return RadarWindow(start: max(archive.since, end - linkHours * 3600), end: end)
            ?? RadarWindow(start: end, end: min(archive.until, end + linkHours * 3600))
    }

    // MARK: - Labels

    private func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    private static func date(_ seconds: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(seconds)) }

    /// Whether it runs into another day where the reader is.
    func crossesMidnight(in zone: TimeZone = .current) -> Bool {
        !calendar(zone).isDate(Self.date(start), inSameDayAs: Self.date(end))
    }

    /// A step's label on the strip: its clock time, 24-hour, with the day
    /// in front where the window runs over midnight ("Tue 23:55").
    func label(_ step: Int, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        Self.format(step, template: crossesMidnight(in: timeZone) ? "EEEHHmm" : "HHmm", timeZone: timeZone, locale: locale)
    }

    /// A step's date and time, short enough for a phone's top line ("5 Nov
    /// 14:05", "Nov 5 14:05"); with its weekday where there is room, as
    /// VoiceOver reads the frame's tab ("Thu 5 Nov 14:05").
    static func dateTime(_ step: Int, weekday: Bool = false, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        format(step, template: weekday ? "EEEdMMM" : "dMMM", timeZone: timeZone, locale: locale) + " "
            + format(step, template: "HHmm", timeZone: timeZone, locale: locale)
    }

    /// The window's day and span, as a wide screen's tab names it
    /// (`ArchiveFrame.svelte`): "Thu 5 Nov 14:05–17:05", or both ends dated
    /// where it runs over midnight.
    func span(timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        let first = Self.dateTime(start, weekday: true, timeZone: timeZone, locale: locale)
        guard !crossesMidnight(in: timeZone) else {
            return first + " – " + Self.dateTime(end, weekday: true, timeZone: timeZone, locale: locale)
        }
        return first + "–" + Self.format(end, template: "HHmm", timeZone: timeZone, locale: locale)
    }

    /// A step by its clock, with its weekday once it has crossed midnight
    /// from the window's start: the wide tab's step beside its span.
    func clock(_ step: Int, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        let sameDay = calendar(timeZone).isDate(Self.date(start), inSameDayAs: Self.date(step))
        return Self.format(step, template: sameDay ? "HHmm" : "EEEHHmm", timeZone: timeZone, locale: locale)
    }

    /// The whole window, as the picker sums it up ("5 Nov, 14:05 – 17:05").
    func summary(timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        let formatter = DateIntervalFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateTemplate = "dMMMHHmm"
        return formatter.string(from: Self.date(start), to: Self.date(end))
    }

    private static func format(_ seconds: Int, template: String, timeZone: TimeZone, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date(seconds))
    }

    // MARK: - The strip

    /// Minutes between the strip's labels: about three to five of them,
    /// whatever the length.
    var axisMinutes: Int {
        switch seconds {
        case ...3600: return 15
        case ...(3 * 3600): return 60
        case ...(6 * 3600): return 120
        case ...(12 * 3600): return 180
        default: return 360
        }
    }

    /// Minutes between the ruler's ticks, so a long window is not a solid bar.
    var rulerMinutes: Int {
        switch seconds {
        case ...(3 * 3600): return 5
        case ...(6 * 3600): return 15
        case ...(12 * 3600): return 30
        default: return 60
        }
    }

    /// Minutes between the ruler's taller ticks.
    var majorMinutes: Int {
        switch seconds {
        case ...(3 * 3600): return 30
        case ...(12 * 3600): return 60
        default: return 180
        }
    }

    /// The reader's midnight before the window: ticks counted from it fall
    /// on the clock's whole hours.
    func anchor(timeZone: TimeZone = .current) -> Int {
        Int(calendar(timeZone).startOfDay(for: Self.date(start)).timeIntervalSince1970)
    }
}

/// `GET /v3/archive`: the oldest and newest observed step kept, unix
/// seconds on the grid. Absent (404) while nothing is kept.
struct ArchiveCoverage: Decodable, Equatable, Sendable {
    let since: Int
    let until: Int
    let stepSeconds: Int

    enum CodingKeys: String, CodingKey {
        case since, until
        case stepSeconds = "step_seconds"
    }

    init(since: Int, until: Int, stepSeconds: Int = RadarWindow.stepSeconds) {
        (self.since, self.until, self.stepSeconds) = (since, until, stepSeconds)
    }

    static func decode(_ data: Data) -> ArchiveCoverage? {
        guard let coverage = try? JSONDecoder().decode(ArchiveCoverage.self, from: data), coverage.until > coverage.since else { return nil }
        return coverage
    }

    /// The window a reader picked (`pickWindow`): from `start`, `hours`
    /// long, kept inside what the archive covers. One running past the
    /// newest step ends there; one starting before the oldest starts there.
    /// Nil when nothing of it is kept.
    func pick(start: Int, hours: Int) -> RadarWindow? {
        let first = RadarWindow.grid(start)
        let from = max(first, since), to = min(first + hours * 3600, until)
        guard to > from else { return nil }
        return RadarWindow(start: from, end: to)
    }

    /// Where the picker starts (`seed`): the window open now, or the last
    /// few hours the archive has; never before its oldest step.
    func seed(open: RadarWindow?) -> (start: Int, hours: Int) {
        let start = open?.start ?? RadarWindow.grid(until - RadarWindow.defaultHours * 3600)
        return (max(start, since), open?.pickerHours ?? RadarWindow.defaultHours)
    }

    /// The days the picker offers, each its midnight in `calendar`, oldest
    /// first: every day with anything kept (`coverageDays`).
    func days(calendar: Calendar) -> [Int] {
        var days: [Int] = []
        let last = calendar.startOfDay(for: Self.date(until))
        var day = calendar.startOfDay(for: Self.date(since))
        while day <= last {
            days.append(Int(day.timeIntervalSince1970))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = calendar.startOfDay(for: next)
        }
        return days
    }

    /// The minutes of the day a window may start at on `day` (its midnight
    /// in `calendar`), on the grid (`startMinutes`): the whole day, cut at
    /// the archive's ends on its first and last day.
    func startMinutes(day: Int, calendar: Calendar) -> ClosedRange<Int> {
        func minuteOf(_ seconds: Int) -> Int {
            let parts = calendar.dateComponents([.hour, .minute], from: Self.date(seconds))
            return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }
        func midnight(_ seconds: Int) -> Int { Int(calendar.startOfDay(for: Self.date(seconds)).timeIntervalSince1970) }
        let first = midnight(since) == day ? Int((Double(minuteOf(since)) / 5).rounded(.up)) * 5 : 0
        let last = midnight(until) == day ? minuteOf(until) / 5 * 5 : 1435
        return first ... max(first, last)
    }

    private static func date(_ seconds: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(seconds)) }
}

/// The strikes a past window draws (`/v3/lightning/strikes`, at most three
/// hours a call): those of the half hour before the step on screen, aged
/// against it.
enum ArchiveStrikes {
    /// The longest span the route lists at once.
    static let chunkSeconds = 3 * 3600
    /// What is drawn before the step, as live draws the last half hour.
    static let shownSeconds = 30 * 60

    struct Chunk: Hashable, Sendable {
        let since: Int
        let until: Int
    }

    /// The calls covering the strikes shown at `step`: three-hour chunks on
    /// a fixed grid, so scrubbing reuses them, none ending after `now`.
    static func chunks(at step: Int, now: Int) -> [Chunk] {
        let from = step - shownSeconds
        let first = Int((Double(from) / Double(chunkSeconds)).rounded(.down)) * chunkSeconds
        var chunks: [Chunk] = []
        var since = first
        while since <= step {
            let until = min(since + chunkSeconds, now)
            if until > since { chunks.append(Chunk(since: since, until: until)) }
            since += chunkSeconds
        }
        return chunks
    }

    /// Whether a strike at `milliseconds` is drawn at `step`: in the half
    /// hour up to it.
    static func shown(_ milliseconds: Double, at step: Int) -> Bool {
        let seconds = milliseconds / 1000
        return seconds > Double(step - shownSeconds) && seconds <= Double(step)
    }
}

/// How a bolt on the radar map fades with its strikes' mean age (core's
/// `layers/lightning.ts`): four fifths for the first nine minutes or so,
/// then fainter step by step, to about a quarter at fifty.
enum StrikeFade {
    static func alpha(meanAgeMinutes: Double) -> Double {
        var level = min(Int((meanAgeMinutes / 2.5).rounded()) + 1, 20)
        if level < 5 { level = 0 }
        return max(0, min(1, 1 - Double(level) / 30 * 0.8 - 0.2))
    }
}
