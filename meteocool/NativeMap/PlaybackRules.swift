//
//  PlaybackRules.swift
//  meteocool
//
//  When playback moves on, and what is loaded ahead of it: core's
//  `lib/playbackGate.ts` and `lib/framePreload.ts`.
//

import Foundation

/// The player's rules, in steps (unix seconds) as core has them.
///
/// No app dependencies here: `scripts/check.sh` compiles this file alone.
enum PlaybackRules {
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
