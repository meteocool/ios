//
//  StormRules.swift
//  meteocool
//
//  The storm panel's words and numbers: core's `lib/cellMetrics.ts`,
//  `cellStatus.ts`, `stormStatus.ts`, `cellRecency.ts`, `cellPlacement.ts`,
//  `cellLineage.ts`, `timeTicks.ts`, `swipeAway.ts` (the maths) and the
//  history charts' scale from `StormDetails.svelte`, rule for rule.
//

import Foundation

// No app dependencies here: `scripts/check.sh` compiles this file alone.

/// core's `t(key, {values})`: `CoreStrings.t` in the app, a catalogue or a
/// stub in the checks.
typealias StormTranslate = (String, [String: Any]) -> String

enum StormRules {
    // MARK: - Durations and readings (core's `lib/cellMetrics.ts`)

    static let bandNames = ["weak", "moderate", "strong", "extreme"]

    /// Minutes up to an hour, then hours: "59 min", "1 h", "2 h 7 min".
    static func duration(_ minutes: Double, _ t: StormTranslate) -> String {
        if minutes < 60 { return t("storm.duration.min", ["m": Int(StormDrawing.jsRound(minutes))]) }
        let hours = Int((minutes / 60).rounded(.down))
        let rest = Int(StormDrawing.jsRound(minutes.truncatingRemainder(dividingBy: 60)))
        return rest != 0 ? t("storm.duration.h_min", ["h": hours, "m": rest]) : t("storm.duration.h", ["h": hours])
    }

    struct Metric {
        let key: String
        /// The three cut points between the four bands.
        let cuts: [Double]
        /// What the meter's track spans.
        let domain: (Double, Double)
        let unit: String
        let digits: Int
    }

    static let metrics: [String: Metric] = [
        "peak": Metric(key: "peak", cuts: [45, 55, 60], domain: (20, 68), unit: "dBZ", digits: 1),
        "echoTop": Metric(key: "echoTop", cuts: [7, 10, 12.5], domain: (2, 15), unit: "km", digits: 1),
        "vil": Metric(key: "vil", cuts: [10, 25, 40], domain: (0, 55), unit: "kg/m²", digits: 1),
        "speed": Metric(key: "speed", cuts: [30, 55, 75], domain: (0, 95), unit: "km/h", digits: 0),
        "gust": Metric(key: "gust", cuts: [50, 75, 100], domain: (0, 125), unit: "km/h", digits: 0),
        "lightning": Metric(key: "lightning", cuts: [5, 25, 60], domain: (0, 80), unit: "/5 min", digits: 0),
    ]

    /// A reading with its band (0...3), what the band is called, and how far
    /// its meter fills; `fill` nil is a reading with no meter.
    struct Reading: Equatable, Identifiable {
        var key: String
        var label: String
        var text: String
        var band: Int?
        var bandName: String?
        var fill: Double?

        var id: String { key }
    }

    /// One reading, or a blank one when the feed did not report the value.
    static func reading(_ key: String, _ value: Double?, _ t: StormTranslate, suffix: String = "") -> Reading {
        let metric = metrics[key]!
        let label = t("storm.reading.\(metric.key)", [:])
        guard let value, value.isFinite else {
            return Reading(key: key, label: label, text: "–", band: nil, bandName: nil, fill: 0)
        }
        let band = metric.cuts.filter { value >= $0 }.count
        let gap = metric.unit.hasPrefix("/") ? "" : " "
        let fill = min(max((value - metric.domain.0) / (metric.domain.1 - metric.domain.0), 0), 1)
        return Reading(key: key, label: label, text: toFixed(value, metric.digits) + gap + metric.unit + suffix,
                       band: band, bandName: t("storm.band.\(bandNames[band])", [:]), fill: fill)
    }

    /// A KONRAD3D track's readings, in the order they are read.
    static func cellReadings(_ track: TrackProperties, _ t: StormTranslate) -> [Reading] {
        var out = [
            reading("peak", track.maxDbz, t),
            reading("echoTop", track.echoTopMaxM.map { $0 / 1000 }, t),
            reading("vil", track.vilMax, t),
        ]
        if let latest = track.series.last {
            out.append(reading("speed", latest.speedKmh, t, suffix: " " + compass16(latest.headingDeg, t)))
            if let gust = latest.gustKmh, gust != 0 { out.append(reading("gust", gust, t)) }
            if let rate = latest.lightningRate, rate != 0 { out.append(reading("lightning", Double(rate), t)) }
        }
        return out
    }

    static let compass16Points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]

    /// A heading as one of sixteen points, "–" without one.
    static func compass16(_ deg: Double?, _ t: StormTranslate) -> String {
        guard let deg, deg.isFinite else { return "–" }
        let index = Int(StormDrawing.jsRound(deg / 22.5)) % 16
        return t("storm.compass.\(compass16Points[(index + 16) % 16])", [:])
    }

    /// JavaScript's `toFixed`.
    static func toFixed(_ value: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", value)
    }

    /// "–" for nothing, else `toFixed`.
    static func round(_ value: Double?, _ digits: Int = 0) -> String {
        value.map { toFixed($0, digits) } ?? "–"
    }

    /// "no new data" as a value on its own: the first letter upper-cased.
    static func sentence(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    // MARK: - Status (core's `lib/stormStatus.ts`, `lib/cellStatus.ts`)

    /// Past this, an active storm is reported stale.
    static let staleMinutes = 15.0

    enum StatusKind: String {
        case live, stale, superseded, ended, merged
    }

    static func stormStatus(_ status: String, ageMinutes: Double) -> StatusKind {
        if status == "merged" { return .merged }
        if status == "ended" { return .ended }
        return ageMinutes >= staleMinutes ? .stale : .live
    }

    static func cellStatus(active: Bool, childCodes: [String], ageMinutes: Double) -> StatusKind {
        if !active { return childCodes.isEmpty ? .ended : .superseded }
        return ageMinutes >= staleMinutes ? .stale : .live
    }

    static func statusLabel(_ kind: StatusKind, _ t: StormTranslate) -> String {
        t("storm.status.\(kind.rawValue)", [:])
    }

    // MARK: - Recency (core's `lib/cellRecency.ts`)

    static let sameFrameMinutes = 2.5

    struct Recency: Equatable {
        var ageMinutes: Double
        /// Minutes the detection trails the newest radar frame, nil without one.
        var behindMinutes: Double?
    }

    static func cellRecency(lastSeenMs: Double, nowMs: Double, radarFrameMs: Double?) -> Recency {
        Recency(ageMinutes: max(0, (nowMs - lastSeenMs) / 60_000),
                behindMinutes: radarFrameMs.flatMap { $0 != 0 ? ($0 - lastSeenMs) / 60_000 : nil })
    }

    /// The clause about the radar, or nil when there is nothing to say.
    static func radarOffsetLabel(_ behindMinutes: Double?, _ t: StormTranslate) -> String? {
        guard let behindMinutes, abs(behindMinutes) >= sameFrameMinutes else { return nil }
        let minutes = Int(StormDrawing.jsRound(abs(behindMinutes)))
        return t(behindMinutes > 0 ? "storm.radar_offset.behind" : "storm.radar_offset.ahead", ["m": minutes])
    }

    // MARK: - Placement (core's `lib/cellPlacement.ts`)

    enum PlacementStyle { case long, short }

    private static let compass8 = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]

    /// "18 km N of Freising", "N of Freising", "Over Freising", or nil.
    static func placementLabel(_ placement: CellPlacement?, _ t: StormTranslate, style: PlacementStyle = .long) -> String? {
        guard let placement else { return nil }
        let place = placement.place.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !place.isEmpty else { return nil }
        let direction = placement.direction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if direction.isEmpty { return t("cell_place_over", ["place": place]) }
        // An unknown direction is shown as sent rather than dropped.
        let compass = compass8.contains(direction) ? t("compass_\(direction)", [:]) : direction
        if style == .short { return t("cell_place_short", ["direction": compass, "place": place]) }
        return t("cell_place_near", ["distance": Int(StormDrawing.jsRound(placement.distanceKm)), "direction": compass, "place": place])
    }

    // MARK: - Lineage (core's `lib/cellLineage.ts`)

    static let maxFamily = 24

    struct LineageNode: Equatable {
        var code: String
        var severity: Int
        var firstSeen: String
        var lastSeen: String
        var peakDbz: Double?
        var hail: Bool
        var meso: Bool
        var isSelf: Bool
    }

    struct LineageEdge: Equatable {
        var from: String
        var to: String
    }

    struct Lineage: Equatable {
        var nodes: [LineageNode] = []
        var edges: [LineageEdge] = []
    }

    static func relativesOf(_ track: TrackProperties) -> [String] { track.parentCodes + track.childCodes }

    /// The codes reachable from `root` through `known`, breadth first.
    static func reachable(_ known: [String: TrackProperties], _ root: String, limit: Int = maxFamily) -> [String] {
        var seen = Set<String>()
        var order: [String] = []
        var queue = [root]
        var head = 0
        while head < queue.count, order.count < limit {
            let code = queue[head]
            head += 1
            if seen.contains(code) { continue }
            seen.insert(code)
            guard let track = known[code] else { continue }
            order.append(code)
            for other in relativesOf(track) where !seen.contains(other) { queue.append(other) }
        }
        return order
    }

    /// The relatives named by what has been reached but not themselves fetched.
    static func missingRelatives(_ known: [String: TrackProperties], _ root: String) -> [String] {
        var wanted: [String] = []
        var have = Set<String>()
        for code in reachable(known, root) {
            guard let track = known[code] else { continue }
            for other in relativesOf(track) where known[other] == nil && !have.contains(other) {
                have.insert(other)
                wanted.append(other)
            }
        }
        return wanted
    }

    /// The family around `root`, oldest first (the code settles a tie), and
    /// its edges from each child's parents.
    static func buildLineage(_ known: [String: TrackProperties], _ root: String) -> Lineage {
        let codes = reachable(known, root)
        guard codes.count >= 2 else { return Lineage() }
        let inGraph = Set(codes)
        var nodes: [LineageNode] = codes.compactMap { code in
            guard let track = known[code] else { return nil }
            return LineageNode(code: code, severity: min(max(track.maxSeverity, 0), 3), firstSeen: track.firstSeen,
                               lastSeen: track.lastSeen, peakDbz: track.maxDbz, hail: track.hailEver, meso: track.mesoEver,
                               isSelf: code == root)
        }
        nodes.sort { $0.firstSeen != $1.firstSeen ? $0.firstSeen < $1.firstSeen : $0.code < $1.code }
        var edges: [LineageEdge] = []
        var drawn = Set<String>()
        for node in nodes {
            for parent in known[node.code]?.parentCodes ?? [] where inGraph.contains(parent) {
                let key = "\(parent)->\(node.code)"
                if drawn.contains(key) { continue }
                drawn.insert(key)
                edges.append(LineageEdge(from: parent, to: node.code))
            }
        }
        return Lineage(nodes: nodes, edges: edges)
    }

    /// What a node did to get here: `merge`, `split` or "".
    static func nodeRole(_ lineage: Lineage, _ code: String) -> String {
        if lineage.edges.filter({ $0.to == code }).count > 1 { return "merge" }
        if lineage.edges.filter({ $0.from == code }).count > 1 { return "split" }
        return ""
    }

    /// Where each moment sits on the family chart's time axis: elapsed time,
    /// with a floor so nodes never overlap.
    static func axisOffsets(_ times: [Double], minGap: Double, pxPerMs: Double) -> [Double] {
        var offsets: [Double] = []
        for (index, time) in times.enumerated() {
            if index == 0 {
                offsets.append(0)
                continue
            }
            offsets.append(offsets[index - 1] + max(minGap, (time - times[index - 1]) * pxPerMs))
        }
        return offsets
    }

    // MARK: - Family chart layout (core's `CellLineage.svelte`)

    struct FamilyLayout: Equatable {
        struct Node: Equatable {
            var code: String
            var x: Double
            var y: Double
            var severity: Int
            var isSelf: Bool
            var badge: String
            var at: String
            var peak: String
            var place: String
            var label: String
        }

        struct Edge: Equatable {
            var from: (Double, Double)
            var to: (Double, Double)
            var bend: Double

            static func == (a: Edge, b: Edge) -> Bool {
                a.from == b.from && a.to == b.to && a.bend == b.bend
            }
        }

        var width: Double
        var height: Double
        var nodes: [Node]
        var edges: [Edge]
        /// One per distinct first detection, which the axis labels.
        var marks: [(x: Double, label: String)]
        var nowX: Double?

        static func == (a: FamilyLayout, b: FamilyLayout) -> Bool {
            a.width == b.width && a.height == b.height && a.nodes == b.nodes && a.edges == b.edges
                && a.marks.map(\.x) == b.marks.map(\.x) && a.marks.map(\.label) == b.marks.map(\.label) && a.nowX == b.nowX
        }
    }

    static let nodeW = 62.0
    static let nodeH = 30.0
    static let axisH = 18.0
    static let colMin = nodeW + 12
    static let pxPerMinute = 5.0
    static let nowMaxPx = 110.0
    static let laneGap = 10.0

    /// The family laid out left to right: x from the clock (`axisOffsets`),
    /// lanes from a layered layout in place of core's dagre (ranks by the
    /// longest path from a root, ordered by the parents' mean lane, then
    /// first seen and code), so the order is the family's, not the route in.
    static func familyLayout(_ lineage: Lineage, known: [String: TrackProperties], nowMs: Double,
                             clock: (String) -> String, t: StormTranslate) -> FamilyLayout? {
        guard lineage.nodes.count >= 2 else { return nil }
        let codes = lineage.nodes.map(\.code)
        var parents: [String: [String]] = [:]
        for edge in lineage.edges { parents[edge.to, default: []].append(edge.from) }
        // Nodes come oldest first, and an edge always runs from an older or
        // same-minute node, so one pass in that order settles each rank.
        var rank: [String: Int] = [:]
        func rankOf(_ code: String, _ visiting: Set<String>) -> Int {
            if let known = rank[code] { return known }
            var deepest = 0
            for parent in parents[code] ?? [] where !visiting.contains(parent) {
                deepest = max(deepest, rankOf(parent, visiting.union([code])) + 1)
            }
            rank[code] = deepest
            return deepest
        }
        for code in codes { _ = rankOf(code, []) }
        let order = Dictionary(uniqueKeysWithValues: codes.enumerated().map { ($1, $0) })
        let ranks = (rank.values.max() ?? 0) + 1
        var lanes: [[String]] = Array(repeating: [], count: ranks)
        var lane: [String: Double] = [:]
        for r in 0 ..< ranks {
            let members = codes.filter { rank[$0] == r }
            let sorted = members.map { code -> (String, Double) in
                let placed = (parents[code] ?? []).compactMap { lane[$0] }
                return (code, placed.isEmpty ? .infinity : placed.reduce(0, +) / Double(placed.count))
            }.sorted { a, b in
                if a.1 != b.1 { return a.1 < b.1 }
                return order[a.0]! < order[b.0]!
            }.map(\.0)
            lanes[r] = sorted
            for (index, code) in sorted.enumerated() { lane[code] = Double(index) }
        }
        let maxLanes = lanes.map(\.count).max() ?? 1
        let graphHeight = 8 + Double(maxLanes) * nodeH + Double(maxLanes - 1) * laneGap
        var yOf: [String: Double] = [:]
        for members in lanes {
            // Centred against the tallest rank.
            let span = Double(members.count) * nodeH + Double(max(members.count - 1, 0)) * laneGap
            let top = 4 + (graphHeight - 8 - span) / 2
            for (index, code) in members.enumerated() { yOf[code] = top + nodeH / 2 + Double(index) * (nodeH + laneGap) }
        }

        let stamps = Array(Set(lineage.nodes.map { StormTime.ms($0.firstSeen) })).sorted()
        let offsets = axisOffsets(stamps, minGap: colMin, pxPerMs: pxPerMinute / 60_000)
        var colOf: [Double: Double] = [:]
        for (index, stamp) in stamps.enumerated() { colOf[stamp] = offsets[index] + nodeW / 2 + 4 }

        let nodes = lineage.nodes.map { node -> FamilyLayout.Node in
            let role = nodeRole(lineage, node.code)
            let time = clock(node.firstSeen)
            let label = node.peakDbz == nil
                ? t("storm.lineage.node", ["role": t("storm.lineage.role.\(role.isEmpty ? "cell" : role)", [:]), "time": time])
                : t("storm.lineage.node_peak", ["role": t("storm.lineage.role.\(role.isEmpty ? "cell" : role)", [:]), "time": time,
                                                "dbz": Int(StormDrawing.jsRound(node.peakDbz ?? 0))])
            return FamilyLayout.Node(code: node.code, x: colOf[StormTime.ms(node.firstSeen)] ?? 0, y: yOf[node.code] ?? 0,
                                     severity: node.severity, isSelf: node.isSelf,
                                     badge: node.meso ? "↻" : node.hail ? "✦" : "", at: time,
                                     peak: node.peakDbz.map { "\(Int(StormDrawing.jsRound($0))) dBZ" } ?? "",
                                     place: placementLabel(known[node.code]?.placement, t, style: .short) ?? "", label: label)
        }
        let at = Dictionary(uniqueKeysWithValues: nodes.map { ($0.code, $0) })
        let edges = lineage.edges.compactMap { edge -> FamilyLayout.Edge? in
            guard let from = at[edge.from], let to = at[edge.to] else { return nil }
            let x0 = from.x + nodeW / 2, x1 = to.x - nodeW / 2
            return FamilyLayout.Edge(from: (x0, from.y), to: (x1, to.y), bend: max(8, (x1 - x0) / 2))
        }
        let height = graphHeight + axisH
        let marks = stamps.map { (x: colOf[$0] ?? 0, label: clock(StormTime.iso($0))) }
        let lastStamp = stamps[stamps.count - 1]
        let lastX = colOf[lastStamp] ?? 0
        let elapsed = max(0, nowMs - lastStamp) * (pxPerMinute / 60_000)
        let nowX: Double? = elapsed > 1 ? lastX + min(elapsed, nowMaxPx) : nil
        let width = max(offsets[offsets.count - 1] + nodeW + 8, nowX.map { $0 + 12 } ?? 0)
        return FamilyLayout(width: width, height: height, nodes: nodes, edges: edges, marks: marks, nowX: nowX)
    }

    // MARK: - Time ticks (core's `lib/timeTicks.ts`)

    static let stepsMinutes: [Double] = [5, 10, 15, 30, 60, 120, 180, 360, 720]

    /// Ticks across `[from, to]` (ms) on the clock, about `target` of them,
    /// the ends included unless a tick is near.
    static func timeTicks(_ from: Double, _ to: Double, target: Double = 4) -> [Double] {
        guard from.isFinite, to.isFinite, to > from else { return from.isFinite ? [from] : [] }
        let span = (to - from) / 60_000
        let step = (stepsMinutes.first { span / $0 <= target } ?? stepsMinutes[stepsMinutes.count - 1]) * 60_000
        var ticks: [Double] = []
        var t = (from / step).rounded(.up) * step
        while t <= to {
            ticks.append(t)
            t += step
        }
        let gap = step / 2
        if ticks.isEmpty || ticks[0] - from > gap { ticks.insert(from, at: 0) }
        if to - ticks[ticks.count - 1] > gap { ticks.append(to) }
        return ticks.count > 1 ? ticks : [from, to]
    }

    // MARK: - Chart scale (core's `StormDetails.svelte`)

    /// Tick values at 1, 2, 2.5 or 5 times a power of ten.
    static func niceTicks(_ min: Double, _ max: Double, target: Double = 4) -> [Double] {
        let span = max - min != 0 ? max - min : 1
        let rough = span / target
        let magnitude = pow(10, log10(rough).rounded(.down))
        let step = [1, 2, 2.5, 5, 10].map { $0 * magnitude }.first { $0 >= rough } ?? 10 * magnitude
        var ticks: [Double] = []
        var v = (min / step).rounded(.up) * step
        while v <= max + step / 1000 {
            ticks.append(StormDrawing.jsRound(v * 1000) / 1000)
            v += step
        }
        return ticks
    }

    struct Scale {
        var min: Double
        var max: Double
        var ticks: [Double]
        var y0: Double
        var y1: Double

        func at(_ value: Double) -> Double { y0 + (value - min) / (max - min) * (y1 - y0) }
    }

    /// A vertical scale over `values`, padded out to whole ticks; nil with
    /// fewer than two values.
    static func verticalScale(_ values: [Double], y0: Double, y1: Double, target: Double = 4) -> Scale? {
        let real = values.filter(\.isFinite)
        guard real.count >= 2, let low = real.min(), let high = real.max() else { return nil }
        // A flat series still needs a box to sit in.
        let pad = (high - low != 0 ? high - low : Swift.max(abs(high) * 0.1, 1)) * 0.15
        let ticks = niceTicks(low - pad, high + pad, target: target)
        return Scale(min: Swift.min(low - pad, ticks.first ?? low - pad), max: Swift.max(high + pad, ticks.last ?? high + pad),
                     ticks: ticks, y0: y0, y1: y1)
    }

    // MARK: - Swipe (core's `lib/swipeAway.ts`)

    static let swipeSlop = 6.0
    static let swipeCommit = 0.45
    static let swipeDetent = 96.0
    static let swipeGive = 0.7

    enum SwipeAxis { case undecided, x, y }

    static func decideAxis(_ dx: Double, _ dy: Double, slop: Double = swipeSlop) -> SwipeAxis {
        if abs(dx) < slop && abs(dy) < slop { return .undecided }
        return abs(dx) > abs(dy) ? .x : .y
    }

    /// How far aside a panel is pulled for a drag of `dx` (negative is
    /// leftward) that began `from` aside, on an element `width` wide.
    static func pullTo(_ from: Double, _ dx: Double, width: Double) -> Double {
        let pulled = max(0, from - dx)
        return pulled <= swipeDetent ? pulled : min(width, swipeDetent + (pulled - swipeDetent) * swipeGive)
    }

    static func shouldClear(_ dx: Double, width: Double, commit: Double = swipeCommit) -> Bool {
        width > 0 && -dx >= width * commit
    }
}
