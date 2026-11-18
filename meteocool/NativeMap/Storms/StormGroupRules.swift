//
//  StormGroupRules.swift
//  meteocool
//
//  Storms that are one system: the groups `/storms/groups` outlines, and how
//  the map and the panel use them. Core's `lib/stormGroups.ts`, rule for
//  rule.
//

import Foundation

// No app dependencies here: `scripts/check.sh` compiles this file alone.

/// One group's outline, as the map draws it (core's `GroupOutline`).
struct GroupOutline: Equatable, Sendable {
    var id: String
    /// Its polygons, each its rings of `[lon, lat]`, outer first.
    var polygons: [[[LonLat]]]
    /// How many storms it has.
    var storms: Int
    var severity: Int
}

/// A group is two or more storms the backend counts as one system (its
/// storms share `group`), drawn as one quiet outline under their marks
/// (`StormMarks`) and named in a storm's panel by how many storms it has.
enum StormGroupRules {
    /// The statuses that mean a backend has no groups: a 404, or a 422 from
    /// one whose `/storms/{id}` reads `groups` as a storm's id. Both are a map
    /// without outlines, said nowhere and not asked again at once.
    static let absent: Set<Int> = [404, 422]

    /// How long a backend that had no groups is left alone before it is
    /// asked again, ms. Every pan asks for storms, and on a backend from
    /// before groups each would bring a second request that can only fail.
    static let recheckMs = 30 * 60_000.0

    /// Whether to ask for groups now (ms), given when a backend last had
    /// none (nil: never).
    static func asksForGroups(_ absentAt: Double?, now: Double) -> Bool {
        guard let absentAt else { return true }
        return now - absentAt >= recheckMs
    }

    /// A ring that is one: at least four positions, closed or not.
    private static func ringOf(_ ring: GeoCoordinates) -> [LonLat]? {
        guard case .list(let positions) = ring else { return nil }
        let points: [LonLat] = positions.compactMap { position in
            guard case .list(let values) = position, values.count >= 2,
                  case .number(let lon) = values[0], case .number(let lat) = values[1], lon.isFinite, lat.isFinite else { return nil }
            return LonLat(lon, lat)
        }
        return points.count >= 4 ? points : nil
    }

    /// A group's polygons, from a MultiPolygon or, leniently, a Polygon;
    /// none from anything else.
    static func polygonsOf(_ type: String?, _ coordinates: GeoCoordinates?) -> [[[LonLat]]] {
        guard let coordinates, case .list(let list) = coordinates else { return [] }
        let polygons: [GeoCoordinates]
        switch type {
        case "MultiPolygon": polygons = list
        case "Polygon": polygons = [coordinates]
        default: return []
        }
        return polygons.compactMap { polygon in
            guard case .list(let rings) = polygon else { return nil }
            let read = rings.map(ringOf)
            // A polygon whose outer ring is no ring is nothing; a bad hole is left out.
            guard let outer = read.first, outer != nil else { return nil }
            return read.compactMap { $0 }
        }
    }

    /// Whether a group is drawn at `moment` (ms): born by then, seen within
    /// the time a storm stays active of it, and its outline (which is its
    /// newest) no further ahead of it than an outline keeps describing a
    /// storm. In the present that is every group still going; on an earlier
    /// frame, the ones whose outline was close to where they were then.
    static func groupShownAt(_ group: StormSystem, _ moment: Double) -> Bool {
        let born = StormTime.ms(group.properties?.bornAt ?? "")
        let seen = StormTime.ms(group.properties?.lastSeen ?? "")
        guard born.isFinite, seen.isFinite, born <= moment else { return false }
        return moment - seen <= StormDrawing.activeMinutes * 60_000 && seen - moment <= StormDrawing.outlineMaxMinutes * 60_000
    }

    /// The outlines to draw at `moment`: one per group of two or more storms
    /// with an area to outline. The backend lists only those; anything else
    /// is left out rather than drawn wrong.
    static func groupOutlines(_ groups: [StormSystem], _ moment: Double) -> [GroupOutline] {
        groups.compactMap { group in
            guard let p = group.properties, let storms = p.storms, storms.count >= 2, groupShownAt(group, moment),
                  let id = group.id ?? p.id else { return nil }
            let polygons = polygonsOf(group.geometryType, group.coordinates)
            guard !polygons.isEmpty else { return nil }
            return GroupOutline(id: id, polygons: polygons, storms: storms.count, severity: StormDrawing.clampSeverity(p.severity ?? 0))
        }
    }

    /// How many storms the system `storm` belongs to has, for its panel, or
    /// nil when it is in none of two or more. The group's own list when the
    /// groups answer has it; otherwise the storms held that share its id,
    /// which is what a backend's storms say when its groups are out of view
    /// or not yet in.
    static func systemSize(_ storm: Storm?, groups: [StormSystem], held: [Storm]) -> Int? {
        guard let storm, let id = storm.properties.group, !id.isEmpty else { return nil }
        let count: Int
        if let group = groups.first(where: { ($0.id ?? $0.properties?.id) == id }), let storms = group.properties?.storms {
            count = storms.count
        } else {
            count = Set([storm.properties.id] + held.filter { $0.properties.group == id }.map(\.properties.id)).count
        }
        return count >= 2 ? count : nil
    }
}
