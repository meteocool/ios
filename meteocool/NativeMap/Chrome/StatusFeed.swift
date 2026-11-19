//
//  StatusFeed.swift
//  meteocool
//
//  Asking the backend what is late, and handing its answer to the map while
//  it can be trusted (core's `lib/statusFeed.ts`).
//

import Foundation

/// `GET /v3/status`, asked on start, on the socket's `status`, on waking and
/// on a timer: every few minutes, every minute while the socket is down. An
/// answer is trusted for `StatusRules.trust` with no newer one; past that, or
/// with none (a backend without the route answers 404), `trusted` is nil and
/// the map's own rules judge. Nil in a past window too, which has no now.
@MainActor
final class StatusFeed {
    /// How often with the socket up: a little inside the trust window, so the
    /// next answer is in before the last one runs out (`POLL_MS`).
    static let poll: TimeInterval = StatusRules.trust - 30
    /// How often while the socket is down, when no `status` can come (`SOCKET_DOWN_POLL_MS`).
    static let socketDownPoll: TimeInterval = 60

    /// The answer to go by, and when it came; nil when the map's own rules judge.
    private(set) var trusted: (status: ServiceStatus, receivedAt: Date)?
    /// Called whenever `trusted` changes.
    var onChange: (() -> Void)?
    /// A request through the map, which the connection's log sees.
    var fetch: ((URL, @escaping @MainActor (Data?, Int?) -> Void) -> Void)?
    var url: URL
    /// A past window is open: nothing is trusted.
    var past = false { didSet { if past != oldValue { publish() } } }

    private var latest: (status: ServiceStatus, receivedAt: Date)?
    private var asking = false
    private var timer: Timer?
    private var expiry: Timer?
    private var socketDown = false

    init(url: URL) {
        self.url = url
    }

    /// Asks now, unless already asking. A 404 forgets any earlier answer: the
    /// backend has no status to give. Any other failure keeps it until it
    /// runs out, and is the API's failure to report.
    func refresh() {
        guard !asking, let fetch else { return }
        asking = true
        #if DEBUG
        // A status of the UI test's own (`MC_STATUS`: the answer's JSON, or
        // "404" for a backend without the route).
        if let fixture = ProcessInfo.processInfo.environment["MC_STATUS"] {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.answered(fixture == "404" ? nil : Data(fixture.utf8), status: fixture == "404" ? 404 : 200) }
            }
            return
        }
        #endif
        fetch(url) { [weak self] data, status in self?.answered(data, status: status) }
    }

    private func answered(_ data: Data?, status: Int?) {
        asking = false
        if let status = data.flatMap(ServiceStatus.decode) {
            latest = (status, Date())
        } else if status == 404 {
            latest = nil
        }
        publish()
    }

    /// Starts asking: now, and on the timer for the socket as it is.
    func start(socketDown: Bool) {
        self.socketDown = socketDown
        refresh()
        schedule()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        expiry?.invalidate()
        expiry = nil
    }

    /// The socket went or came back: the timer follows it.
    func socketChanged(down: Bool) {
        guard down != socketDown else { return }
        socketDown = down
        if timer != nil { schedule() }
    }

    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: socketDown ? Self.socketDownPoll : Self.poll, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Hands the newest answer to the map while it is trusted and the map is
    /// live, and takes it back when it runs out.
    private func publish() {
        let now = Date()
        let usable = latest.flatMap { StatusRules.trusted(receivedAt: $0.receivedAt.timeIntervalSince1970, now: now.timeIntervalSince1970)
            && !past ? $0 : nil }
        let changed = usable?.status != trusted?.status || usable?.receivedAt != trusted?.receivedAt
        trusted = usable
        expiry?.invalidate()
        expiry = nil
        if let usable {
            let left = usable.receivedAt.addingTimeInterval(StatusRules.trust).timeIntervalSince(now)
            expiry = Timer.scheduledTimer(withTimeInterval: max(0, left), repeats: false) { [weak self] _ in
                Task { @MainActor in self?.publish() }
            }
        }
        if changed { onChange?() }
    }
}
