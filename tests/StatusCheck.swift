import Foundation

/// Checks what the map says is late (core's `feedOutage.test.ts`,
/// `status.test.ts`, `noticeQueue.test.ts`): which countries' radar has
/// stopped arriving, what the backend's status says of a screen, against
/// boxes and against the map's own ground (`radar-coverage.json` and
/// `radar-wash.json`, the paths given), and which one notice is shown.
@main
struct StatusCheck {
    static func main() {
        feedOutage()
        status()
        let arguments = CommandLine.arguments
        if arguments.count > 2, let coverage = RadarCoverage(json: try! Data(contentsOf: URL(fileURLWithPath: arguments[1]))),
           let reach = RadarReach(json: try! Data(contentsOf: URL(fileURLWithPath: arguments[2]))) {
            groundCoverage(coverage.statusCoverage(dwdReach: reach.dwd))
        } else {
            fatalError("usage: check-status radar-coverage.json radar-wash.json")
        }
        noticeQueue()
        print("StatusCheck: ok")
    }

    static let hx = 1_794_430_200

    static func feedOutage() {
        typealias Feed = FeedOutage.Feed
        // A network level with DWD is live.
        precondition(FeedOutage.stalledNetworks([Feed(code: "fr", newestScan: hx - 120, answered: true)], reference: hx).isEmpty)
        // Three cycles behind DWD is still live, one more and it has stopped.
        let feeds = [Feed(code: "fr", newestScan: hx - FeedOutage.stalledBehind, answered: true),
                     Feed(code: "pl", newestScan: hx - FeedOutage.stalledBehind - 60, answered: true)]
        precondition(FeedOutage.stalledNetworks(feeds, reference: hx) == ["pl"])
        // No fresh frame at all: stopped once the backend has answered for it
        // (2026-11-11: EUMETNET's bucket stopped, every country's frame aged out).
        precondition(FeedOutage.stalledNetworks([Feed(code: "se", newestScan: nil, answered: true)], reference: hx) == ["se"])
        // Not yet heard from is not an outage.
        precondition(FeedOutage.stalledNetworks([Feed(code: "se", newestScan: nil, answered: false)], reference: hx).isEmpty)
        // Nothing is stalled while DWD's own scan is unknown.
        precondition(FeedOutage.stalledNetworks([Feed(code: "se", newestScan: nil, answered: true)], reference: nil).isEmpty)
        // In place of "no forecast" wherever a stalled network is on screen.
        precondition(FeedOutage.saysFeedStopped(stalledShare: 0.1, noForecast: true, atCentre: false))
        // Otherwise only when a stalled network draws the middle of the screen:
        // a wide map of Germany with silent neighbours all round says nothing.
        precondition(FeedOutage.saysFeedStopped(stalledShare: 0.1, noForecast: false, atCentre: true))
        precondition(!FeedOutage.saysFeedStopped(stalledShare: 0.7, noForecast: false, atCentre: false))
        // Never without a stalled network on screen.
        precondition(!FeedOutage.saysFeedStopped(stalledShare: 0, noForecast: true, atCentre: true))
    }

    // MARK: - lib/status.ts

    static let now = 1_794_480_000
    typealias Extent = StatusRules.Extent

    /// Two neighbouring square countries, west and east of 10°E, and a third far off.
    static func box(_ extent: Extent) -> StatusRules.DomainCoverage {
        StatusRules.DomainCoverage(extent: extent) { lon, lat in
            lon >= extent.west && lon <= extent.east && lat >= extent.south && lat <= extent.north
        }
    }

    static let boxes: StatusRules.Coverage = ["de": box(Extent(5, 47, 10, 55)), "pl": box(Extent(10, 47, 20, 55)), "fi": box(Extent(20, 60, 30, 70))]
    static let overDE = Extent(6, 48, 9, 50)
    static let overPL = Extent(15, 50, 18, 52)
    static let across = Extent(8, 48, 12, 50)
    static let allOn = StatusRules.DrawnLayers(radar: true, lightning: true, stations: true, storms: true)

    static func component(_ kind: String, _ state: StatusComponent.State, _ domain: String? = nil) -> StatusComponent {
        StatusComponent(kind: kind, domain: domain, state: state, newest: now - 600, since: state == .ok ? nil : now - 300)
    }

    static func status(_ components: [StatusComponent], _ notices: [StatusNotice] = []) -> ServiceStatus {
        ServiceStatus(serverTime: now, replay: false, components: components, notices: notices)
    }

    static func notice(_ id: String, _ level: StatusNotice.Level, _ domains: [String]?, _ text: [String: String]? = nil) -> StatusNotice {
        StatusNotice(id: id, level: level, domains: domains, starts: now - 60, ends: nil, text: text ?? ["en": id])
    }

    static func status() {
        // An answer is trusted for five minutes and not after, nor from this clock's future.
        precondition(StatusRules.trusted(receivedAt: 1000, now: 1000 + StatusRules.trust - 0.001))
        precondition(!StatusRules.trusted(receivedAt: 1000, now: 1000 + StatusRules.trust))
        precondition(!StatusRules.trusted(receivedAt: 5000, now: 1000))
        // The answer as the API gives it.
        let json = #"{"server_time": 1, "replay": false, "components": [{"kind": "lightning", "state": "ok", "newest": 1},"#
            + #" {"kind": "radar", "domain": "pl", "state": "down", "newest": null, "since": 0}],"#
            + #" "notices": [{"id": "a", "level": "warning", "domains": null, "starts": 0, "ends": null, "text": {"en": "A"}}]}"#
        let decoded = ServiceStatus.decode(Data(json.utf8))
        precondition(decoded?.components.count == 2 && decoded?.components[1].newest == nil && decoded?.notices.first?.level == .warning)

        let inView = { (c: StatusComponent, view: Extent) in StatusRules.inView(c, view: view, coverage: boxes) }
        // A component with a domain is in view where that domain's ground is.
        precondition(inView(component("radar", .down, "pl"), overPL))
        precondition(!inView(component("radar", .down, "pl"), overDE))
        precondition(inView(component("radar", .down, "pl"), across))
        // One without a domain is always in view.
        precondition(inView(component("lightning", .delayed), overDE))
        precondition(inView(component("stations", .down), Extent(100, 0, 110, 10)))
        // A domain the map has no ground for is in no view.
        precondition(!inView(component("radar", .down, "eu"), overDE))
        // A domain in a corner of the view is found and given its share.
        let share = StatusRules.shareInView(boxes["pl"]!, view: across)
        precondition(share > 0.45 && share < 0.55, "share \(share)")
        let sliver = StatusRules.shareInView(boxes["fi"]!, view: Extent(0, 50, 20.5, 60.5))
        precondition(sliver > 0 && sliver < 0.01, "sliver \(sliver)")

        // The radar and its forecast are drawn with the radar layer.
        var off = allOn
        off.radar = false
        precondition(StatusRules.drawn(component("radar", .down, "de"), layers: allOn))
        precondition(StatusRules.drawn(component("forecast", .down, "de"), layers: allOn))
        precondition(!StatusRules.drawn(component("radar", .down, "de"), layers: off))
        precondition(!StatusRules.drawn(component("forecast", .down, "de"), layers: off))
        // Lightning, stations and storms with their own layers.
        let none = StatusRules.DrawnLayers(radar: true, lightning: false, stations: false, storms: false)
        for kind in ["lightning", "stations", "storms"] {
            precondition(!StatusRules.drawn(component(kind, .down), layers: none), kind)
            var on = none
            switch kind {
            case "lightning": on.lightning = true
            case "stations": on.stations = true
            default: on.storms = true
            }
            precondition(StatusRules.drawn(component(kind, .down), layers: on), kind)
        }
        // Alerts are never drawn; a kind the map does not know is ignored.
        precondition(!StatusRules.drawn(component("alerts", .down, "de"), layers: allOn))
        let unknown = component("satellite", .down, "de")
        precondition(!StatusRules.drawn(unknown, layers: allOn))
        precondition(StatusRules.affected(status([unknown]), view: overDE, layers: allOn, coverage: boxes).isEmpty)

        // Affected leaves out what is ok, off screen or not drawn.
        let mixed = status([component("radar", .ok, "de"), component("radar", .down, "pl"), component("alerts", .down, "de"),
                            component("stations", .delayed)])
        var noStations = allOn
        noStations.stations = false
        precondition(StatusRules.affected(mixed, view: overDE, layers: noStations, coverage: boxes).isEmpty)
        // Down before delayed, then the larger share of the screen first.
        let ranked = status([component("lightning", .delayed), component("forecast", .delayed, "pl"),
                             component("radar", .down, "pl"), component("radar", .down, "de")])
        let order = StatusRules.affected(ranked, view: Extent(7, 48, 11, 50), layers: allOn, coverage: boxes)
            .map { "\($0.component.kind):\($0.component.domain ?? "")" }
        precondition(order == ["radar:de", "radar:pl", "lightning:", "forecast:pl"], "\(order)")
        // A forecast with no newest left is affected as down.
        let gone = StatusComponent(kind: "forecast", domain: "de", state: .down, newest: nil)
        precondition(StatusRules.affected(status([gone]), view: overDE, layers: allOn, coverage: boxes).map(\.component) == [gone])
        // An absent component is unknown, not down.
        precondition(StatusRules.affected(status([component("radar", .ok, "de")]), view: overDE, layers: allOn, coverage: boxes).isEmpty)
        precondition(!StatusRules.radarDownInView(status([]), view: overDE, coverage: boxes))

        // The radar is out of date only where a down radar is on screen; a delayed one is not.
        let plDown = status([component("radar", .down, "pl"), component("radar", .ok, "de")])
        precondition(StatusRules.radarDownInView(plDown, view: overPL, coverage: boxes))
        precondition(!StatusRules.radarDownInView(plDown, view: overDE, coverage: boxes))
        precondition(!StatusRules.radarDownInView(status([component("radar", .delayed, "de")]), view: overDE, coverage: boxes))
        // The stopped networks are the radars not ok, Germany's among them.
        let stopped = status([component("radar", .down, "de"), component("radar", .delayed, "pl"), component("radar", .ok, "fr"),
                              component("forecast", .down, "fi")])
        precondition(StatusRules.stalledDomains(stopped) == ["de", "pl"])
        // The forecast is not arriving where it is late and its radar is not…
        precondition(StatusRules.forecastStoppedShare(status([component("forecast", .down, "de"), component("radar", .ok, "de")]),
                                                      view: overDE, coverage: boxes) == 1)
        // …under a late radar it is the radar's notice; off screen it is nothing here.
        precondition(StatusRules.forecastStoppedShare(status([component("forecast", .down, "pl"), component("radar", .down, "pl")]),
                                                      view: overPL, coverage: boxes) == 0)
        precondition(StatusRules.forecastStoppedShare(status([component("forecast", .down, "fi")]), view: overDE, coverage: boxes) == 0)

        // Our notices: those for everywhere and those for a domain on screen.
        let notices = status([], [notice("pl", .info, ["pl"]), notice("all", .info, nil), notice("fi", .info, ["fi"])])
        precondition(StatusRules.noticesFor(notices, view: overPL, locale: "en", coverage: boxes).map(\.id) == ["pl", "all"])
        precondition(StatusRules.noticesFor(notices, view: overDE, locale: "en", coverage: boxes).map(\.id) == ["all"])
        // A warning before an info, otherwise in the order given.
        let levels = status([], [notice("a", .info, nil), notice("b", .warning, nil), notice("c", .info, nil)])
        precondition(StatusRules.noticesFor(levels, view: overDE, locale: "en", coverage: boxes).map(\.id) == ["b", "a", "c"])
        // In the reader's language, its base language, else English.
        let serviced = notice("x", .info, nil, ["en": "Serviced", "de": "Gewartet"])
        precondition(StatusRules.noticeText(serviced, locale: "de") == "Gewartet")
        precondition(StatusRules.noticeText(serviced, locale: "de-AT") == "Gewartet")
        precondition(StatusRules.noticeText(serviced, locale: "pl") == "Serviced")
        precondition(StatusRules.noticeText(serviced, locale: nil) == "Serviced")

        // A neighbour's radar down at the edge of the screen is no headline.
        let edge = Extent(6, 48, 10.8, 50)
        let late = StatusRules.affected(plDown, view: edge, layers: allOn, coverage: boxes)
        precondition(late.count == 1 && StatusRules.headline(late) == nil)
        precondition(!StatusRules.radarDownInView(status([component("radar", .down, "pl")]), view: edge, coverage: boxes))
        // A radar down under the middle of the screen is the headline.
        precondition(StatusRules.headline(StatusRules.affected(plDown, view: Extent(6, 48, 12, 50), layers: allOn, coverage: boxes)) == nil)
        precondition(StatusRules.headline(StatusRules.affected(plDown, view: Extent(9, 48, 15, 50), layers: allOn, coverage: boxes)) == .down)
        precondition(StatusRules.radarDownInView(plDown, view: Extent(9, 48, 15, 50), coverage: boxes))
        // The middle decides, not how much of the screen a late neighbour takes.
        precondition(StatusRules.headline(StatusRules.affected(plDown, view: Extent(9, 48, 20, 50), layers: allOn, coverage: boxes)) == .down)
        precondition(StatusRules.headline(StatusRules.affected(plDown, view: Extent(2, 48, 13, 50), layers: allOn, coverage: boxes)) == nil)
        // Anything late without a domain is a delayed headline.
        precondition(StatusRules.headline(StatusRules.affected(status([component("lightning", .delayed)]), view: overDE, layers: allOn,
                                                               coverage: boxes)) == .delayed)
        // A notice for a domain at the edge of the screen is not shown there.
        precondition(StatusRules.noticesFor(status([], [notice("pl", .warning, ["pl", "fi"])]), view: edge, locale: "en", coverage: boxes).isEmpty)
    }

    /// The map's own ground, from the coverage built into the app.
    static func groundCoverage(_ coverage: StatusRules.Coverage) {
        let poland = Extent(19, 51.5, 21, 52.5), bavaria = Extent(11, 48, 12.5, 48.8)
        let pl = component("radar", .down, "pl")
        precondition(StatusRules.inView(pl, view: poland, coverage: coverage))
        precondition(!StatusRules.inView(pl, view: bavaria, coverage: coverage))
        // Germany's ground is DWD's reach, less the networks'.
        let de = component("radar", .down, "de")
        precondition(StatusRules.inView(de, view: bavaria, coverage: coverage))
        precondition(!StatusRules.inView(de, view: poland, coverage: coverage))

        // The outage of 2026-11-12: EUMETNET's feed stopped, every network
        // and its forecast down, DWD's fine.
        let networks = coverage.keys.filter { $0 != "de" }.sorted()
        precondition(networks.count == 15, "\(networks)")
        let eumetnetDown = status([component("radar", .ok, "de"), component("forecast", .ok, "de")]
            + networks.flatMap { [component("radar", .down, $0), StatusComponent(kind: "forecast", domain: $0, state: .down, newest: nil)] })
        // A German screen to its borders hears nothing unasked.
        for view in [Extent(5.5, 47.2, 15.2, 55.1), Extent(12, 51.5, 15.5, 53.5), Extent(6, 48.5, 8.5, 50)] {
            let late = StatusRules.affected(eumetnetDown, view: view, layers: allOn, coverage: coverage)
            precondition(StatusRules.headline(late) == nil, "pill over \(view)")
            precondition(!StatusRules.radarDownInView(eumetnetDown, view: view, coverage: coverage), "dimming over \(view)")
            precondition(StatusRules.forecastStoppedShare(eumetnetDown, view: view, coverage: coverage) == 0, "forecast over \(view)")
        }
        // A Polish screen is told.
        precondition(StatusRules.headline(StatusRules.affected(eumetnetDown, view: poland, layers: allOn, coverage: coverage)) == .down)
    }

    // MARK: - lib/noticeQueue.ts

    static func noticeQueue() {
        typealias Candidates = NoticeQueue.Candidates
        let warning = StatusRules.ShownNotice(id: "pl-service", level: .warning, text: "Poland's radars are being serviced.")
        let info = StatusRules.ShownNotice(id: "hello", level: .info, text: "Hello.")
        let everything = Candidates(ours: [warning, info], noCoverage: true, radarStopped: true, forecastStopped: true, noForecast: true,
                                    dryOutlook: true)
        func kinds(_ candidates: Candidates) -> [String] {
            NoticeQueue.ranked(candidates).map {
                if case .ours(let notice) = $0 { return notice.id }
                return NoticeQueue.dismissalKey($0)
            }
        }
        // Nothing applies, nothing is shown.
        precondition(NoticeQueue.next(Candidates(), dismissed: []) == nil)
        // Ours first, then coverage, the radar, the forecast and the dry outlook.
        precondition(kinds(everything) == ["pl-service", "hello", "no-coverage", "radar-stopped", "forecast-stopped", "dry-outlook"])
        // No forecast here after the feeds and before the dry outlook…
        precondition(kinds(Candidates(noForecast: true, dryOutlook: true)) == ["no-forecast", "dry-outlook"])
        // …and not while either feed is the reason.
        precondition(kinds(Candidates(radarStopped: true, noForecast: true)) == ["radar-stopped"])
        precondition(kinds(Candidates(forecastStopped: true, noForecast: true)) == ["forecast-stopped"])
        // The dry outlook cannot stand under the radar's notice.
        precondition(NoticeQueue.next(Candidates(radarStopped: true, dryOutlook: true), dismissed: []) == .condition(.radarStopped))
        // Only the first is shown.
        precondition(NoticeQueue.next(everything, dismissed: []) == .ours(warning))
        // A dismissed notice yields to the next.
        var onlyWarning = everything
        onlyWarning.ours = [warning]
        precondition(NoticeQueue.next(onlyWarning, dismissed: [NoticeQueue.dismissalKey(.ours(warning)), "no-coverage"])
            == .condition(.radarStopped))
        // The radar's notice dismissed, the forecast's still yields to nothing wrong.
        precondition(NoticeQueue.next(Candidates(radarStopped: true, noForecast: true), dismissed: ["radar-stopped"]) == nil)
        // A dismissed condition comes back once it has cleared and returns.
        precondition(NoticeQueue.rearmed(["radar-stopped"], Candidates(radarStopped: true)) == ["radar-stopped"])
        let cleared = NoticeQueue.rearmed(["radar-stopped"], Candidates())
        precondition(cleared.isEmpty)
        precondition(NoticeQueue.next(Candidates(radarStopped: true), dismissed: cleared) == .condition(.radarStopped))
        // Ours stay dismissed for the session, applying or not.
        let key = NoticeQueue.dismissalKey(.ours(warning))
        precondition(NoticeQueue.rearmed([key], Candidates()) == [key])
        // No forecast here stays dismissed while it applies under the radar's notice.
        precondition(NoticeQueue.rearmed(["no-forecast"], Candidates(radarStopped: true, noForecast: true)) == ["no-forecast"])
    }

}
