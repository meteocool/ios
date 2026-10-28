//
//  StormSelection.swift
//  meteocool
//
//  The one selection the map makes, a storm, and the rules for what a tap,
//  a walk through the family, a refresh or a fetched detail does to it:
//  core's `lib/stormSelection.ts`, `lib/cellSelection.ts` and
//  `lib/cellTrack.ts`, rule for rule.
//

import Foundation

// No app dependencies here: `scripts/check.sh` compiles this file alone.

/// The products a storm's tracks come from, as `properties.tracks` names them.
let konrad3dProduct = "dwd/konrad3d"
let trackerProduct = "meteocool/tracker"

/// The selected storm (core's `StormSelection`). A tap usually lands on
/// something smaller than a storm (a cell from a link, a relative in the
/// family chart): a seed, with no `id` until its storm is found.
/// Whose tracking a storm is: DWD's KONRAD3D, or meteocool's own tracker.
enum StormSource: String, Sendable {
    case dwd, meteocool
}

struct StormSelection: Equatable, Sendable {
    /// The storm; nil while a seed is being resolved, or when none claims it.
    var id: String?
    /// The storm as the list has it.
    var summary: Storm?
    /// `/storms/{id}`, once fetched.
    var detail: StormDetail?
    /// The KONRAD3D track shown: the storm's primary one, or a relative walked to.
    var cell: TrackProperties?
    /// A box of sky: the storm's patch's, picked from `/cells/volumes`.
    var volume: RadarVolume?
}

enum StormSelect {
    /// A storm tapped on the map, or found for a seed (`fromStorm`).
    static func fromStorm(_ storm: Storm) -> StormSelection {
        StormSelection(id: storm.properties.id, summary: storm)
    }

    /// A storm named by id alone: a link, or a merge followed in the panel;
    /// its list copy where one is held (`byId`).
    static func byId(_ id: String, held: [Storm] = []) -> StormSelection {
        if let storm = held.first(where: { $0.properties.id == id }) { return fromStorm(storm) }
        return StormSelection(id: id)
    }

    /// Whether the selected storm claims this KONRAD3D code, as far as is known.
    static func claimsCell(_ selection: StormSelection, _ code: String) -> Bool {
        if selection.cell?.code == code { return true }
        if selection.summary?.properties.tracks.contains(where: { $0.track == code }) == true { return true }
        if selection.detail?.konrad3d.contains(where: { $0.code == code }) == true { return true }
        return selection.detail?.storm.properties.tracks.contains(where: { $0.track == code }) == true
    }

    /// The features of every tracker track a storm's detail claims.
    static func trackerFeatures(_ detail: StormDetail) -> [TrackerFeature] {
        detail.tracks.flatMap(\.features)
    }

    /// Whether a feature is the storm's: one of its tracks' features, or the
    /// patch one of its cores sits in.
    static func holdsFeature(_ selection: StormSelection, _ feature: String) -> Bool {
        guard let detail = selection.detail else { return false }
        return trackerFeatures(detail).contains { $0.id == feature || $0.parent == feature }
    }

    /// A KONRAD3D cell selected: walked to in the family chart, or named by a
    /// link. One the open storm claims stays in that storm; any other is a seed.
    static func withCell(_ current: StormSelection?, _ cell: TrackProperties) -> StormSelection {
        if var current, current.id != nil, claimsCell(current, cell.code) {
            current.cell = withKnownVolume(cell, current.cell)
            return current
        }
        if var current, current.id == nil, current.cell?.code == cell.code {
            current.cell = withKnownVolume(cell, current.cell)
            return current
        }
        return StormSelection(cell: cell)
    }

    /// A radar volume selected.
    static func withVolume(_ current: StormSelection?, _ volume: RadarVolume) -> StormSelection {
        if var current, current.id != nil, let feature = volume.feature, holdsFeature(current, feature) {
            current.volume = volume
            return current
        }
        return StormSelection(volume: volume)
    }

    /// The storm's list copy: a seed's answer, or a newer copy of the open
    /// storm. A seed keeps what it was opened on.
    static func withStorm(_ current: StormSelection?, _ storm: Storm) -> StormSelection {
        let id = storm.properties.id
        if var current, current.id == id || current.id == nil {
            if current.detail?.storm.id != id { current.detail = nil }
            current.id = id
            current.summary = storm
            return current
        }
        return fromStorm(storm)
    }

    /// The KONRAD3D track to show for a storm: its primary track where that
    /// is KONRAD3D's, else the most recently seen one it claims.
    static func primaryCell(_ detail: StormDetail) -> TrackProperties? {
        let cells = detail.konrad3d
        guard var newest = cells.first else { return nil }
        let p = detail.storm.properties
        if p.primaryProduct == konrad3dProduct, let track = p.primaryTrack,
           let primary = cells.first(where: { $0.code == track }) {
            return primary
        }
        for cell in cells.dropFirst() where cell.lastSeen > newest.lastSeen { newest = cell }
        return newest
    }

    /// The fetched storm, for the storm it was fetched for. The cell shown is
    /// kept if the storm claims it, refreshed from the detail's copy.
    static func withDetail(_ current: StormSelection?, _ detail: StormDetail) -> StormSelection? {
        guard var current, current.id == detail.storm.id else { return current }
        let cells = detail.konrad3d
        let shown = current.cell.flatMap { open in cells.first { $0.code == open.code } }
        let cell: TrackProperties?
        if let shown {
            cell = withKnownVolume(shown, current.cell)
        } else if let open = current.cell, claimsCell(current, open.code) {
            cell = open
        } else {
            cell = primaryCell(detail)
        }
        current.summary = detail.storm
        current.detail = detail
        current.cell = cell
        return current
    }

    enum Lookup: Equatable {
        case cell(String)
        case feature(String)
    }

    /// What a seed is looked up by, or nil when the selection is not a seed.
    static func lookupOf(_ selection: StormSelection?) -> Lookup? {
        guard let selection, selection.id == nil else { return nil }
        if let cell = selection.cell { return .cell(cell.code) }
        if let feature = selection.volume?.feature { return .feature(feature) }
        return nil
    }

    /// The selection as one comparable string: the storm once known, else the seed.
    static func selectionKey(_ selection: StormSelection?) -> String {
        guard let selection else { return "" }
        if let id = selection.id { return "storm:\(id)" }
        if let cell = selection.cell { return "cell:\(cell.code)" }
        if let volume = selection.volume { return "cloud:\(volume.path)" }
        return ""
    }

    /// Whether the selection had appeared by `atMs`: the storm born, or a
    /// seed's cell first seen. A box of sky alone: false.
    static func existedBy(_ selection: StormSelection, _ atMs: Double) -> Bool {
        guard let since = selection.summary?.properties.bornAt ?? selection.cell?.firstSeen else { return false }
        return StormTime.ms(since) <= atMs
    }

    /// Whether going from one selection to the other only found the storm a
    /// seed belongs to: not a new selection.
    static func isResolution(_ from: StormSelection?, _ to: StormSelection?) -> Bool {
        guard let from, let to, from.id == nil, to.id != nil else { return false }
        if let cell = from.cell { return to.cell?.code == cell.code }
        if let volume = from.volume { return to.volume?.path == volume.path }
        return false
    }

    /// Whether the storm's severity is DWD's class, which may be named.
    static func knowsSeverity(_ selection: StormSelection) -> Bool {
        selection.cell != nil || selection.summary?.properties.primaryProduct == konrad3dProduct
    }

    /// The storm's severity class, 0...3, or nil.
    static func severityOf(_ selection: StormSelection) -> Int? {
        guard let value = selection.summary?.properties.severity ?? selection.cell?.maxSeverity else { return nil }
        return min(max(value, 0), 3)
    }

    /// Where the storm is now: its centroid, else its cell's newest step, else its box.
    static func positionOf(_ selection: StormSelection) -> LonLat? {
        if let centroid = selection.summary?.geometry { return centroid }
        if let last = selection.cell?.series.last { return LonLat(last.lon, last.lat) }
        if let volume = selection.volume { return LonLat(volume.lon, volume.lat) }
        return nil
    }

    /// KONRAD3D's product name, as a track claims it.
    static let konrad3d = "dwd/konrad3d"

    /// Whose tracking a product is.
    static func source(ofProduct product: String?) -> StormSource {
        product == konrad3d ? .dwd : .meteocool
    }

    /// A storm's source, by its primary track: the one whose attributes it shows.
    static func source(_ storm: Storm) -> StormSource {
        source(ofProduct: storm.properties.primaryProduct)
    }

    /// Every source behind the selection, the one its readings are from
    /// first (core's `sourcesOf`). A storm both track names both; a
    /// meteocool storm with a KONRAD3D track shows that track's readings, so
    /// DWD leads there. A seed cell is DWD's alone, a box of sky meteocool's.
    static func sourcesOf(_ selection: StormSelection) -> [StormSource] {
        let tracks = selection.detail?.storm.properties.tracks ?? selection.summary?.properties.tracks ?? []
        var named = Set(tracks.map { source(ofProduct: $0.product) })
        if let summary = selection.summary { named.insert(source(summary)) }
        if selection.cell != nil { named.insert(.dwd) }
        if named.isEmpty && selection.volume != nil { named.insert(.meteocool) }
        let lead: StormSource? = selection.cell != nil ? .dwd : selection.summary.map(source)
        return named.sorted { a, b in a == lead ? b != lead : (b == lead ? false : a.rawValue < b.rawValue) }
    }

    /// How fast and which way the storm is going, in metres per second: its
    /// newest step's, else the storm's own (core's `motionOf`).
    static func motionOf(_ selection: StormSelection) -> (speedMs: Double, headingDeg: Double)? {
        let last = selection.cell?.series.last
        guard let speed = last?.speedKmh ?? selection.summary?.properties.speedKmh,
              let heading = last?.headingDeg ?? selection.summary?.properties.headingDeg else { return nil }
        return (speed / 3.6, heading)
    }

    /// Which way the storm is going: the KONRAD3D track's newest heading,
    /// else the storm's own.
    static func headingOf(_ selection: StormSelection) -> Double? {
        selection.cell?.series.last?.headingDeg ?? selection.summary?.properties.headingDeg
    }

    /// The tracker track whose history to show: the storm's primary one, else
    /// the most recently seen it claims.
    static func primaryTrackerTrack(_ detail: StormDetail) -> TrackerTrack? {
        guard var newest = detail.tracks.first else { return nil }
        if let primary = detail.tracks.first(where: { $0.id == detail.storm.properties.primaryTrack }) { return primary }
        for track in detail.tracks.dropFirst() where track.lastSeen > newest.lastSeen { newest = track }
        return newest
    }

    /// The patches the storm's newest features are or sit in: what its
    /// radar volumes name.
    static func newestPatches(_ selection: StormSelection) -> [String] {
        guard let detail = selection.detail else { return [] }
        let features = trackerFeatures(detail)
        guard !features.isEmpty else { return [] }
        let newest = features.reduce("") { $1.validAt > $0 ? $1.validAt : $0 }
        var seen = Set<String>()
        var out: [String] = []
        for feature in features where feature.validAt == newest {
            guard let id = feature.kind == "patch" ? feature.id : feature.parent, !id.isEmpty, !seen.contains(id) else { continue }
            seen.insert(id)
            out.append(id)
        }
        return out
    }

    /// The radar volume to cut the storm open by: cut from one of its newest
    /// patches, nearest its centroid.
    static func volumeOfStorm(_ volumes: [RadarVolume], _ selection: StormSelection) -> RadarVolume? {
        let patches = Set(newestPatches(selection))
        guard !patches.isEmpty else { return nil }
        let own = volumes.filter { !$0.coarse && $0.feature.map(patches.contains) == true }
        guard var best = own.first else { return nil }
        guard let at = positionOf(selection) else { return best }
        func away(_ volume: RadarVolume) -> Double {
            hypot((volume.lon - at.lon) * cos(at.lat * .pi / 180), volume.lat - at.lat)
        }
        for volume in own.dropFirst() where away(volume) < away(best) { best = volume }
        return best
    }

    /// One step of a storm's history from meteocool's tracker.
    struct StormStep: Equatable {
        var t: String
        var peakDbz: Double?
        var areaKm2: Double?
    }

    /// The primary tracker track's features, one per frame (the highest
    /// peak), oldest first.
    static func trackerSeries(_ detail: StormDetail) -> [StormStep] {
        guard let track = primaryTrackerTrack(detail) else { return [] }
        var byFrame: [String: StormStep] = [:]
        var order: [String] = []
        for feature in track.features {
            if let known = byFrame[feature.validAt] {
                if feature.peakDbz > (known.peakDbz ?? -.infinity) {
                    byFrame[feature.validAt] = StormStep(t: feature.validAt, peakDbz: feature.peakDbz, areaKm2: feature.areaKm2)
                }
            } else {
                byFrame[feature.validAt] = StormStep(t: feature.validAt, peakDbz: feature.peakDbz, areaKm2: feature.areaKm2)
                order.append(feature.validAt)
            }
        }
        return order.compactMap { byFrame[$0] }.sorted { $0.t < $1.t }
    }

    /// The storms among those held that merged into this one.
    static func mergedInto(_ storms: [Storm], _ id: String) -> [Storm] {
        storms.filter { $0.properties.mergedInto == id && $0.properties.id != id }
    }

    /// The selected storm's outline now: its KONRAD3D cell's where that track
    /// is primary, else its newest tracker feature's.
    static func outlineOf(_ selection: StormSelection?) -> [LonLat]? {
        guard let selection else { return nil }
        let primary = selection.summary?.properties.primaryProduct
        if let polygon = selection.cell?.polygon, polygon.count > 2, selection.summary == nil || primary == konrad3dProduct {
            return polygon
        }
        guard let detail = selection.detail, let track = primaryTrackerTrack(detail), var newest = track.features.first else { return nil }
        for feature in track.features.dropFirst() where feature.validAt > newest.validAt { newest = feature }
        guard let ring = newest.outline.first, ring.count > 2 else { return nil }
        return ring
    }

    /// The storm among these that claims a KONRAD3D code.
    static func stormClaiming(_ storms: [Storm], _ code: String) -> Storm? {
        storms.first { $0.properties.tracks.contains { $0.track == code } }
    }

    /// The storms nearest a point, nearest first, at most `count`, within `withinKm`.
    static func nearestStorms(_ storms: [Storm], _ at: LonLat, withinKm: Double, count: Int) -> [Storm] {
        let kmPerLon = 111.32 * cos(at.lat * .pi / 180)
        var unique: [String: Storm] = [:]
        var order: [String] = []
        for storm in storms {
            if unique[storm.properties.id] == nil { order.append(storm.properties.id) }
            unique[storm.properties.id] = storm
        }
        return order.compactMap { unique[$0] }
            .map { storm in (storm, hypot((storm.geometry.lon - at.lon) * kmPerLon, (storm.geometry.lat - at.lat) * 111.32)) }
            .filter { $0.1 <= withinKm }
            .enumerated()
            .sorted { $0.element.1 != $1.element.1 ? $0.element.1 < $1.element.1 : $0.offset < $1.offset }
            .prefix(count)
            .map(\.element.0)
    }

    /// A cell's copy with the volume already known for it, if it came
    /// without one (core's `lib/cellTrack.ts`).
    static func withKnownVolume(_ next: TrackProperties, _ known: TrackProperties?...) -> TrackProperties {
        if next.volume != nil { return next }
        guard let volume = known.first(where: { $0?.code == next.code && $0?.volume != nil })??.volume else { return next }
        var copy = next
        copy.volume = volume
        return copy
    }

    // MARK: - Taps (core's `lib/cellSelection.ts`)

    /// The marks drawn (`code`) and whether the details are open.
    struct Tapped: Equatable {
        var code: String?
        var details: Bool

        static let none = Tapped(code: nil, details: false)
    }

    /// The selection after tapping `tapped` (nil for the background). On a
    /// phone (`twoStage`) the first tap only draws; the second opens.
    static func nextSelection(_ current: Tapped, _ tapped: String?, twoStage: Bool) -> Tapped {
        guard let tapped else { return .none }
        if !twoStage { return Tapped(code: tapped, details: true) }
        if tapped == current.code { return Tapped(code: tapped, details: true) }
        return Tapped(code: tapped, details: false)
    }

    /// The selection after the panel's close: on a phone back to the marks,
    /// elsewhere nothing.
    static func afterClose(_ current: Tapped, twoStage: Bool) -> Tapped {
        twoStage ? Tapped(code: current.code, details: false) : .none
    }
}
