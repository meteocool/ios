//
//  AlertHistory.swift
//  meteocool
//
//  The rain alerts this phone received, for the list behind the map's bell,
//  as Better Rain Alarm keeps them. The notification service extension adds
//  each alert as it arrives, before iOS shows it: ng sends every alert with
//  `mutable-content`. The app adds any delivered alert the extension missed
//  when it comes to the front. Kept on the phone only, as JSON in the app
//  group: two weeks, at most 200. The app and the extension may write at
//  once, so every read and write is coordinated.
//
//  Shared by the app and NotificationService; `scripts/check.sh` compiles it
//  alone with `tests/AlertHistoryCheck.swift`.
//

import Foundation
import UserNotifications

/// A rain alert this phone received, as the list of past alerts shows it.
struct ReceivedAlert: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    /// When it arrived.
    let received: Date
    let title: String
    let body: String
    /// The saved place it is about (`place` in the payload), nil for where the phone is.
    let place: String?
    /// The notification request's identifier, to recognise it among the
    /// delivered notifications.
    let request: String
    /// Its thread (`thread-id`), where ng sends one.
    let thread: String?
    /// An alert in new words (`"update": true`), which replaces the last of
    /// its thread rather than adding one.
    var replaces: Bool { replacing ?? false }
    private let replacing: Bool?

    init(request: UNNotificationRequest, received: Date) {
        let content = request.content
        self.init(title: content.title, body: content.body, received: received,
                  place: content.userInfo["place"] as? String,
                  request: request.identifier,
                  thread: content.threadIdentifier.isEmpty ? nil : content.threadIdentifier,
                  replaces: content.userInfo["update"] as? Bool == true)
    }

    init(title: String, body: String, received: Date, place: String? = nil, request: String = UUID().uuidString,
         thread: String? = nil, replaces: Bool = false) {
        id = UUID()
        self.received = received
        self.title = title
        self.body = body
        self.place = place
        self.request = request
        self.thread = thread
        replacing = replaces
    }

    /// Whether `other` is the same alert, seen a second time: by the
    /// notification service extension and among the delivered ones.
    func isSame(as other: ReceivedAlert) -> Bool {
        abs(received.timeIntervalSince(other.received)) < 120
            && (request == other.request || (title == other.title && body == other.body))
    }
}

enum AlertHistory {
    /// As CLAUDE.md's shared state and the targets' entitlements have it.
    static let groupID = "group.org.frcy.app.meteocool"
    static let kept: TimeInterval = 14 * 24 * 3600
    static let limit = 200

    /// The list's file; outside an app group (unsigned builds), the app's own.
    static var file: URL {
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) {
            return container.appendingPathComponent("alerts.json")
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("alerts.json")
    }

    static func load(from file: URL = file) -> [ReceivedAlert] {
        var alerts: [ReceivedAlert] = []
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &error) { url in
            alerts = read(url)
        }
        return alerts
    }

    /// Adds the alerts not in the list yet, newest first, and drops what is
    /// past two weeks or beyond the limit. An update takes the place of the
    /// newest alert of its thread, so a rain kept up to date is one entry.
    static func add(_ new: [ReceivedAlert], now: Date = Date(), to file: URL = file) {
        guard !new.isEmpty else { return }
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forMerging, error: &error) { url in
            write(merged(read(url), adding: new, now: now), to: url)
        }
    }

    /// `add`'s decision, pure: what the list holds after `new` came in.
    static func merged(_ existing: [ReceivedAlert], adding new: [ReceivedAlert], now: Date) -> [ReceivedAlert] {
        var alerts = existing.sorted { $0.received > $1.received }
        for alert in new where !alerts.contains(where: { $0.isSame(as: alert) }) {
            if alert.replaces, let thread = alert.thread,
               let index = alerts.firstIndex(where: { $0.thread == thread }) {
                alerts.remove(at: index)
            }
            alerts.insert(alert, at: 0)
        }
        alerts = alerts
            .filter { now.timeIntervalSince($0.received) < kept }
            .sorted { $0.received > $1.received }
        return Array(alerts.prefix(limit))
    }

    static func clear(_ file: URL = file) {
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forDeleting, error: &error) { url in
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// The alerts by day, newest day and newest alert first, for the list's sections.
    static func days(_ alerts: [ReceivedAlert], calendar: Calendar = .current) -> [(day: Date, alerts: [ReceivedAlert])] {
        let byDay = Dictionary(grouping: alerts) { calendar.startOfDay(for: $0.received) }
        return byDay.keys.sorted(by: >).map { day in (day, byDay[day, default: []].sorted { $0.received > $1.received }) }
    }

    /// How many alerts came since the user last looked.
    static func unseen(_ alerts: [ReceivedAlert], since seen: Date?) -> Int {
        alerts.filter { $0.received > (seen ?? .distantPast) }.count
    }

    private static func read(_ url: URL) -> [ReceivedAlert] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ReceivedAlert].self, from: data)) ?? []
    }

    private static func write(_ alerts: [ReceivedAlert], to url: URL) {
        guard let data = try? JSONEncoder().encode(alerts) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
