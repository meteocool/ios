//
//  ConnectionRules.swift
//  meteocool
//
//  When core's status pill says the backend is degraded, the radar out of
//  date, or the connection slow (`lib/degraded.ts`, `degradedStatus.ts`,
//  `tileStatus.ts`, `updateCadence.ts`, `connectionState.ts`, `freshness.ts`),
//  checked as core's `degraded.test.ts` and `tileErrors.test.ts` check them.
//

import Foundation

/// One request the map made, for the pill and Connection Details.
struct RequestRecord: Sendable {
    let service: String
    let endpoint: String
    let time: Date
    /// HTTP status, nil when no answer came at all.
    let status: Int?
    let duration: TimeInterval
    let bytes: Int
    let cached: Bool
    /// Answered without a body worth having but not an error (a 404 from an
    /// optional endpoint: "absent").
    var absent: Bool { status == 404 }
    var failed: Bool { status.map { $0 >= 500 || ($0 >= 400 && $0 != 404) } ?? true }
}

/// core's rules, free of the app so they can be checked.
///
/// No app dependencies here: `scripts/check.sh` compiles this file alone.
enum ConnectionRules {
    /// A failure counts for this long (`DEGRADED_TTL_MS`).
    static let failureTTL: TimeInterval = 300
    /// Slow: this p95 of `/v3/` answers (`SLOW_P95_MS`)…
    static let slowP95: TimeInterval = 4
    /// …over at least this many answers (`SLOW_MIN_SAMPLES`)…
    static let slowMinSamples = 5
    /// …in this window (`window`).
    static let latencyWindow: TimeInterval = 120
    /// Answers before the newest run of this many quick ones are forgotten (`QUICK_RUN`).
    static let quickRun = 3
    /// A frame this long past its expected time means the publisher stalled (`PUBLISH_OVERDUE_S`).
    static let publishOverdue = 300
    /// Gaps longer than this are outages, not the cadence (`MAX_GAP_S`).
    static let maxGap = 1800
    /// The cadence needs this many gaps (`MIN_INTERVALS`).
    static let minIntervals = 3
    /// Without a learned cadence, frames come every five minutes (`ASSUMED_PERIOD_S`).
    static let assumedPeriod = 300
    /// The radar is out of date this long after its period (`OUTDATED_GRACE_S`).
    static let outdatedGrace = 60
    /// Catching up lasts at least this long, at most the other (`CATCH_UP_MIN_MS`, `_MAX_MS`).
    static let catchUpMin: TimeInterval = 1.5
    static let catchUpMax: TimeInterval = 30
    /// Radar tiles are judged over this long (`TILE_WINDOW_MS`)…
    static let tileWindow: TimeInterval = 120
    /// …from this many on: fewer is a couple of tiles wearing a percentage's hat (`TILE_MIN_ASKED`)…
    static let tileMinAsked = 10
    /// …and more than this share of them failing leaves holes worth a warning (`TILE_FAILED_SHARE`).
    static let tileFailedShare = 0.25

    /// Our own API and the data service's (the lightning and mesocyclone
    /// caches, cells, storms, stations, sweeps), not tiles or the base map:
    /// what slowness is a claim about (`API_MATCH`), by a request's path.
    static func isBackend(_ path: String) -> Bool {
        path.contains("/v3/") || ["lightning_cache", "mesocyclones", "cells", "storms", "stations", "sweeps"].contains { name in
            path.contains("/\(name)/") || path.contains("/\(name)?") || path.hasSuffix("/\(name)")
        }
    }

    /// How many radar tiles were asked for in the window, and how many of
    /// them failed (`radarTileCounts`): outcomes are when each landed or failed.
    static func tileCounts(_ outcomes: [(at: Date, ok: Bool)], now: Date) -> (asked: Int, failed: Int) {
        let recent = outcomes.filter { $0.at >= now.addingTimeInterval(-tileWindow) }
        return (recent.count, recent.filter { !$0.ok }.count)
    }

    /// More than a quarter of enough radar tiles failing (the `tile-errors` criterion).
    static func tilesFailing(asked: Int, failed: Int) -> Bool {
        asked >= tileMinAsked && Double(failed) / Double(asked) > tileFailedShare
    }

    /// The p-quantile by linear interpolation, of what is given.
    static func quantile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let position = Double(sorted.count - 1) * p
        let lower = Int(position.rounded(.down)), upper = Int(position.rounded(.up))
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }

    /// The `/v3/` answers that count for slowness: the window's, from after
    /// the newest run of quick answers onward (`sinceRecovery`).
    static func latencySamples(_ records: [RequestRecord], now: Date) -> [TimeInterval] {
        let recent = records.filter { isBackend($0.endpoint) && $0.status != nil && now.timeIntervalSince($0.time) <= latencyWindow }
            .map(\.duration)
        var run = 0
        for (i, duration) in recent.enumerated().reversed() {
            run = duration < slowP95 ? run + 1 : 0
            if run >= quickRun { return Array(recent[i...]) }
        }
        return recent
    }

    /// p95 and count when slow enough to say so.
    static func slowResponses(_ records: [RequestRecord], now: Date) -> (p95: TimeInterval, count: Int)? {
        let samples = latencySamples(records, now: now)
        guard samples.count >= slowMinSamples, let p95 = quantile(samples, 0.95), p95 >= slowP95 else { return nil }
        return (p95, samples.count)
    }

    /// The endpoints whose last attempt failed within the TTL.
    static func failingEndpoints(_ records: [RequestRecord], now: Date) -> [String] {
        var last: [String: RequestRecord] = [:]
        for record in records { last[record.endpoint] = record }
        return last.values.filter { $0.failed && now.timeIntervalSince($0.time) < failureTTL }.map(\.endpoint).sorted()
    }

    /// The median gap between frames' build times, ignoring outages; nil
    /// until enough are seen (`updateCadence`).
    static func cadence(processedTimes: [Int]) -> Int? {
        let sorted = Array(Set(processedTimes)).sorted()
        let gaps = zip(sorted.dropFirst(), sorted).map { $0 - $1 }.filter { $0 > 0 && $0 <= maxGap }
        guard gaps.count >= minIntervals else { return nil }
        let ordered = gaps.sorted()
        let mid = ordered.count / 2
        return ordered.count % 2 == 1 ? ordered[mid] : Int((Double(ordered[mid - 1] + ordered[mid]) / 2).rounded())
    }

    /// Whether the publisher has missed its next frame by `publishOverdue`.
    /// Not the map's to judge while the backend's status is trusted: it says
    /// what is late itself.
    static func publishStalled(newestProcessed: Int?, cadence: Int?, now: Int, statusTrusted: Bool = false) -> Bool {
        guard !statusTrusted, let newestProcessed, let cadence else { return false }
        return now - (newestProcessed + cadence) >= publishOverdue
    }

    /// Whether the newest observation is older than a period and the grace
    /// (`isOutdated`).
    static func outdated(newestObservation: Int?, period: Int?, now: Int) -> Bool {
        guard let newestObservation else { return false }
        return now - newestObservation > (period ?? assumedPeriod) + outdatedGrace
    }
}
