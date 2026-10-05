//
//  HiddenFeatures.swift
//  meteocool
//
//  Features the map keeps out of sight until the logo is tapped five times.
//

import Foundation

/// Features that are not ready for everyone, such as the AR storm view's
/// button. Tapping the logo five times in a row shows them; five more taps
/// hide them again.
///
/// Off at every launch: a user who found them by accident does not keep a
/// half-finished feature on the map.
@MainActor
enum HiddenFeatures {
    /// Posted when `unlocked` changes. Views that offer a hidden feature
    /// observe it and show or hide their controls.
    static let didChange = Notification.Name("HiddenFeaturesChanged")

    /// Whether the hidden features are shown.
    private(set) static var unlocked = false

    /// Taps in a row that toggle `unlocked`.
    static let taps = 5
    /// Longest pause between two taps of a row, in seconds.
    static let tapInterval: TimeInterval = 0.8

    private static var count = 0
    private static var lastTap = Date.distantPast

    /// Counts a tap on the logo. Returns true when it completed a row and
    /// toggled `unlocked`.
    @discardableResult
    static func logoTapped(at date: Date = Date()) -> Bool {
        count = date.timeIntervalSince(lastTap) <= tapInterval ? count + 1 : 1
        lastTap = date
        guard count == taps else { return false }
        count = 0
        unlocked.toggle()
        NotificationCenter.default.post(name: didChange, object: nil)
        return true
    }
}
