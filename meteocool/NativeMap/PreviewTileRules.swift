//
//  PreviewTileRules.swift
//  meteocool
//
//  A coarse picture of every step of the timeline, to draw until the step's
//  own tiles are in: core's `lib/previewTiles.ts`.
//

import Foundation

/// A hand on the timeline crosses a step every few tens of milliseconds, and
/// a step's tiles for the map in view take far longer than that to fetch and
/// put together: the map stood on the step it had until the needle came to
/// rest, and then for as long again as the tiles took. So for each step the
/// map's ground is also kept from tiles a few zooms up (`previewZoom`), one
/// or two a source rather than a dozen, and of each only the part the map is
/// looking at, with a margin for a pan (`cropFor`): every step of the
/// timeline fits where one step's tiles would. The radar moves to a step as
/// soon as these cover it, blurred, and sharpens it tile by tile.
///
/// An extent is four numbers, west, south, east and north (north up, as
/// core has it); MapKit's map points, y down, are turned round by the caller.
///
/// The native map keeps a piece as a picture of the step, its layers
/// already coloured and put together (`RadarCompositor.preparePreviews`):
/// one piece a coarse tile for every layer, where core keeps each source's
/// bytes. One thinned near the pyramid's top (`previewScale`) is drawn
/// smaller, so it keeps a pixel of each block rather than core's strongest
/// value (`cropBytes`).
///
/// No app dependencies here: `scripts/check.sh` compiles this file alone.
enum PreviewTileRules {
    /// West, south, east, north.
    typealias Box = [Double]

    /// How many zooms coarser than the map's tiles the preview is: an eighth of the resolution.
    static let zooms = 3

    /// What a crop's edges snap to, in pixels of the preview: the map can pan
    /// this far in each direction before another crop is needed, and two
    /// views a little apart ask for the same one (`PREVIEW_BLOCK`).
    static let block = 32

    /// How long a step has to have been asked for before the tiles its
    /// preview stands in for are fetched: longer than a hand moving along the
    /// timeline stays on a step, shorter than anyone notices on the step it
    /// stops on (core's `REST_MS`).
    static let rest: TimeInterval = 0.08

    /// The zoom a view drawn from tiles at `z` is previewed from: `zooms` up,
    /// no further than the pyramid's top. Nil where that is no coarser than
    /// the view's own tiles, which are then as few as a preview's would be.
    static func previewZoom(_ z: Int, minZ: Int) -> Int? {
        let zoom = max(minZ, z - zooms)
        return zoom < z ? zoom : nil
    }

    /// How many pixels of a tile at `zoom` go into one of the preview, a
    /// side, for a view drawn from tiles at `z`: 1 where the tile is the full
    /// `zooms` up; near the pyramid's top it is not, and its pixels are
    /// thinned to the same eighth of the view's resolution (`previewScale`).
    static func previewScale(_ z: Int, zoom: Int) -> Int {
        1 << max(0, zooms - (z - zoom))
    }

    /// A rectangle of a tile, in its pixels, from its north-west corner.
    struct Crop: Equatable, Sendable {
        let x: Int
        let y: Int
        let width: Int
        let height: Int

        /// Its name in a key, thinned by `scale` (`cropName`).
        func name(scale: Int = 1) -> String { "\(x),\(y),\(width)x\(height)/\(scale)" }
    }

    /// The part of a tile of `size` pixels a side, covering `tile`, that
    /// `view` needs: every block the view touches and `margin` blocks around
    /// them, kept inside the tile. Nil where the view misses the tile.
    static func cropFor(_ tile: Box, size: Int, view: Box, block: Int = block, margin: Int = 1) -> Crop? {
        let (west, south, east, north) = (tile[0], tile[1], tile[2], tile[3])
        if view[0] >= east || view[2] <= west || view[1] >= north || view[3] <= south { return nil }
        let perUnit = Double(size) / (east - west)
        let blocks = Int((Double(size) / Double(block)).rounded(.up))
        func first(_ pixel: Double) -> Int { max(0, Int((pixel / Double(block)).rounded(.down)) - margin) }
        func last(_ pixel: Double) -> Int { min(blocks, Int((pixel / Double(block)).rounded(.up)) + margin) }
        let x0 = first((view[0] - west) * perUnit), x1 = last((view[2] - west) * perUnit)
        // Rows count down from the tile's northern edge.
        let y0 = first((north - view[3]) * perUnit), y1 = last((north - view[1]) * perUnit)
        let x = x0 * block, y = y0 * block
        return Crop(x: x, y: y, width: min(size, x1 * block) - x, height: min(size, y1 * block) - y)
    }

    /// The ground a crop of a tile covers.
    static func cropExtent(_ tile: Box, size: Int, crop: Crop) -> Box {
        let perPixel = (tile[2] - tile[0]) / Double(size)
        return [
            tile[0] + Double(crop.x) * perPixel,
            tile[3] - Double(crop.y + crop.height) * perPixel,
            tile[0] + Double(crop.x + crop.width) * perPixel,
            tile[3] - Double(crop.y) * perPixel,
        ]
    }

    /// Whether `inner` lies within `outer`, give or take a rounding.
    static func covers(_ outer: Box, _ inner: Box) -> Bool {
        let slack = (outer[2] - outer[0]) * 1e-6
        return inner[0] >= outer[0] - slack && inner[1] >= outer[1] - slack
            && inner[2] <= outer[2] + slack && inner[3] <= outer[3] + slack
    }

    /// Whether two rectangles share any ground: touching is not sharing.
    static func meets(_ a: Box, _ b: Box) -> Bool {
        a[0] < b[2] && a[2] > b[0] && a[1] < b[3] && a[3] > b[1]
    }

    /// What a piece costs besides its pixels.
    static let pieceOverhead = 256
}

/// One coarse tile's part of a step, as kept.
struct PreviewPiece<Image>: Sendable where Image: Sendable {
    /// What tells it apart from any other: the step, the tile and the crop.
    let key: String
    /// The step it is of (a `RadarFrameRef`'s key).
    let frame: String
    let z: Int
    let x: Int
    let y: Int
    /// The ground its pixels cover.
    let covers: PreviewTileRules.Box
    /// Its picture, nil where there is nothing to draw.
    let image: Image?
    /// What it costs to keep, its overhead included.
    let cost: Int
}

/// The pieces of the plan in hand, by step and coarse tile, and those of the
/// plans before it for as long as there is room (core's `PreviewStore`).
///
/// Only what the plan names is taken in (`plan`): a piece put together for a
/// view since left is refused. What an earlier plan named is not let go at
/// once, though: the map moved or zoomed is planned afresh, every piece
/// under another name, and the step on screen may have nothing but its old
/// piece to be drawn from until the new one is in. Those go, the oldest
/// first, only as the plan's own need their room. Past `capacity` a piece of
/// the plan is refused. Not thread-safe: its owner locks round it.
struct PreviewStore<Image: Sendable> {
    /// By key, in the order they were kept.
    private var pieces: [String: PreviewPiece<Image>] = [:]
    private var order: [String] = []
    /// By step, then by `z/x/y`.
    private var frames: [String: [String: String]] = [:]
    private var wanted = Set<String>()
    /// The bytes held now.
    private(set) var bytes = 0
    /// The most bytes held at once.
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
    }

    /// How many pieces are held.
    var count: Int { pieces.count }

    func has(_ key: String) -> Bool { pieces[key] != nil }

    /// The keys taken in from now on; what is held under others stays while there is room.
    mutating func plan(_ keys: some Sequence<String>) {
        wanted = Set(keys)
    }

    /// Whether the plan in hand names `key`.
    func planned(_ key: String) -> Bool { wanted.contains(key) }

    /// Lets every piece go, and takes none in until the next plan.
    mutating func clear() {
        pieces = [:]
        order = []
        frames = [:]
        wanted = []
        bytes = 0
    }

    /// Keeps a piece of the plan; false where it is not kept.
    @discardableResult
    mutating func put(_ piece: PreviewPiece<Image>) -> Bool {
        guard wanted.contains(piece.key) else { return false }
        if pieces[piece.key] != nil { remove(piece.key) }
        // A step has one piece a coarse tile: a newer crop of it replaces the last.
        let at = "\(piece.z)/\(piece.x)/\(piece.y)"
        if let before = frames[piece.frame]?[at] { remove(before) }
        // Room is made of what no plan names any more, the oldest first.
        for key in order where bytes + piece.cost > capacity && !wanted.contains(key) { remove(key) }
        guard bytes + piece.cost <= capacity else { return false }
        frames[piece.frame, default: [:]][at] = piece.key
        pieces[piece.key] = piece
        order.append(piece.key)
        bytes += piece.cost
        return true
    }

    /// The piece of `frame` cut from coarse tile `z`/`x`/`y`; nil where there is none.
    func find(_ frame: String, z: Int, x: Int, y: Int) -> PreviewPiece<Image>? {
        frames[frame]?["\(z)/\(x)/\(y)"].flatMap { pieces[$0] }
    }

    /// The piece of `frame` that covers `ground`, which lies in tile
    /// `z`/`x`/`y`: the nearest of the tiles above it, at most `depth` zooms
    /// up. With `partly`, one that covers only some of the ground will do.
    func covering(_ frame: String, z: Int, x: Int, y: Int, ground: PreviewTileRules.Box, partly: Bool = false,
                  depth: Int = PreviewTileRules.zooms + 2) -> PreviewPiece<Image>? {
        guard let ofFrame = frames[frame] else { return nil }
        var up = 1
        while up <= depth && z - up >= 0 {
            if let key = ofFrame["\(z - up)/\(x >> up)/\(y >> up)"], let piece = pieces[key],
               partly ? PreviewTileRules.meets(piece.covers, ground) : PreviewTileRules.covers(piece.covers, ground) {
                return piece
            }
            up += 1
        }
        return nil
    }

    private mutating func remove(_ key: String) {
        guard let piece = pieces.removeValue(forKey: key) else { return }
        order.removeAll { $0 == key }
        bytes -= piece.cost
        let at = "\(piece.z)/\(piece.x)/\(piece.y)"
        if frames[piece.frame]?[at] == key { frames[piece.frame]?[at] = nil }
        if frames[piece.frame]?.isEmpty == true { frames[piece.frame] = nil }
    }
}
