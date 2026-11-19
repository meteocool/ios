//
//  PlaybackRules.swift
//  meteocool
//
//  Where playback goes, when it moves on, and what is loaded ahead of it:
//  core's `lib/playbackLoop.ts`, `lib/playbackGate.ts` and `lib/framePreload.ts`.
//

import Foundation

/// The player's rules, in steps (unix seconds) as core has them.
///
/// No app dependencies here: `scripts/check.sh` compiles this file alone.
enum PlaybackRules {
    // MARK: - The loop (lib/playbackLoop.ts)

    static let stepSeconds = 300

    /// Where the loop is, for `nextFrame`.
    struct LoopState {
        /// The step on screen.
        var shown: Int
        /// The newest observed step.
        var latestObservation: Int
        /// The grid's now, where a full playback starts again.
        var now: Int
        /// The last step playback may reach: the forecast's end.
        var lastStep: Int
        /// The grid's first step.
        var start: Int
        /// Where playback was started from.
        var loopFrom: Int
        /// The "play from the start" setting.
        var fromStart = false
        /// The forecast covers none of the screen.
        var noForecast = false
        /// The only steps playback may land on, oldest first: an open radar's, with a sweep.
        var only: [Int]? = nil
    }

    /// The step after `shown`, wrapping round at the end of what is worth
    /// playing: through the forecast and round to now (or the start); with no
    /// forecast on screen, through the past and back to where play was
    /// pressed; with a radar open, through its sweeps alone and round all of
    /// them, wherever play was pressed (`nextFrame`).
    static func nextFrame(_ state: LoopState) -> Int {
        if let only = state.only, let first = only.first {
            // Past the last: back to the first, so every round shows all of them.
            return only.first { $0 > state.shown } ?? first
        }
        if state.noForecast {
            if state.shown < state.latestObservation { return state.shown + stepSeconds }
            // Back to where play was pressed, unless that was no earlier than now.
            return state.fromStart || state.loopFrom >= state.latestObservation ? state.start : state.loopFrom
        }
        if state.shown >= state.lastStep { return state.fromStart ? state.start : state.now }
        return state.shown + stepSeconds
    }

    /// The step in `only` nearest `t`, the earlier of two as near (`nearestStep`).
    static func nearestStep(_ only: [Int], to t: Int) -> Int? {
        only.reduce(nil as Int?) { best, step in best.map { abs(step - t) < abs($0 - t) ? step : $0 } ?? step }
    }

    // MARK: - The gate (lib/playbackGate.ts)

    /// The longest the step on screen is held for the next one's pictures
    /// (`READY_TIMEOUT_MS`): a few frames of playback, not a stall.
    static let readyTimeout: TimeInterval = 1.5

    /// Whether playback waits for a step's pictures at all: only while they
    /// are being prepared ahead, and not while the map is `moving`, where the
    /// pictures a step needs change with every moment of the move
    /// (`holdsForTiles`).
    static func holdsForTiles(_ mode: PreloadMode, moving: Bool = false) -> Bool {
        !moving && (mode == .all || mode == .ahead)
    }

    /// Whether to move on: the next step is ready, or has been waited for long enough.
    static func shouldAdvance(ready: Bool, waited: TimeInterval, timeout: TimeInterval = readyTimeout) -> Bool {
        ready || waited >= timeout
    }

    /// How much longer the step on screen may be held, having been held `waited` already.
    static func waitLeft(_ waited: TimeInterval, timeout: TimeInterval = readyTimeout) -> TimeInterval {
        max(0, timeout - waited)
    }

    /// The steps playback will show from `from` on, `from` first, in the
    /// order it shows them, until it comes round again or `max` steps: what
    /// to prepare ahead while playing (`playOrder`).
    static func playOrder(from: Int, next: (Int) -> Int, max: Int) -> [Int] {
        var order = [from]
        var seen: Set<Int> = [from]
        while order.count < max {
            let step = next(order[order.count - 1])
            guard seen.insert(step).inserted else { break }
            order.append(step)
        }
        return order
    }

    // MARK: - Loading ahead (lib/framePreload.ts)

    /// What to load ahead: every step, the next few after the needle, only
    /// each step's coarse preview, or nothing. The first two load the
    /// previews as well, before anything else.
    enum PreloadMode: String, Sendable {
        case all, ahead, previews, none
    }

    /// How many steps ahead of playback a slow connection loads: about a
    /// second and a half of the loop (`PRELOAD_AHEAD_SLOW`).
    static let aheadOnSlow = 3

    /// Whether to load ahead, and how much (`preloadMode`): once the reader
    /// moves through steps; on a slow or data-saving connection only the next
    /// few while playing, and with a hand on the timeline the previews alone.
    static func preloadMode(setting: Bool, radarShown: Bool, browsing: Bool, playing: Bool, slow: Bool) -> PreloadMode {
        guard setting, radarShown, browsing else { return .none }
        guard slow else { return .all }
        return playing ? .ahead : .previews
    }

    /// The order to load steps in: nearest `from` first, the later of two as
    /// near, since playback and a flick both go forward (`preloadOrder`).
    static func preloadOrder(_ steps: [Int], from: Int) -> [Int] {
        steps.sorted { a, b in
            let (da, db) = (abs(a - from), abs(b - from))
            return da != db ? da < db : a > b
        }
    }
}
