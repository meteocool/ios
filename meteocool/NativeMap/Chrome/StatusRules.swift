//
//  StatusRules.swift
//  meteocool
//
//  Which weather services' radar is not reaching meteocool (core's
//  `lib/feedOutage.ts`).
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
    /// the screen stalled networks draw on and whether it would otherwise say
    /// there is no forecast: in its place wherever a stalled network is on
    /// screen at all; on any other step only once they hold half the screen,
    /// so a border strip of a silent neighbour does not put a notice over a
    /// map that is otherwise live.
    static func saysFeedStopped(stalledShare: Double, noForecast: Bool) -> Bool {
        guard stalledShare > 0 else { return false }
        return noForecast || stalledShare >= 0.5
    }
}
