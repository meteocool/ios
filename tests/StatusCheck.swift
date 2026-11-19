import Foundation

/// Checks what the map says is late (core's `feedOutage.test.ts`): which
/// countries' radar has stopped arriving, measured against DWD's, and when
/// the player says so in place of "No Forecast Here".
@main
struct StatusCheck {
    static func main() {
        feedOutage()
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
        precondition(FeedOutage.saysFeedStopped(stalledShare: 0.1, noForecast: true))
        // Otherwise only when stalled networks hold half the screen.
        precondition(!FeedOutage.saysFeedStopped(stalledShare: 0.1, noForecast: false))
        precondition(FeedOutage.saysFeedStopped(stalledShare: 0.5, noForecast: false))
        // Never without a stalled network on screen.
        precondition(!FeedOutage.saysFeedStopped(stalledShare: 0, noForecast: true))
    }
}
