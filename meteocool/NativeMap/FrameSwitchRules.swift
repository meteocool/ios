//
//  FrameSwitchRules.swift
//  meteocool
//
//  When the radar's picture moves to its next step, and what fills a tile
//  of it still missing: core's `lib/frameSwitch.ts`.
//

import Foundation

/// The radar's picture moves to the step asked for only once every tile of
/// it the view needs is ready (`settled`): the whole picture at once, never
/// two times in it; until then the step before stays whole
/// (`RadarEngine.showStep`). Within the step shown, a tile not yet there (the
/// map panned or zoomed onto new ground) is drawn from a coarser tile of the
/// same step that is (`ancestor`), or from finer ones when zooming out
/// (`children`): of the same time, blurrier for a moment.
///
/// core's crossfade between steps (`fadeWeight`, `blendTexel`) is not here:
/// the native map colours each tile before putting a step together.
///
/// No app dependencies here: `scripts/check.sh` compiles this file alone.
enum FrameSwitchRules {
    /// A tile's place in the pyramid.
    struct Tile: Hashable, Sendable {
        let z: Int
        let x: Int
        let y: Int
    }

    /// How many zooms up a missing tile is drawn from the step's own coarser
    /// tiles where it has no preview: far enough that a loop played at one
    /// zoom still shows, blurred, three or four zooms in (`ANCESTOR_REACH`).
    static let ancestorReach = 4

    /// The nearest coarser tile, at most `depth` zooms up and not above
    /// `minZ`, that `has` says is ready to draw; nil where none is (`ancestorTile`).
    static func ancestor(of tile: Tile, minZ: Int, depth: Int = 2, has: (Tile) -> Bool) -> Tile? {
        var up = 1
        while up <= depth && tile.z - up >= minZ {
            let coarser = Tile(z: tile.z - up, x: tile.x >> up, y: tile.y >> up)
            if has(coarser) { return coarser }
            up += 1
        }
        return nil
    }

    /// The four tiles one zoom finer that `has` says are ready, none past
    /// `maxZ` (`childTiles`).
    static func children(of tile: Tile, maxZ: Int, has: (Tile) -> Bool) -> [Tile] {
        guard tile.z + 1 <= maxZ else { return [] }
        return [(0, 0), (1, 0), (0, 1), (1, 1)]
            .map { Tile(z: tile.z + 1, x: 2 * tile.x + $0.0, y: 2 * tile.y + $0.1) }
            .filter(has)
    }

    /// Whether a step can be switched to: every one of its tiles is settled,
    /// drawn or known to draw nothing (`settled`).
    static func settled<Job>(_ jobs: some Sequence<Job>, ready: (Job) -> Bool) -> Bool {
        jobs.allSatisfy(ready)
    }
}
