//
//  ConnectionMonitor.swift
//  meteocool
//
//  The native map's connection state and the status pill's word for it
//  (core's `LiveIndicator.svelte`, `lib/connectionState.ts`).
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

    func started() { lock.withLock { inFlight += 1 } }

    func finished(_ record: RequestRecord) {
        lock.withLock {
            inFlight = max(0, inFlight - 1)
            records.append(record)
            if records.count > 2000 { records.removeFirst(records.count - 2000) }
        }
    }

    var snapshot: (records: [RequestRecord], inFlight: Int) { lock.withLock { (records, inFlight) } }

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

/// The pill's state, in core's priority order.
enum PillState: Equatable {
    case offline, catchingUp, degraded, stale, slow, time(Int), demo, live, none
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
    @Published private(set) var degradedReasons: [(name: String, reason: String)] = []
    @Published private(set) var unreachable = false

    private let path = NWPathMonitor()
    private var timer: Timer?
    private var catchUpSince: Date?
    private var constrainedSince: Date?
    /// The radar's freshness, from the player.
    var radarStale: () -> Bool = { false }
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

        var reasons: [(String, String)] = []
        let failing = ConnectionRules.failingEndpoints(records, now: now)
        if !failing.isEmpty {
            reasons.append((CoreStrings.t("chrome.degraded.api_errors"),
                            CoreStrings.t("chrome.degraded.api_errors_reason", ["endpoints": failing.joined(separator: ", ")])))
        }
        if let slow = ConnectionRules.slowResponses(records, now: now) {
            reasons.append((CoreStrings.t("chrome.degraded.slow_responses"),
                            CoreStrings.t("chrome.degraded.slow_responses_reason", ["p95": Int(slow.p95 * 1000), "count": slow.count])))
        }
        let processed = newestProcessed()
        if ConnectionRules.publishStalled(newestProcessed: processed.newest, cadence: processed.cadence, now: Int(now.timeIntervalSince1970)),
           let newest = processed.newest, let cadence = processed.cadence {
            let minutes = (Int(now.timeIntervalSince1970) - newest - cadence) / 60
            reasons.append((CoreStrings.t("chrome.degraded.stale_publish"),
                            CoreStrings.t("chrome.degraded.stale_publish_reason", ["minutes": minutes])))
        }
        degradedReasons = reasons

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
            if since >= ConnectionRules.catchUpMax || (since >= ConnectionRules.catchUpMin && inFlight == 0 && !radarStale()) {
                connection = reasons.isEmpty ? .online : .degraded
                catchUpSince = nil
            }
        default:
            connection = reasons.isEmpty ? .online : .degraded
        }
    }

    /// What the pill shows, given the step on screen.
    func pillState(live: Bool, shownStep: Int?, replay: Bool, radarStale: Bool, hasTimeline: Bool) -> PillState {
        switch connection {
        case .offline: return .offline
        case .catchingUp: return .catchingUp
        case .degraded: return .degraded
        case .online: break
        }
        if radarStale { return .stale }
        if slow { return .slow }
        if !live, let shownStep { return .time(shownStep) }
        if replay { return .demo }
        return hasTimeline ? .live : .none
    }
}
