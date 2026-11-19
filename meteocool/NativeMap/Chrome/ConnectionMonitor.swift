//
//  ConnectionMonitor.swift
//  meteocool
//
//  The native map's connection state and the status pill's word for it
//  (core's `LiveIndicator.svelte`, `lib/connectionState.ts`,
//  `lib/connectionStatus.ts`, `lib/degradedStatus.ts`).
//

import Foundation
import Network

/// Every request the map makes, from any thread: what Connection Details
/// lists and the pill judges by.
final class NetworkLog: @unchecked Sendable {
    static let shared = NetworkLog()
    private let lock = NSLock()
    private var records: [RequestRecord] = []
    private var inFlight = 0
    /// When each radar tile asked for landed or failed, within the window
    /// (core's `lib/tileStatus.ts`).
    private var tiles: [(at: Date, ok: Bool)] = []

    func started() { lock.withLock { inFlight += 1 } }

    func finished(_ record: RequestRecord) {
        lock.withLock {
            inFlight = max(0, inFlight - 1)
            records.append(record)
            if records.count > 2000 { records.removeFirst(records.count - 2000) }
        }
    }

    var snapshot: (records: [RequestRecord], inFlight: Int) { lock.withLock { (records, inFlight) } }

    /// A radar tile asked for has landed or failed (`radarTileOutcome`).
    func tileOutcome(_ ok: Bool, now: Date = Date()) {
        lock.withLock {
            tiles.append((now, ok))
            let cut = now.addingTimeInterval(-ConnectionRules.tileWindow)
            if let first = tiles.firstIndex(where: { $0.at >= cut }) { tiles.removeFirst(first) } else { tiles.removeAll() }
        }
    }

    /// How many radar tiles were asked for in the window, and how many failed (`radarTileCounts`).
    func tileCounts(now: Date = Date()) -> (asked: Int, failed: Int) {
        lock.withLock { ConnectionRules.tileCounts(tiles, now: now) }
    }

    /// The service a URL belongs to, as Connection Details groups them.
    static func service(of url: URL) -> String {
        let path = url.path
        if path.contains("/v3/radar/timeseries") { return "radar_grid" }
        if url.pathExtension == "png", path.contains("/meteo") { return "radar_tiles" }
        if path.contains("lightning") { return "lightning" }
        if path.contains("mesocyclones") { return "mesocyclones" }
        if url.host?.contains("geocoding") == true || url.host?.contains("bigdatacloud") == true { return "geocoder" }
        if url.host?.hasPrefix("map.") == true { return "basemap" }
        return "api_other"
    }
}

/// The pill's state, in core's priority order. `dataDown` and
/// `dataDelayed` are the backend's verdict on what is under the middle of
/// the screen (`StatusRules.headline`).
enum PillState: Equatable {
    case offline, catchingUp, degraded, dataDown, dataDelayed, stale, slow, time(Int), demo, live, none
}

/// A degraded criterion tripped: its id (core's `DegradedReason`), what the
/// diagnostics call it, and why.
struct DegradedReason: Equatable {
    let id: String
    let name: String
    let reason: String
}

/// Watches the path, the requests and the radar's freshness, and says
/// which state the pill shows.
@MainActor
final class ConnectionMonitor: ObservableObject {
    enum Connection: String { case online, offline, degraded, catchingUp = "catching_up" }

    @Published private(set) var connection = Connection.online
    @Published private(set) var offlinePath = false
    @Published private(set) var constrained = false
    @Published private(set) var expensive = false
    @Published private(set) var slow = false
    @Published private(set) var degradedReasons: [DegradedReason] = []
    @Published private(set) var unreachable = false

    private let path = NWPathMonitor()
    private var timer: Timer?
    private var catchUpSince: Date?
    private var constrainedSince: Date?
    /// The map's own "we are behind", which holds catching up: a refetch
    /// clears that, and nothing the map fetches clears the backend's verdict,
    /// so not while the backend's status is trusted.
    var radarStale: () -> Bool = { false }
    /// Whether the backend's status is trusted (`StatusFeed`): it knows what
    /// should have come, so the map does not guess from the cadence.
    var statusTrusted: () -> Bool = { false }
    var newestProcessed: () -> (newest: Int?, cadence: Int?) = { (nil, nil) }

    init() {
        path.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            let constrained = path.isConstrained, expensive = path.isExpensive
            Task { @MainActor in
                self?.offlinePath = offline
                self?.constrained = constrained
                self?.expensive = expensive
                self?.evaluate()
            }
        }
        path.start(queue: DispatchQueue(label: "org.frcy.meteocool.native-map.path"))
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
    }

    deinit {
        path.cancel()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Re-judges everything (core re-evaluates on each signal and every 5 s).
    func evaluate() {
        let now = Date()
        let (records, inFlight) = NetworkLog.shared.snapshot
        // Unreachable: a call got no answer and nothing has answered since.
        let lastAnswer = records.last { $0.status != nil }?.time
        let lastSilence = records.last { $0.status == nil }?.time
        unreachable = lastSilence.map { silence in lastAnswer.map { $0 < silence } ?? true } ?? false

        var reasons: [DegradedReason] = []
        let failing = ConnectionRules.failingEndpoints(records, now: now)
        if !failing.isEmpty {
            reasons.append(DegradedReason(id: "api-errors", name: CoreStrings.t("chrome.degraded.api_errors"),
                                          reason: CoreStrings.t("chrome.degraded.api_errors_reason", ["endpoints": failing.joined(separator: ", ")])))
        }
        if let slow = ConnectionRules.slowResponses(records, now: now) {
            reasons.append(DegradedReason(id: "slow-responses", name: CoreStrings.t("chrome.degraded.slow_responses"),
                                          reason: CoreStrings.t("chrome.degraded.slow_responses_reason",
                                                                ["p95": Int(slow.p95 * 1000), "count": slow.count])))
        }
        let processed = newestProcessed()
        if ConnectionRules.publishStalled(newestProcessed: processed.newest, cadence: processed.cadence, now: Int(now.timeIntervalSince1970),
                                          statusTrusted: statusTrusted()),
           let newest = processed.newest, let cadence = processed.cadence {
            let minutes = (Int(now.timeIntervalSince1970) - newest - cadence) / 60
            reasons.append(DegradedReason(id: "stale-publish", name: CoreStrings.t("chrome.degraded.stale_publish"),
                                          reason: CoreStrings.t("chrome.degraded.stale_publish_reason", ["minutes": minutes])))
        }
        // Clears itself as the failures age out of the window, or as tiles
        // that land outnumber them.
        let tiles = NetworkLog.shared.tileCounts(now: now)
        if ConnectionRules.tilesFailing(asked: tiles.asked, failed: tiles.failed) {
            reasons.append(DegradedReason(id: "tile-errors", name: CoreStrings.t("chrome.degraded.tile_errors"),
                                          reason: CoreStrings.t("chrome.degraded.tile_errors_reason",
                                                                ["failed": tiles.failed, "asked": tiles.asked])))
        }
        if reasons != degradedReasons { degradedReasons = reasons }

        // Slow: Low Data Mode, held five seconds before it shows (`SLOW_SETTLE_MS`).
        if constrained {
            constrainedSince = constrainedSince ?? now
            slow = now.timeIntervalSince(constrainedSince!) >= 5
        } else {
            constrainedSince = nil
            slow = false
        }

        // The state machine (`connectionState.ts`).
        let offline = offlinePath || unreachable
        switch connection {
        case _ where offline:
            connection = .offline
            catchUpSince = nil
        case .offline:
            connection = .catchingUp
            catchUpSince = now
        case .degraded where reasons.isEmpty:
            connection = .catchingUp
            catchUpSince = now
        case .catchingUp:
            let since = now.timeIntervalSince(catchUpSince ?? now)
            if since >= ConnectionRules.catchUpMax || (since >= ConnectionRules.catchUpMin && inFlight == 0 && !(radarStale() && !statusTrusted())) {
                connection = reasons.isEmpty ? .online : .degraded
                catchUpSince = nil
            }
        default:
            connection = reasons.isEmpty ? .online : .degraded
        }
    }

    /// What the pill shows, given the step on screen and the backend's
    /// verdict on what is under the middle of it (nil in a past window, and
    /// without a status to trust).
    func pillState(live: Bool, shownStep: Int?, replay: Bool, radarStale: Bool, hasTimeline: Bool, archive: Bool = false,
                   headline: StatusRules.Headline? = nil) -> PillState {
        switch connection {
        case .offline: return .offline
        case .catchingUp: return .catchingUp
        case .degraded: return .degraded
        case .online: break
        }
        // Radar that is not now any more under the middle of the screen, or
        // anything else late there; a neighbour's sliver at the edge says nothing.
        switch headline {
        case .down: return .dataDown
        case .delayed: return .dataDelayed
        case nil: break
        }
        // A past window is the reader's choice, and the frame's tab says it
        // and is the way out of it (`ArchiveFrame`): it outranks whatever is
        // only about now, and leaves the pill nothing to say.
        if archive { return .none }
        if radarStale { return .stale }
        if slow { return .slow }
        if !live, let shownStep { return .time(shownStep) }
        if replay { return .demo }
        return hasTimeline ? .live : .none
    }
}
