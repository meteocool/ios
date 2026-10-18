import ActivityKit
import UIKit

// Only APNs registration and HTTP responses are substituted. The manager,
// ActivityKit state, payload serialization and URLSession run unchanged.
@MainActor final class LiveActivityNotificationState {
    var enabled = true
    var token = String(repeating: "a", count: 64)
    func getToken() -> String? { token }
}
@MainActor let SharedNotificationManager = LiveActivityNotificationState()

final class LiveActivityTransport: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var bodies: [Data] = []
    nonisolated(unsafe) static var stored: Data?
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var failNext = false
    nonisolated(unsafe) static var hold = false
    nonisolated(unsafe) static var held: (() -> Void)?

    static var count: Int { lock.withLock { bodies.count } }
    static var saved: Data? { lock.withLock { stored } }
    static func reset() {
        lock.withLock {
            bodies = []
            stored = nil
            status = 200
            failNext = false
            hold = false
            held = nil
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let (status, fail, hold) = Self.lock.withLock {
            Self.bodies.append(body)
            let fail = Self.failNext
            Self.failNext = false
            if !fail && (200..<300).contains(Self.status) { Self.stored = body }
            return (Self.status, fail, Self.hold)
        }
        if fail {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        let reply = { [self] in
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                                httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"success":true}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        if hold { Self.lock.withLock { Self.held = reply } } else { reply() }
    }
    override func stopLoading() {}
}

@main struct LiveActivityManagerCheck {
    @MainActor static func waitFor(_ message: String, seconds: Double = 3, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        precondition(condition(), message)
        // Let URLSession deliver completion to the manager before the next event.
        try await Task.sleep(for: .milliseconds(50))
    }

    @MainActor static func main() async throws {
        setenv("MC_TEST_API_URL", "http://127.0.0.1:18765/", 1)
        precondition(URLProtocol.registerClass(LiveActivityTransport.self))
        defer { URLProtocol.unregisterClass(LiveActivityTransport.self) }

        // The backend recreated the registration; the unchanged token payload
        // must be uploaded again even after the forced resend loses its connection.
        let manager = LiveActivityManager()
        manager.sync()
        try await waitFor("initial token upload") { LiveActivityTransport.count == 1 }
        let original = try JSONSerialization.jsonObject(with: LiveActivityTransport.saved!) as! NSDictionary
        LiveActivityTransport.lock.withLock {
            LiveActivityTransport.stored = nil
            LiveActivityTransport.failNext = true
        }
        manager.sync(force: true)
        try await waitFor("failed forced resend") { LiveActivityTransport.count == 2 }
        try await waitFor("unchanged tokens must retry automatically") { LiveActivityTransport.count == 3 }
        let restored = try JSONSerialization.jsonObject(with: LiveActivityTransport.saved!) as! NSDictionary
        precondition(restored == original, "retry must restore the backend registration")
        manager.sync()
        try await Task.sleep(for: .milliseconds(100))
        precondition(LiveActivityTransport.count == 3, "successful uploads must still be deduplicated")

        // A delayed retry reads current registration state, not the failed request's payload.
        LiveActivityTransport.lock.withLock { LiveActivityTransport.failNext = true }
        manager.sync(force: true)
        try await waitFor("second failed resend") { LiveActivityTransport.count == 4 }
        SharedNotificationManager.token = String(repeating: "b", count: 64)
        try await waitFor("retry with current device token") { LiveActivityTransport.count == 5 }
        let current = try JSONSerialization.jsonObject(with: LiveActivityTransport.saved!) as! [String: Any]
        precondition(current["token"] as? String == SharedNotificationManager.token)
        precondition(current["activityToken"] is NSNull, "retry must not invent a running activity")

        // Re-registration while a request is in flight preserves the forced resend.
        LiveActivityTransport.reset()
        LiveActivityTransport.lock.withLock { LiveActivityTransport.hold = true }
        manager.sync(force: true)
        try await waitFor("held token upload") { LiveActivityTransport.lock.withLock { LiveActivityTransport.held != nil } }
        manager.sync(force: true)
        precondition(LiveActivityTransport.count == 1, "uploads must remain serialized")
        let reply = LiveActivityTransport.lock.withLock {
            LiveActivityTransport.hold = false
            let reply = LiveActivityTransport.held
            LiveActivityTransport.held = nil
            return reply
        }
        reply?()
        try await waitFor("queued forced resend") { LiveActivityTransport.count == 2 }

        // Validation errors and an unregistered device need another external
        // event, not a repeating request with the same rejected payload.
        for status in [404, 422] {
            LiveActivityTransport.reset()
            LiveActivityTransport.lock.withLock { LiveActivityTransport.status = status }
            manager.sync(force: true)
            try await waitFor("rejected token upload") { LiveActivityTransport.count == 1 }
            try await Task.sleep(for: .milliseconds(1200))
            precondition(LiveActivityTransport.count == 1, "HTTP \(status) must not retry automatically")
            LiveActivityTransport.lock.withLock { LiveActivityTransport.status = 200 }
            manager.sync()
            try await waitFor("failed uploads must not remain cached") { LiveActivityTransport.count == 2 }
        }

        // Bound repeated server failures; foreground entry resumes recovery.
        manager.start()
        try await Task.sleep(for: .milliseconds(100))
        LiveActivityTransport.reset()
        LiveActivityTransport.lock.withLock { LiveActivityTransport.status = 503 }
        manager.sync(force: true)
        try await waitFor("three delayed retries", seconds: 9) { LiveActivityTransport.count == 4 }
        try await Task.sleep(for: .milliseconds(8200))
        precondition(LiveActivityTransport.count == 4, "retry attempts must be bounded")
        LiveActivityTransport.lock.withLock { LiveActivityTransport.status = 200 }
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        try await waitFor("foreground must retry pending tokens") { LiveActivityTransport.count == 5 }

        // A changed token gets its own retries after the old payload exhausted them.
        LiveActivityTransport.reset()
        LiveActivityTransport.lock.withLock { LiveActivityTransport.status = 503 }
        manager.sync(force: true)
        try await waitFor("exhaust retries before token change", seconds: 9) { LiveActivityTransport.count == 4 }
        SharedNotificationManager.token = String(repeating: "c", count: 64)
        LiveActivityTransport.lock.withLock {
            LiveActivityTransport.status = 200
            LiveActivityTransport.failNext = true
        }
        manager.sync()
        try await waitFor("changed token's failed upload") { LiveActivityTransport.count == 5 }
        try await waitFor("changed token must retry after the old budget ran out") { LiveActivityTransport.count == 6 }
        let recovered = try JSONSerialization.jsonObject(with: LiveActivityTransport.saved!) as! [String: Any]
        precondition(recovered["token"] as? String == SharedNotificationManager.token)

        // Disabling notifications cancels the pending retry.
        LiveActivityTransport.reset()
        LiveActivityTransport.lock.withLock { LiveActivityTransport.status = 503 }
        manager.sync(force: true)
        try await waitFor("pending retry before disabling") { LiveActivityTransport.count == 1 }
        SharedNotificationManager.enabled = false
        manager.settingChanged()
        try await Task.sleep(for: .milliseconds(1200))
        precondition(LiveActivityTransport.count == 1, "disabled notifications must not keep retrying")
        print("Live Activity token recovery, serialization and retry checks passed")
    }
}
