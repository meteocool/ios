//
//  RadarPlayer.swift
//  meteocool
//
//  The native map's player: which step is on screen, and playback (core's
//  `NowcastPlayback.svelte` and `lib/playbackLoop.ts`).
//

import Foundation
import UIKit

/// Which step of the timeline is on screen, and playback.
@MainActor
final class RadarPlayer: ObservableObject {
    /// Per frame while playing (core's `FRAME_MS`).
    static let frameInterval: TimeInterval = 0.45
    /// Back on the live frame after this long away (`RETURN_TO_LIVE_AFTER_MS`).
    static let returnToLiveAfter: TimeInterval = 5 * 60
    /// Waiting for a step's pictures at most this long, so a slow tile
    /// cannot stop playback.
    static let maxWait: TimeInterval = 3

    @Published private(set) var timeline = RadarTimeline.empty
    @Published private(set) var index = 0
    @Published private(set) var playing = false
    @Published var palette = "classic"
    /// A finger is on the strip.
    @Published private(set) var grabbed = false
    /// What the view on screen allows: no radar at all, or no forecast
    /// (core's `outOfRadar`, `noForecast`).
    @Published var outOfRadar = false
    @Published var noForecast = false
    /// "Loop From Two Hours Back" (`playbackFromStart`).
    var fromStart = false
    /// With a radar open, the only steps (unix seconds) it has a sweep for:
    /// playback and the needle keep to them, the strip hatches the rest
    /// (core's `only`). nil with none open.
    @Published var only: Set<Int>? {
        didSet {
            guard only != oldValue, let only, !only.isEmpty, let step, !only.contains(step) else { return }
            // A step outside them opens on the newest it has.
            if let newest = timeline.steps.lastIndex(where: { only.contains($0) }) { show(newest) }
        }
    }
    /// Steps whose pictures are ready to show: the strip's preload fill.
    @Published var preloaded = Set<Int>()
    /// The steps are being fetched for a new point, or not yet at all: the
    /// strip shows its skeleton (core's `gridLoading`).
    @Published var loading = true

    /// Called whenever the step on screen changes.
    var onStep: ((Int) -> Void)?
    /// Whether a step's pictures are ready: playing waits for the next one,
    /// so a step comes on screen whole, never tile by tile.
    var isReady: ((Int) -> Bool)?

    /// Parked on the newest observation: stays there as new ones arrive.
    private(set) var followsLive = true
    private var timer: Timer?
    private var waitingSince: Date?
    private var loopFrom: Int?
    private var wasPlaying = false
    private var leftAt: Date?

    var step: Int? { timeline.steps.indices.contains(index) ? timeline.steps[index] : nil }
    var nowIndex: Int? { timeline.now.flatMap { timeline.steps.firstIndex(of: $0) } }
    var lastIndex: Int { timeline.lastPlayable.flatMap { timeline.steps.firstIndex(of: $0) } ?? max(0, timeline.steps.count - 1) }
    /// Where the needle may rest: every published step, or an open radar's.
    var reach: TimelinePhysics.Reach {
        TimelinePhysics.reach(steps: timeline.steps, last: lastIndex, only: only)
    }
    /// On the newest observation: what core calls live. Never in a window.
    var isLive: Bool { timeline.window == nil && step != nil && step == timeline.now }
    /// The past window on the strip, nil live.
    var window: RadarWindow? { timeline.window }

    /// Whether play does anything here (`canPlay`): not outside the radar,
    /// and with no forecast only from the past.
    var canPlay: Bool {
        // With a radar open, anything of its own to move to.
        if let only { return only.contains { $0 != step } }
        // A window plays round its own steps.
        if timeline.window != nil { return !outOfRadar && timeline.steps.count > 1 }
        guard !outOfRadar, let now = nowIndex else { return false }
        return !noForecast || index < now
    }

    func setTimeline(_ next: RadarTimeline) {
        let previous = step
        let wasWindow = timeline.window
        timeline = next
        loading = false
        if let window = next.window {
            // A window opens on its first step, and keeps the step on screen
            // when it is the same window again (a wake, a product).
            followsLive = false
            if wasWindow == window, let previous, let same = next.steps.firstIndex(of: previous) {
                index = same
            } else {
                pause()
                index = 0
            }
        } else if !playing, followsLive || previous == nil || wasWindow != nil, let now = nowIndex {
            index = now
        } else if let previous, let same = next.steps.firstIndex(of: previous) {
            index = min(same, lastIndex)
        } else {
            index = nowIndex ?? 0
        }
        if let step { onStep?(step) }
    }

    /// Moves to step `index` of the strip, as a scrub or a tap does; a seek
    /// while playing pauses.
    func scrub(to newIndex: Int) {
        guard !timeline.steps.isEmpty else { return }
        let reach = self.reach
        let clamped = max(reach.first, min(newIndex, reach.last))
        guard clamped != index else { return }
        if playing, !grabbed { pause() }
        show(clamped)
    }

    func show(time: Int) {
        guard let step = timeline.step(nearest: time), let at = timeline.steps.firstIndex(of: step) else { return }
        pause()
        show(at)
    }

    /// Back to the newest observation, following it; in a window, to its end.
    func showLive() {
        pause()
        if let now = nowIndex { show(now) }
        followsLive = timeline.window == nil
    }

    /// The window was left: the steps on their way are live ones, and the
    /// player follows the newest as soon as they land.
    func leaveWindow() {
        pause()
        followsLive = true
        loading = true
    }

    /// A window was asked for: the strip waits for its steps.
    func awaitWindow() {
        pause()
        followsLive = false
        loading = true
    }

    /// A finger landed on the strip: playback holds until it lifts.
    func grab() {
        grabbed = true
        wasPlaying = playing
        if playing { stopTimer() }
    }

    /// The finger lifted: playback goes on if it was playing and still can.
    func release() {
        grabbed = false
        if wasPlaying, canPlay {
            startTimer(after: Self.frameInterval)
        } else if wasPlaying {
            pause()
        }
        wasPlaying = false
    }

    func togglePlay() {
        playing ? pause() : play()
    }

    func play() {
        guard !timeline.steps.isEmpty, !playing, canPlay else { return }
        playing = true
        followsLive = false
        loopFrom = index
        startTimer(after: 0)
    }

    func pause() {
        stopTimer()
        waitingSince = nil
        playing = false
        followsLive = isLive
    }

    /// The app went to the background: playback stops (`leaveForeground`).
    func leftForeground() {
        pause()
        leftAt = Date()
    }

    /// Back after five minutes or more on a past frame: live again.
    func returnedToForeground() {
        defer { leftAt = nil }
        // A window is the reader's choice, however long they were away.
        guard timeline.window == nil, let leftAt, Date().timeIntervalSince(leftAt) >= Self.returnToLiveAfter, !isLive else { return }
        showLive()
    }

    private func startTimer(after delay: TimeInterval) {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: max(delay, 0.01), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard playing, !grabbed, !timeline.steps.isEmpty else { return }
        let next = nextIndex()
        if let isReady, !isReady(timeline.steps[next]) {
            let since = waitingSince ?? Date()
            waitingSince = since
            if Date().timeIntervalSince(since) < Self.maxWait {
                startTimer(after: 0.1)
                return
            }
        }
        waitingSince = nil
        show(next)
        startTimer(after: Self.frameInterval)
    }

    /// The step after this one while playing (`nextFrame`): through the
    /// forecast and round to now (or two hours back), or, with no forecast
    /// on screen, through the past and back to where play was pressed.
    func nextIndex() -> Int {
        // An open radar's steps alone, round to where play was pressed.
        if let only, !only.isEmpty {
            let mine = timeline.steps.indices.filter { only.contains(timeline.steps[$0]) }
            if let next = mine.first(where: { $0 > index }) { return next }
            if !fromStart, let loopFrom, mine.contains(loopFrom), loopFrom < mine.last! { return loopFrom }
            return mine.first!
        }
        let start = 0
        // A window: through it, and round to its start.
        if timeline.window != nil { return index < lastIndex ? index + 1 : start }
        let gridNow = timeline.steps.firstIndex(of: timeline.gridNow) ?? (nowIndex ?? 0)
        if !noForecast {
            if index < lastIndex { return index + 1 }
            return fromStart ? start : min(gridNow, lastIndex)
        }
        let latest = nowIndex ?? lastIndex
        if index < latest { return index + 1 }
        if fromStart { return start }
        guard let loopFrom, loopFrom < latest else { return start }
        return loopFrom
    }

    private func show(_ newIndex: Int) {
        index = newIndex
        followsLive = newIndex == nowIndex && !playing && timeline.window == nil
        if let step { onStep?(step) }
    }

    /// A step's offset, as core writes it (`formatOffset`): "Now", "+45m",
    /// "-1h30m", counted from the clock's step; in a window, its clock time.
    func offsetLabel(_ step: Int) -> String {
        if let window = timeline.window { return window.label(step) }
        let minutes = Int((Double(step - timeline.gridNow) / 60).rounded())
        if minutes == 0 { return CoreStrings.t("now") }
        let sign = minutes < 0 ? "-" : "+"
        let hours = abs(minutes) / 60, rest = abs(minutes) % 60
        if hours == 0 { return CoreStrings.t("chrome.playback.offset_minutes", ["sign": sign, "minutes": rest]) }
        if rest == 0 { return CoreStrings.t("chrome.playback.offset_hours", ["sign": sign, "hours": hours]) }
        return CoreStrings.t("chrome.playback.offset_hours_minutes", ["sign": sign, "hours": hours, "minutes": rest])
    }

    /// The step on screen's label, as the strip's readout writes it.
    var label: String { step.map(offsetLabel) ?? "" }
}
