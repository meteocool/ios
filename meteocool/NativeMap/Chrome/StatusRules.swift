//
//  StatusRules.swift
//  meteocool
//
//  What is late, and what the map says of it: which weather services'
//  radar is not reaching meteocool (core's `lib/feedOutage.ts`), what the
//  backend's status says of this screen (`lib/status.ts`), and the one
//  notice above the tray (`lib/noticeQueue.ts`).
//

import Foundation

/// Which countries' radar has stopped arriving, measured against DWD's, and
/// when the player says so in place of "No Forecast Here".
///
/// Each country's radar comes from its own weather service, through
/// EUMETNET, and one of them (or the whole of EUMETNET's feed) can stop
/// while DWD's keeps going. The map then has nothing new to draw for that
/// country, and meteocool's nowcast, which runs on the same radar, has no run
/// for it: the reader is owed the real reason instead. Measured against
/// DWD's newest scan rather than the clock: when everything is late together
/// (an app asleep, meteocool's own backend stalled), no one country's service
/// is to blame, and "Out of date" and "Degraded" say so.
///
/// No app dependencies here: `scripts/check.sh` compiles this file alone.
enum FeedOutage {
    /// How far a network's newest scan may trail DWD's before its feed
    /// counts as stopped: three of its five-minute cycles, as the backend's
    /// composites keep a quiet radar for (`STALLED_BEHIND_S`).
    static let stalledBehind = 15 * 60

    /// What a network's live layer knows: its newest fresh scan, if any, and
    /// whether the backend has answered for it at all.
    struct Feed: Equatable {
        let code: String
        /// Unix seconds; nil with no fresh frame (none yet, or one too old to draw).
        let newestScan: Int?
        let answered: Bool
    }

    /// The networks whose feed has stopped: answered, and with no fresh frame
    /// or one trailing DWD's newest scan (`reference`) by more than
    /// `stalledBehind`. None while DWD's own scan is unknown.
    static func stalledNetworks(_ feeds: [Feed], reference: Int?) -> [String] {
        guard let reference else { return [] }
        return feeds.filter { feed in
            feed.answered && (feed.newestScan.map { reference - $0 > stalledBehind } ?? true)
        }.map(\.code)
    }

    /// Whether the player says the data is not arriving, given the share of
    /// the screen stalled networks draw on, whether it would otherwise say
    /// there is no forecast, and whether a stalled network draws the middle
    /// of the screen: in place of "No Forecast Here" wherever a stalled
    /// network is on screen at all; on any other step only where the reader
    /// is looking, so a map of Germany, live, says nothing of its silent
    /// neighbours however much of a wide screen they take.
    static func saysFeedStopped(stalledShare: Double, noForecast: Bool, atCentre: Bool) -> Bool {
        guard stalledShare > 0 else { return false }
        return noForecast || atCentre
    }
}

/// `GET /v3/status`: what the backend judges late, against its own clock,
/// and our notices to the readers.
struct ServiceStatus: Decodable, Equatable, Sendable {
    let serverTime: Int
    let replay: Bool
    let components: [StatusComponent]
    let notices: [StatusNotice]

    enum CodingKeys: String, CodingKey {
        case serverTime = "server_time"
        case replay, components, notices
    }

    static func decode(_ data: Data) -> ServiceStatus? { try? JSONDecoder().decode(ServiceStatus.self, from: data) }
}

/// One thing a reader can miss, and whether it is arriving.
struct StatusComponent: Decodable, Equatable, Sendable {
    enum State: String, Decodable, Sendable {
        case ok, delayed, down
    }

    /// `radar`, `forecast`, `alerts`, `lightning`, `stations`, `storms`; any
    /// other is ignored, as the API asks.
    let kind: String
    /// `de`, a network's code, or `eu`; nil for the kinds that have none.
    let domain: String?
    let state: State
    /// Unix seconds of what it was judged by; nil when too old to keep.
    let newest: Int?
    let since: Int?

    init(kind: String, domain: String? = nil, state: State, newest: Int?, since: Int? = nil) {
        (self.kind, self.domain, self.state, self.newest, self.since) = (kind, domain, state, newest, since)
    }
}

/// A notice of ours to the readers, in force now.
struct StatusNotice: Decodable, Equatable, Sendable {
    enum Level: String, Decodable, Sendable {
        case info, warning
    }

    let id: String
    let level: Level
    /// The domains it is about, nil for everywhere.
    let domains: [String]?
    let starts: Int
    let ends: Int?
    /// Its text by locale, `en` always there.
    let text: [String: String]
}

/// What the backend says is late, and what of it matters on this screen
/// (core's `lib/status.ts`): the map only asks which of the judged
/// components are on screen, drawn and not `ok`, and which notices are
/// about where it is.
///
/// Pure, with no clock: the coverage is passed in as a box and a predicate
/// per domain (`StatusCoverage.swift`), the layers as flags.
enum StatusRules {
    /// A lon/lat box.
    struct Extent: Equatable, Sendable {
        let west, south, east, north: Double

        init(_ west: Double, _ south: Double, _ east: Double, _ north: Double) {
            (self.west, self.south, self.east, self.north) = (west, south, east, north)
        }

        static let world = Extent(-180, -85, 180, 85)
    }

    /// Where a domain's radar draws: a box round it, and whether a point
    /// (lon, lat) inside the box is its ground.
    struct DomainCoverage {
        let extent: Extent
        let covers: (Double, Double) -> Bool
    }

    /// Each domain's ground, by the component's `domain`.
    typealias Coverage = [String: DomainCoverage]

    /// Which of the layers that draw a component are on.
    struct DrawnLayers: Equatable, Sendable {
        var radar: Bool
        var lightning: Bool
        var stations: Bool
        var storms: Bool
    }

    /// The kinds this map knows (`KNOWN_KINDS`).
    static let knownKinds = ["radar", "forecast", "alerts", "lightning", "stations", "storms"]

    /// How long an answer is used with no newer one; past that the map's own
    /// rules come back (`TRUST_MS`).
    static let trust: TimeInterval = 5 * 60

    /// Whether an answer received at `receivedAt` is still the one to go by.
    static func trusted(receivedAt: TimeInterval, now: TimeInterval) -> Bool {
        now >= receivedAt && now - receivedAt < trust
    }

    private static func mercatorY(_ lat: Double) -> Double {
        log(tan(.pi / 4 + max(-85, min(85, lat)) * .pi / 360))
    }

    private static func latitude(_ y: Double) -> Double {
        (atan(exp(y)) - .pi / 4) * (360 / .pi)
    }

    /// The share of the view a domain's ground takes, from a grid of
    /// `samples` × `samples` points over the part of the view inside the
    /// domain's box, even in Web Mercator (`shareInView`).
    static func shareInView(_ coverage: DomainCoverage, view: Extent, samples: Int = 12) -> Double {
        let box = coverage.extent
        let west = max(view.west, box.west), east = min(view.east, box.east)
        let south = max(view.south, box.south), north = min(view.north, box.north)
        guard west < east, south < north, view.east > view.west, view.north > view.south else { return 0 }
        let bottom = mercatorY(south), top = mercatorY(north)
        let viewHeight = mercatorY(view.north) - mercatorY(view.south)
        guard viewHeight > 0 else { return 0 }
        var inside = 0
        for row in 0 ..< samples {
            let lat = latitude(bottom + (Double(row) + 0.5) / Double(samples) * (top - bottom))
            for column in 0 ..< samples {
                let lon = west + (Double(column) + 0.5) / Double(samples) * (east - west)
                if coverage.covers(lon, lat) { inside += 1 }
            }
        }
        let overlap = (east - west) / (view.east - view.west) * ((top - bottom) / viewHeight)
        return overlap * Double(inside) / Double(samples * samples)
    }

    /// The share of the view any of `domains` draws on, from a grid of
    /// `samples` × `samples` points over the whole view, even in Web
    /// Mercator (`1 - uncoveredShare` over `drawnByDomains`).
    static func unionShare(_ domains: [String], view: Extent, coverage: Coverage, samples: Int = 12) -> Double {
        let grounds = domains.compactMap { coverage[$0] }
        guard !grounds.isEmpty, view.east > view.west, view.north > view.south else { return 0 }
        let bottom = mercatorY(view.south), top = mercatorY(view.north)
        var inside = 0
        for row in 0 ..< samples {
            let lat = latitude(bottom + (Double(row) + 0.5) / Double(samples) * (top - bottom))
            for column in 0 ..< samples {
                let lon = view.west + (Double(column) + 0.5) / Double(samples) * (view.east - view.west)
                if grounds.contains(where: { $0.covers(lon, lat) }) { inside += 1 }
            }
        }
        return Double(inside) / Double(samples * samples)
    }

    /// The middle of the screen, where the reader is looking, even in Web
    /// Mercator (`viewCentre`): lon, lat.
    static func viewCentre(_ view: Extent) -> (lon: Double, lat: Double) {
        ((view.west + view.east) / 2, latitude((mercatorY(view.south) + mercatorY(view.north)) / 2))
    }

    /// Whether a domain's ground is under the middle of the screen.
    static func coversCentre(_ domain: String, view: Extent, coverage: Coverage) -> Bool {
        guard let ground = coverage[domain] else { return false }
        let (lon, lat) = viewCentre(view)
        let box = ground.extent
        return lon >= box.west && lon <= box.east && lat >= box.south && lat <= box.north && ground.covers(lon, lat)
    }

    /// Whether a component is about the middle of the screen: its domain's
    /// ground is there, or it has no domain (`atCentre`). What the map says
    /// unasked goes by this; the sheet behind the pill lists it all the same.
    static func atCentre(_ component: StatusComponent, view: Extent, coverage: Coverage) -> Bool {
        guard let domain = component.domain else { return true }
        return coversCentre(domain, view: view, coverage: coverage)
    }

    /// The share of the view a component is about: its domain's, all of it
    /// without one, none for a domain the map has no ground for (`viewShare`).
    static func viewShare(_ component: StatusComponent, view: Extent, coverage: Coverage) -> Double {
        guard let domain = component.domain else { return 1 }
        return coverage[domain].map { shareInView($0, view: view) } ?? 0
    }

    /// Whether a component is about anything on screen (`inView`).
    static func inView(_ component: StatusComponent, view: Extent, coverage: Coverage) -> Bool {
        viewShare(component, view: view, coverage: coverage) > 0
    }

    /// Whether the map draws a component: the radar and its forecast with the
    /// radar layer, the others with their own; never `alerts`, nor a kind it
    /// does not know (`drawn`).
    static func drawn(_ component: StatusComponent, layers: DrawnLayers) -> Bool {
        switch component.kind {
        case "radar", "forecast": return layers.radar
        case "lightning": return layers.lightning
        case "stations": return layers.stations
        case "storms": return layers.storms
        default: return false
        }
    }

    private static func worse(_ state: StatusComponent.State) -> Int {
        switch state {
        case .down: return 2
        case .delayed: return 1
        case .ok: return 0
        }
    }

    /// A component late here, how much of the screen it is about, and
    /// whether it is about its middle.
    struct Affected: Equatable {
        let component: StatusComponent
        let share: Double
        let atCentre: Bool
    }

    /// What is late on this screen: in view, drawn and not `ok`, `down`
    /// before `delayed`, then the larger share of the screen first (`affected`).
    static func affected(_ status: ServiceStatus, view: Extent, layers: DrawnLayers, coverage: Coverage) -> [Affected] {
        status.components
            .filter { knownKinds.contains($0.kind) && $0.state != .ok && drawn($0, layers: layers) }
            .map { Affected(component: $0, share: viewShare($0, view: view, coverage: coverage),
                            atCentre: atCentre($0, view: view, coverage: coverage)) }
            .filter { $0.share > 0 }
            .enumerated()
            .sorted { a, b in
                let (wa, wb) = (worse(a.element.component.state), worse(b.element.component.state))
                if wa != wb { return wa > wb }
                if a.element.share != b.element.share { return a.element.share > b.element.share }
                return a.offset < b.offset
            }
            .map(\.element)
    }

    enum Headline: Equatable {
        case down, delayed
    }

    /// What the pill says of what is late: `down` when a radar that is down
    /// is under the middle of the screen, `delayed` when anything else late
    /// is (one without a domain always is), else nothing (`headline`).
    static func headline(_ late: [Affected]) -> Headline? {
        let central = late.filter(\.atCentre)
        if central.contains(where: { $0.component.kind == "radar" && $0.component.state == .down }) { return .down }
        return central.isEmpty ? nil : .delayed
    }

    /// A notice's text in the reader's language: the exact tag, else its
    /// language alone, else English (`noticeText`).
    static func noticeText(_ notice: StatusNotice, locale: String?) -> String {
        let tag = (locale ?? "en").lowercased()
        let base = String(tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "en")
        return notice.text[tag] ?? notice.text[base] ?? notice.text["en"] ?? notice.text.sorted { $0.key < $1.key }.first?.value ?? ""
    }

    /// A notice of ours, ready to show.
    struct ShownNotice: Equatable, Sendable {
        let id: String
        let level: StatusNotice.Level
        let text: String
    }

    /// Our notices for this screen: those for everywhere and those for a
    /// domain under its middle; `warning` before `info`, otherwise in the
    /// order given (`noticesFor`).
    static func noticesFor(_ status: ServiceStatus, view: Extent, locale: String?, coverage: Coverage) -> [ShownNotice] {
        status.notices
            .filter { notice in notice.domains.map { $0.contains { coversCentre($0, view: view, coverage: coverage) } } ?? true }
            .enumerated()
            .sorted { a, b in
                let (ra, rb) = (a.element.level == .warning ? 0 : 1, b.element.level == .warning ? 0 : 1)
                return ra != rb ? ra < rb : a.offset < b.offset
            }
            .map { ShownNotice(id: $0.element.id, level: $0.element.level, text: noticeText($0.element, locale: locale)) }
    }

    private static func radarOf(_ status: ServiceStatus, _ domain: String?) -> StatusComponent? {
        status.components.first { $0.kind == "radar" && $0.domain == domain }
    }

    /// The domains whose radar the status says is not arriving, `de` among
    /// them (`stalledDomains`).
    static func stalledDomains(_ status: ServiceStatus) -> [String] {
        status.components.filter { $0.kind == "radar" && $0.state != .ok }.compactMap(\.domain)
    }

    /// Whether a radar that is `down` is under the middle of the screen: the
    /// radar shown there is not now any more (`radarDownInView`).
    static func radarDownInView(_ status: ServiceStatus, view: Extent, coverage: Coverage) -> Bool {
        status.components.contains { $0.kind == "radar" && $0.state == .down && atCentre($0, view: view, coverage: coverage) }
    }

    /// A forecast not arriving while its domain's radar is.
    private static func forecastStopped(_ component: StatusComponent, in status: ServiceStatus) -> Bool {
        component.kind == "forecast" && component.state != .ok && (radarOf(status, component.domain)?.state ?? .ok) == .ok
    }

    /// The share of the screen whose forecast is not arriving while its
    /// radar is (`forecastStoppedShare`).
    static func forecastStoppedShare(_ status: ServiceStatus, view: Extent, coverage: Coverage) -> Double {
        status.components.filter { forecastStopped($0, in: status) }
            .reduce(0) { $0 + viewShare($1, view: view, coverage: coverage) }
    }

    /// Whether such a forecast lies under the middle of the screen (`forecastStoppedAtCentre`).
    static func forecastStoppedAtCentre(_ status: ServiceStatus, view: Extent, coverage: Coverage) -> Bool {
        status.components.contains { forecastStopped($0, in: status) && atCentre($0, view: view, coverage: coverage) }
    }
}

/// Which one notice the slot above the tray shows, of all that apply (core's
/// `lib/noticeQueue.ts`): every candidate ranked once, in a fixed order, a
/// dismissed one yielding to the next. Ours for this view first, `warning`
/// first; then no radar coverage, radar not arriving, forecast not arriving,
/// no forecast here, and the dry outlook.
enum NoticeQueue {
    /// A condition the map works out for itself.
    enum Condition: String, CaseIterable, Sendable {
        case noCoverage = "no-coverage"
        case radarStopped = "radar-stopped"
        case forecastStopped = "forecast-stopped"
        case noForecast = "no-forecast"
        case dryOutlook = "dry-outlook"
    }

    /// What the slot shows.
    enum Queued: Equatable, Sendable {
        case ours(StatusRules.ShownNotice)
        case condition(Condition)
    }

    /// What applies right now.
    struct Candidates: Equatable, Sendable {
        var ours: [StatusRules.ShownNotice] = []
        var noCoverage = false
        var radarStopped = false
        var forecastStopped = false
        var noForecast = false
        var dryOutlook = false

        func applies(_ condition: Condition) -> Bool {
            switch condition {
            case .noCoverage: return noCoverage
            case .radarStopped: return radarStopped
            case .forecastStopped: return forecastStopped
            case .noForecast: return noForecast
            case .dryOutlook: return dryOutlook
            }
        }
    }

    /// What a dismissal is kept by: ours by id, a condition by its name.
    static func dismissalKey(_ notice: Queued) -> String {
        switch notice {
        case .ours(let notice): return "ours:\(notice.id)"
        case .condition(let condition): return condition.rawValue
        }
    }

    /// Every candidate that applies, best first, dismissed or not (`ranked`).
    static func ranked(_ candidates: Candidates) -> [Queued] {
        var order = candidates.ours.map(Queued.ours)
        if candidates.noCoverage { order.append(.condition(.noCoverage)) }
        if candidates.radarStopped { order.append(.condition(.radarStopped)) }
        if candidates.forecastStopped { order.append(.condition(.forecastStopped)) }
        // Not while either feed is the reason there is no forecast, dismissed
        // or not: "No Forecast Here" would then give the wrong one.
        if candidates.noForecast, !candidates.radarStopped, !candidates.forecastStopped { order.append(.condition(.noForecast)) }
        if candidates.dryOutlook { order.append(.condition(.dryOutlook)) }
        return order
    }

    /// The one to show: the first that applies and was not dismissed (`nextNotice`).
    static func next(_ candidates: Candidates, dismissed: Set<String>) -> Queued? {
        ranked(candidates).first { !dismissed.contains(dismissalKey($0)) }
    }

    /// The dismissals still to keep: a condition's goes once it no longer
    /// applies, so coming back to it says so again; ours are kept by id for
    /// the session, whatever applies (`rearmed`).
    static func rearmed(_ dismissed: Set<String>, _ candidates: Candidates) -> Set<String> {
        dismissed.filter { key in
            key.hasPrefix("ours:") || Condition(rawValue: key).map(candidates.applies) == true
        }
    }
}

/// What the trusted status says about this screen (core's `StatusVerdict`,
/// `statusVerdict` in `lib/statusFeed.ts`).
struct StatusVerdict: Equatable {
    /// What is late on screen, worst first.
    let affected: [StatusRules.Affected]
    /// What the pill says of it.
    let headline: StatusRules.Headline?
    /// Our notices for this screen, `warning` first, in the reader's language.
    let notices: [StatusRules.ShownNotice]
    /// A `radar` under the middle of the screen is `down`.
    let radarDown: Bool
    /// The domains whose radar is not `ok`, wherever they are.
    let stalled: [String]
    /// The share of the screen whose forecast is not arriving while its radar is.
    let forecastStopped: Double
    /// Whether that forecast is under the middle of the screen.
    let forecastStoppedAtCentre: Bool
    /// The newest radar scan on screen, unix seconds on the server's clock.
    let newestRadar: Int?
    /// When the answer was received, and the server's clock then: what
    /// "min old" is measured from.
    let receivedAt: TimeInterval
    let serverTime: Int

    /// The trusted status, read for a view, the layers drawn and a language.
    init(_ status: ServiceStatus, receivedAt: TimeInterval, view: StatusRules.Extent, layers: StatusRules.DrawnLayers, locale: String?,
         coverage: StatusRules.Coverage) {
        let late = StatusRules.affected(status, view: view, layers: layers, coverage: coverage)
        affected = late
        headline = StatusRules.headline(late)
        notices = StatusRules.noticesFor(status, view: view, locale: locale, coverage: coverage)
        radarDown = layers.radar && StatusRules.radarDownInView(status, view: view, coverage: coverage)
        stalled = StatusRules.stalledDomains(status)
        forecastStopped = layers.radar ? StatusRules.forecastStoppedShare(status, view: view, coverage: coverage) : 0
        forecastStoppedAtCentre = layers.radar && StatusRules.forecastStoppedAtCentre(status, view: view, coverage: coverage)
        newestRadar = status.components
            .filter { $0.kind == "radar" && $0.newest != nil && StatusRules.inView($0, view: view, coverage: coverage) }
            .compactMap(\.newest).max()
        self.receivedAt = receivedAt
        serverTime = status.serverTime
    }

    /// How old the newest radar on screen is, in minutes, by the server's
    /// clock carried forward from the answer.
    func radarAge(now: TimeInterval) -> Int? {
        newestRadar.map { max(0, Int((Double(serverTime - $0) + (now - receivedAt)) / 60 + 0.5)) }
    }
}
