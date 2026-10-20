//
//  RadarSocket.swift
//  meteocool
//
//  The radar's live channel: core's socket.io connection to `/radar`.
//

import Foundation

/// The backend's nudges, as core receives them (`App.svelte`,
/// `api/events.ts`): one-way socket.io events on the `/radar` namespace.
///
/// Just enough of Engine.IO 4 and Socket.IO 5 over a WebSocket: open,
/// join the namespace, answer pings, read events. Reconnects with backoff
/// while started.
@MainActor
final class RadarSocket {
    /// An event's name and its first argument, as JSON.
    var onEvent: ((String, Data) -> Void)?
    /// After a reconnect: what was missed while away has to be fetched.
    var onReconnect: (() -> Void)?
    /// Whether the namespace is joined: live, rather than polled.
    var onConnection: ((Bool) -> Void)?

    private let namespace = "/radar"
    private var host: URL
    private var task: URLSessionWebSocketTask?
    private var started = false
    private var failures = 0
    private var everConnected = false
    private var watchdog: Timer?
    private var pingDeadline: TimeInterval = 50

    init(host: URL) {
        self.host = host
    }

    func setHost(_ url: URL) {
        guard url != host else { return }
        host = url
        if started { stop(); start() }
    }

    func start() {
        guard !started else { return }
        started = true
        connect()
    }

    func stop() {
        started = false
        watchdog?.invalidate()
        watchdog = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func connect() {
        guard started else { return }
        var components = URLComponents(url: host.appendingPathComponent("socket.io/"), resolvingAgainstBaseURL: false)!
        components.scheme = host.scheme == "http" ? "ws" : "wss"
        components.queryItems = [URLQueryItem(name: "EIO", value: "4"), URLQueryItem(name: "transport", value: "websocket")]
        guard let url = components.url else { return }
        let task = URLSession.shared.webSocketTask(with: url)
        self.task = task
        task.resume()
        receive(on: task)
        resetWatchdog()
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === task else { return }
                switch result {
                case .success(.string(let text)):
                    self.handle(text, on: task)
                    self.receive(on: task)
                case .success:
                    self.receive(on: task)
                case .failure:
                    self.dropped()
                }
            }
        }
    }

    private func handle(_ packet: String, on task: URLSessionWebSocketTask) {
        guard let type = packet.first else { return }
        let body = packet.dropFirst()
        switch type {
        case "0":
            // Engine.IO open: how often the server pings. Then join the namespace.
            if let data = body.data(using: .utf8),
               let open = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let interval = open["pingInterval"] as? Double, let timeout = open["pingTimeout"] as? Double {
                pingDeadline = (interval + timeout) / 1000 + 5
            }
            task.send(.string("40\(namespace),")) { _ in }
            resetWatchdog()
        case "2":
            task.send(.string("3")) { _ in }
            resetWatchdog()
        case "1":
            dropped()
        case "4":
            message(body)
        default:
            break
        }
    }

    /// A Socket.IO packet inside an Engine.IO message.
    private func message(_ packet: Substring) {
        guard let type = packet.first else { return }
        var rest = packet.dropFirst()
        if rest.hasPrefix(namespace) {
            rest = rest.dropFirst(namespace.count)
            if rest.first == "," { rest = rest.dropFirst() }
        }
        switch type {
        case "0":
            // Joined.
            failures = 0
            onConnection?(true)
            if everConnected { onReconnect?() }
            everConnected = true
        case "2":
            // An event: optional ack id, then `["name", payload]`.
            let json = rest.drop { $0.isNumber }
            guard let data = json.data(using: .utf8),
                  let array = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [Any],
                  let name = array.first as? String else { return }
            let payload = array.count > 1 ? array[1] : NSNull()
            let encoded = (try? JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed])) ?? Data("null".utf8)
            onEvent?(name, encoded)
        case "4":
            // The namespace refused us; try again later.
            dropped()
        default:
            break
        }
    }

    /// Without a ping for longer than the server promised, the line is dead.
    private func resetWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: pingDeadline, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dropped() }
        }
    }

    private func dropped() {
        onConnection?(false)
        task?.cancel(with: .abnormalClosure, reason: nil)
        task = nil
        watchdog?.invalidate()
        guard started else { return }
        failures += 1
        let delay = min(30, pow(2, Double(min(failures, 5))) / 2)
        watchdog = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.connect() }
        }
    }
}
