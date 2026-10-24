//
//  StormDrawing.swift
//  meteocool
//
//  What the map draws for the storms in view, as plain marks in degrees:
//  core's `lib/stormMarks.ts`, `lib/cellGeometry.ts` and `lib/cellPulse.ts`,
//  rule for rule. MapKit only sees the result (`StormMarks`).
//

import Foundation

// No app dependencies here: `scripts/check.sh` compiles this file alone.

/// One mark of a storm (core's `StormMark`).
struct StormMark: Equatable, Sendable {
    enum Kind: String, Sendable {
        case path, link, position, outline, forecast, ellipse
    }

    enum Geometry: Equatable, Sendable {
        case point(LonLat)
        case line([LonLat])
        case polygon([LonLat])
    }

    var kind: Kind
    /// Unique among the marks.
    var id: String
    /// The storm it belongs to; a join belongs to the storm it leads into.
    var storm: String
    /// For a join: the storm it leads out of.
    var fromStorm: String?
    var geometry: Geometry
    var severity: Int
    var hail: Bool
    var meso: Bool
    /// Minutes since the storm was last seen, which fades it.
    var ageMinutes: Double
    /// Still being seen: ringed, and drawn at every zoom.
    var live: Bool
    /// For an ellipse: the moment it is for (ms), its lead over the last
    /// detection, and where to label it.
    var forecastAt: Double?
    var leadMinutes: Double?
    var tip: LonLat?
}

/// Where a live ring goes, and how long its storm has been tracked.
struct StormPing: Equatable, Sendable {
    var storm: String
    var severity: Int
    var coordinates: LonLat
    var historyMinutes: Double
}

/// Every mark for the storms (core's `StormDrawing`).
struct StormDrawingResult: Equatable, Sendable {
    /// Paths, positions, outlines and the forecast; drawn over the joins.
    var marks: [StormMark] = []
    /// The joins, drawn underneath.
    var links: [StormMark] = []
    var pings: [StormPing] = []
}

enum StormDrawing {
    /// How long a track stays active after its last detection (core's `ACTIVE_MINUTES`).
    static let activeMinutes = 20.0
    /// How long an outline keeps describing its storm (`OUTLINE_MAX_MINUTES`).
    static let outlineMaxMinutes = 30.0
    static let kmPerDegreeLat = 111.32
    private static let ellipsePoints = 36

    /// Minutes since `iso`, from `now` (ms).
    static func ageMinutes(_ iso: String, _ now: Double) -> Double {
        (now - StormTime.ms(iso)) / 60_000
    }

    static func clampSeverity(_ severity: Int) -> Int { min(max(severity, 0), 3) }

    /// A storm's path as points, oldest first; one until it moves.
    static func pathOf(_ storm: Storm) -> [LonLat] { storm.properties.path.points }

    /// A storm as it stood at `atMs`, or nil for one not yet born then. One
    /// still going is cut back in proportion: active, merged into nothing.
    static func stormAsOf(_ storm: Storm, _ atMs: Double) -> Storm? {
        let p = storm.properties
        let born = StormTime.ms(p.bornAt)
        let seen = StormTime.ms(p.lastSeen)
        if born > atMs { return nil }
        if seen <= atMs {
            // Ended is decided a while after the last sighting; within it, still going.
            let ended = p.status == "ended" && atMs - seen > activeMinutes * 60_000
            let status = p.status == "ended" && !ended ? "active" : p.status
            if status == p.status { return storm }
            var copy = storm
            copy.properties.status = status
            return copy
        }
        let path = pathOf(storm)
        guard !path.isEmpty else { return storm }
        let fraction = seen > born ? (atMs - born) / (seen - born) : 1
        let kept = Array(path.prefix(max(1, Int((fraction * Double(path.count - 1)).rounded(.down)) + 1)))
        let last = kept[kept.count - 1]
        var copy = storm
        copy.geometry = last
        copy.properties.path = kept.count > 1 ? .line(kept) : .point(last)
        copy.properties.lastSeen = StormTime.iso(atMs)
        copy.properties.status = "active"
        copy.properties.mergedInto = nil
        return copy
    }

    /// Whether a storm is drawn: active, or seen within the active window;
    /// the selected one always.
    static func isDrawn(_ storm: Storm, reference: Double, selected: String?) -> Bool {
        let p = storm.properties
        if p.id == selected { return true }
        return p.status == "active" || ageMinutes(p.lastSeen, reference) <= activeMinutes
    }

    /// The vertex of `path` nearest `point`; the first wins ties.
    static func nearestOn(_ path: [LonLat], _ point: LonLat) -> LonLat {
        let c = cos(point.lat * .pi / 180)
        func away(_ v: LonLat) -> Double { hypot((v.lon - point.lon) * c, v.lat - point.lat) }
        var best = path[0]
        for v in path.dropFirst() where away(v) < away(best) { best = v }
        return best
    }

    /// The forecast to draw: the selected storm's KONRAD3D track's, while
    /// that track is detected and is the storm's primary one.
    static func forecastCell(_ selection: StormSelection?) -> TrackProperties? {
        guard let cell = selection?.cell, cell.active, !cell.forecast.isEmpty else { return nil }
        if let summary = selection?.summary, summary.properties.primaryProduct != konrad3dProduct { return nil }
        return cell
    }

    /// What the selection's marks carry as their `storm`: its id, or
    /// `cell:<code>` for a seed.
    static func selectedMark(_ selection: StormSelection?) -> String? {
        guard let selection else { return nil }
        if let id = selection.id { return id }
        return selection.cell.map { "cell:\($0.code)" }
    }

    /// Every mark for these storms. `now` is the moment drawn (ms), `at` an
    /// earlier frame or nil for the present.
    static func drawStorms(_ storms: [Storm], now: Double, reference: Double, selection: StormSelection?, at: Double?) -> StormDrawingResult {
        let selected = selection?.id
        func asOf(_ storm: Storm) -> Storm? { at.map { stormAsOf(storm, $0) } ?? storm }
        var drawing = storms.compactMap(asOf).filter { !pathOf($0).isEmpty }
        // The selected storm from its own copy, whether or not the answer has it.
        if let summary = selection?.summary, let selected, !drawing.contains(where: { $0.properties.id == selected }),
           let pinned = asOf(summary), !pathOf(pinned).isEmpty {
            drawing.append(pinned)
        }
        drawing = drawing.filter { isDrawn($0, reference: reference, selected: selected) }

        var byId: [String: Storm] = [:]
        for storm in drawing { byId[storm.properties.id] = storm }
        var result = StormDrawingResult()
        func liveOf(_ storm: Storm) -> Bool {
            storm.properties.status == "active" && StormPulse.isLive(ageMinutes(storm.properties.lastSeen, reference))
        }

        for storm in drawing {
            let p = storm.properties
            let target = p.mergedInto.flatMap { byId[$0] }
            // Merged into a storm on the map: that one carries on.
            let taken = p.status == "merged" && target != nil && p.id != selected
            let live = liveOf(storm)
            let severity = clampSeverity(p.severity)
            let age = ageMinutes(p.lastSeen, now)
            func mark(_ kind: StormMark.Kind, _ id: String, _ geometry: StormMark.Geometry) -> StormMark {
                StormMark(kind: kind, id: id, storm: p.id, geometry: geometry, severity: severity, hail: p.hail,
                          meso: p.meso, ageMinutes: age, live: live)
            }
            let path = pathOf(storm)
            if path.count > 1 { result.marks.append(mark(.path, "\(p.id):path", .line(path))) }
            if !taken {
                result.marks.append(mark(.position, p.id, .point(storm.geometry)))
                if live {
                    let history = max(0, (StormTime.ms(p.lastSeen) - StormTime.ms(p.bornAt)) / 60_000)
                    result.pings.append(StormPing(storm: p.id, severity: severity, coordinates: storm.geometry, historyMinutes: history))
                }
                // Only the selected storm's outline is known, and only in the present.
                if p.id == selected, at == nil, let outline = StormSelect.outlineOf(selection) {
                    result.marks.append(mark(.outline, "\(p.id):outline", .polygon(outline)))
                }
            }
            if let target {
                let start = path[path.count - 1]
                let t = target.properties
                result.links.append(StormMark(kind: .link, id: "\(p.id)>\(t.id)", storm: t.id, fromStorm: p.id,
                                              geometry: .line([start, nearestOn(pathOf(target), start)]),
                                              severity: clampSeverity(t.severity), hail: false, meso: false,
                                              ageMinutes: ageMinutes(t.lastSeen, now), live: liveOf(target)))
            }
            // A branch of a split, joined to where its parent was then.
            if let parent = p.splitFrom.flatMap({ byId[$0] }) {
                let start = path[0]
                let then = stormAsOf(parent, StormTime.ms(p.bornAt)) ?? parent
                var link = mark(.link, "\(parent.properties.id)>\(p.id)", .line([nearestOn(pathOf(then), start), start]))
                link.fromStorm = parent.properties.id
                link.hail = false
                link.meso = false
                result.links.append(link)
            }
        }

        // The forecast, for the selected storm alone and only in the present.
        let cell = at == nil ? forecastCell(selection) : nil
        let storm = selected.flatMap { byId[$0] }
        if let cell, let owner = selectedMark(selection) {
            let last = cell.series.last
            let severity = clampSeverity(storm?.properties.severity ?? cell.maxSeverity)
            let age = ageMinutes(cell.lastSeen, now)
            let seen = StormTime.ms(cell.lastSeen)
            for (index, point) in cell.forecast.enumerated() {
                result.marks.append(StormMark(kind: .forecast, id: "\(owner):fc:\(index)", storm: owner,
                                              geometry: .point(LonLat(point.lon, point.lat)), severity: severity,
                                              hail: false, meso: false, ageMinutes: age, live: true))
                guard let major = point.majorKm, major != 0 else { continue }
                let ring = ellipseRing4326(point.lon, point.lat, major, point.minorKm ?? major, point.angleDeg ?? 0)
                let t = StormTime.ms(point.t)
                var ellipse = StormMark(kind: .ellipse, id: "\(owner):el:\(index)", storm: owner, geometry: .polygon(ring),
                                        severity: severity, hail: false, meso: false, ageMinutes: age, live: true)
                ellipse.forecastAt = t
                ellipse.leadMinutes = jsRound((t - seen) / 60_000)
                ellipse.tip = leadingTip(ring, LonLat(last?.lon ?? point.lon, last?.lat ?? point.lat))
                result.marks.append(ellipse)
            }
        }
        return result
    }

    // MARK: - Geometry (core's `lib/cellGeometry.ts`)

    /// A ring approximating one uncertainty ellipse: 37 points, the angle a
    /// bearing (clockwise from north).
    static func ellipseRing4326(_ lon: Double, _ lat: Double, _ majorKm: Double, _ minorKm: Double, _ angleDeg: Double) -> [LonLat] {
        let bearing = angleDeg * .pi / 180
        let lonScale = kmPerDegreeLat * cos(lat * .pi / 180)
        return (0 ... ellipsePoints).map { i in
            let t = 2 * Double.pi * Double(i) / Double(ellipsePoints)
            let along = majorKm * cos(t)
            let across = minorKm * sin(t)
            let north = along * cos(bearing) - across * sin(bearing)
            let east = along * sin(bearing) + across * cos(bearing)
            return LonLat(lon + east / lonScale, lat + north / kmPerDegreeLat)
        }
    }

    /// The end of a ring's major axis that points away from `from`.
    static func leadingTip(_ ring: [LonLat], _ from: LonLat) -> LonLat {
        let opposite = ring[(ring.count - 1) / 2]
        return distanceKm(from, ring[0]) >= distanceKm(from, opposite) ? ring[0] : opposite
    }

    static func distanceKm(_ a: LonLat, _ b: LonLat) -> Double {
        let lat = (a.lat + b.lat) / 2 * .pi / 180
        return hypot((b.lon - a.lon) * kmPerDegreeLat * cos(lat), (b.lat - a.lat) * kmPerDegreeLat)
    }

    /// How far apart lead-time labels are, in minutes, at a resolution.
    static func labelStepMinutes(_ resolution: Double) -> Double {
        if resolution > 600 { return 20 }
        if resolution > 300 { return 15 }
        if resolution > 150 { return 10 }
        return 5
    }

    /// What a forecast ring's label says ("+8 min", counted from `now`), or
    /// nil when it carries none. A literal in core, not translated.
    static func leadLabel(_ forecastAt: Double?, _ leadMinutes: Double?, resolution: Double, now: Double) -> String? {
        guard let forecastAt, let leadMinutes, forecastAt.isFinite, leadMinutes.isFinite, leadMinutes > 0 else { return nil }
        guard leadMinutes.truncatingRemainder(dividingBy: labelStepMinutes(resolution)) == 0 else { return nil }
        let remaining = jsRound((forecastAt - now) / 60_000)
        return remaining > 0 ? "+\(Int(remaining)) min" : nil
    }

    /// Whether an outline still says something true about where its storm is.
    static func outlineIsCurrent(_ minutes: Double) -> Bool { minutes <= outlineMaxMinutes }

    /// JavaScript's `Math.round`: halves go up.
    static func jsRound(_ value: Double) -> Double { (value + 0.5).rounded(.down) }

    /// A track's opacity by how long ago it was seen, bucketed as core's
    /// style cache does: 1, 0.6, 0.4, 0.2.
    static func ageOpacity(_ minutes: Double) -> Double {
        let raw: Double = minutes < 20 ? 1 : minutes < 40 ? 0.6 : minutes < 60 ? 0.35 : 0.15
        return jsRound(raw * 10) / 10
    }

    // MARK: - Extents

    /// `[west, south, east, north]` in degrees.
    struct Extent: Equatable, Sendable {
        var west: Double
        var south: Double
        var east: Double
        var north: Double
    }

    /// Grow an extent by a fraction of its own size.
    static func padExtent(_ e: Extent, _ fraction: Double) -> Extent {
        let x = (e.east - e.west) * fraction
        let y = (e.north - e.south) * fraction
        return Extent(west: e.west - x, south: e.south - y, east: e.east + x, north: e.north + y)
    }

    /// An extent the endpoint accepts: on the one world, the right way round.
    static func worldExtent(_ e: Extent) -> Extent {
        func lat(_ v: Double) -> Double { min(90, max(-90, v)) }
        if e.east - e.west >= 360 { return Extent(west: -180, south: lat(e.south), east: 180, north: lat(e.north)) }
        let shift = ((e.west + 180) / 360).rounded(.down) * 360
        if e.east - shift > 180 { return Extent(west: -180, south: lat(e.south), east: 180, north: lat(e.north)) }
        return Extent(west: e.west - shift, south: lat(e.south), east: e.east - shift, north: lat(e.north))
    }

    /// Whether `inner` is entirely inside `outer`.
    static func covers(_ outer: Extent?, _ inner: Extent) -> Bool {
        guard let outer else { return false }
        return outer.west <= inner.west && outer.south <= inner.south && outer.east >= inner.east && outer.north >= inner.north
    }
}

/// The live ring and which rings give way zoomed out: core's `lib/cellPulse.ts`.
enum StormPulse {
    /// How recently a cell must have been detected to count as live.
    static let liveMinutes = 10.0
    static func isLive(_ minutes: Double) -> Bool { minutes <= liveMinutes }

    /// From this zoom on, storms no longer live are drawn.
    static let endedMinZoom = 10.0
    /// Web Mercator's metres per point at zoom 0.
    static let resolutionAtZoom0 = 156_543.033_928_041

    /// OpenLayers' resolution at a zoom.
    static func resolution(zoom: Double) -> Double { resolutionAtZoom0 / pow(2, zoom) }

    static func showsEnded(_ resolution: Double) -> Bool {
        resolution <= resolutionAtZoom0 / pow(2, endedMinZoom) * 1.001
    }

    static let ringRadius = 11.0
    static let ringWidth = 2.0
    static let dash: (Double, Double) = (5, 4)
    static let dashPeriod = 9.0
    static let tickMs = 200.0
    /// The ring's length as the dash pattern measures it: whole periods.
    static let ringPathLength = (2 * Double.pi * ringRadius / dashPeriod).rounded() * dashPeriod
    static let notchDegrees = 360 / ringPathLength

    /// How far round the ring is turned at a moment, degrees clockwise, off
    /// the wall clock so every ring steps together.
    static func ringAngle(_ nowMs: Double) -> Double {
        (nowMs / tickMs).rounded(.down).truncatingRemainder(dividingBy: dashPeriod) * notchDegrees
    }

    /// Where the rings were last laid out.
    struct RingLayout: Equatable {
        var resolution: Double
        var rotation: Double
        var revision: Int
        var selected: String?
    }

    /// Whether the map has only slid since the rings were laid out.
    static func onlySlid(_ laid: RingLayout?, _ now: RingLayout) -> Bool {
        laid == now
    }

    /// From this class a storm keeps its ring however crowded.
    static let severe = 2
    /// How close two rings' centres are, in points, when their strokes touch.
    static let ringOverlapPx = 2 * ringRadius + ringWidth

    struct RingSpot: Equatable {
        var storm: String
        var x: Double
        var y: Double
        var severity: Int
        var historyMinutes: Double
    }

    /// The storms left off the map at this resolution because their ring
    /// would sit on another's: most severe first, then longest tracked.
    static func crowdedOut(_ rings: [RingSpot], resolution: Double, selected: String?) -> Set<String> {
        var out = Set<String>()
        if showsEnded(resolution) { return out }
        let reach = ringOverlapPx * resolution
        let ranked = rings.sorted { a, b in
            let aSelected = a.storm == selected, bSelected = b.storm == selected
            if aSelected != bSelected { return aSelected }
            if a.severity != b.severity { return a.severity > b.severity }
            if a.historyMinutes != b.historyMinutes { return a.historyMinutes > b.historyMinutes }
            return a.storm < b.storm
        }
        var kept: [RingSpot] = []
        for ring in ranked {
            let stays = ring.storm == selected || ring.severity >= severe
            if !stays, kept.contains(where: { hypot($0.x - ring.x, $0.y - ring.y) < reach }) {
                out.insert(ring.storm)
            } else {
                kept.append(ring)
            }
        }
        return out
    }
}
