//
//  RadarPlayer.swift
//  meteocool
//
//  The native map's player: which step is on screen, and the strip to
//  scrub and play it with (core's `NowcastPlayback.svelte`).
//

import SwiftUI
import UIKit

/// Which step of the timeline is on screen, and playback.
@MainActor
final class RadarPlayer: ObservableObject {
    /// Per frame while playing (core's `FRAME_MS`).
    static let frameInterval: TimeInterval = 0.45

    @Published private(set) var timeline = RadarTimeline.empty
    @Published private(set) var index = 0
    @Published private(set) var playing = false
    @Published var palette = "classic"
    /// Who the data on screen is from (core's `layers/attributions.ts`).
    @Published var credits = ""
    /// Whether the series has a reading at a point, for the bars.
    var hasReadings: Bool { !timeline.dbz.isEmpty }

    /// Called whenever the step on screen changes.
    var onStep: ((Int) -> Void)?
    /// Whether a step's pictures are ready: playing waits for the next one,
    /// so a step comes on screen whole, never tile by tile.
    var isReady: ((Int) -> Bool)?
    /// Waiting for a step at most this long, so a slow tile cannot stop
    /// playback.
    static let maxWait: TimeInterval = 3
    private var waitingSince: Date?
    /// Parked on the newest observation: stays there as new ones arrive.
    private(set) var followsLive = true
    private var timer: Timer?
    private let selection = UISelectionFeedbackGenerator()

    var step: Int? { timeline.steps.indices.contains(index) ? timeline.steps[index] : nil }
    var nowIndex: Int? { timeline.now.flatMap { timeline.steps.firstIndex(of: $0) } }

    func setTimeline(_ next: RadarTimeline) {
        let previous = step
        timeline = next
        if followsLive || previous == nil, let now = nowIndex {
            index = now
        } else if let previous, let same = next.steps.firstIndex(of: previous) {
            index = same
        } else {
            index = nowIndex ?? max(0, next.steps.count - 1)
        }
        if let step { onStep?(step) }
    }

    /// Moves to step `index` of the strip, as a scrub does.
    func scrub(to newIndex: Int) {
        let clamped = max(0, min(newIndex, timeline.steps.count - 1))
        guard clamped != index, !timeline.steps.isEmpty else { return }
        if playing { pause() }
        selection.selectionChanged()
        show(clamped)
    }

    func show(time: Int) {
        guard let step = timeline.step(nearest: time), let at = timeline.steps.firstIndex(of: step) else { return }
        pause()
        show(at)
    }

    /// Back to the newest observation, following it.
    func showLive() {
        pause()
        if let now = nowIndex { show(now) }
    }

    func togglePlay() {
        playing ? pause() : play()
    }

    func play() {
        guard !timeline.steps.isEmpty, !playing else { return }
        playing = true
        // From the end, start over at now (core's `playbackLoop`).
        if index >= timeline.steps.count - 1, let now = nowIndex { show(now) }
        timer = Timer.scheduledTimer(withTimeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advance() }
        }
    }

    func pause() {
        timer?.invalidate()
        timer = nil
        waitingSince = nil
        playing = false
    }

    private func advance() {
        guard playing, !timeline.steps.isEmpty else { return }
        let next = index >= timeline.steps.count - 1 ? (nowIndex ?? 0) : index + 1
        if let isReady, !isReady(timeline.steps[next]) {
            let since = waitingSince ?? Date()
            waitingSince = since
            if Date().timeIntervalSince(since) < Self.maxWait { return }
        }
        waitingSince = nil
        show(next)
    }

    private func show(_ newIndex: Int) {
        index = newIndex
        followsLive = newIndex == nowIndex
        if let step { onStep?(step) }
    }

    /// The step's label: "Now", "+45m", with the clock time.
    var label: String {
        guard let step else { return "" }
        let offset = timeline.offsetLabel(step, now: NSLocalizedString("native_map_now", comment: ""))
        let clock = Date(timeIntervalSince1970: TimeInterval(step)).formatted(date: .omitted, time: .shortened)
        return "\(offset) · \(clock)"
    }
}

/// The strip under the map: play, the steps as bars of the reading at the
/// user's position, the needle, and the time on screen.
struct RadarTimelineBar: View {
    @ObservedObject var player: RadarPlayer

    var body: some View {
        HStack(spacing: 12) {
            Button(action: player.togglePlay) {
                Image(systemName: player.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString(player.playing ? "native_map_pause" : "native_map_play", comment: ""))
            .accessibilityIdentifier("nativeMap.play")

            VStack(alignment: .leading, spacing: 4) {
                Text(player.label)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .accessibilityIdentifier("nativeMap.time")
                RadarStrip(player: player)
                    .frame(height: 34)
                if !player.credits.isEmpty {
                    Text(player.credits)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .modifier(StripBackground())
        .padding(.horizontal, 12)
    }
}

private struct StripBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }
}

/// The steps, scrubbable: a bar per step where the series has a reading
/// (core's `Timeline.svelte`), the forecast lighter, ticks every hour.
private struct RadarStrip: View {
    @ObservedObject var player: RadarPlayer

    var body: some View {
        GeometryReader { geometry in
            let steps = player.timeline.steps
            Canvas { context, size in
                guard steps.count > 1 else { return }
                let slot = size.width / CGFloat(steps.count)
                let barArea = size.height - 12
                let peak = max(45, player.timeline.dbz.values.max() ?? 0)
                // Track.
                context.fill(Path(roundedRect: CGRect(x: 0, y: barArea - 2, width: size.width, height: 2), cornerRadius: 1),
                             with: .color(.secondary.opacity(0.4)))
                for (i, step) in steps.enumerated() {
                    let x = CGFloat(i) * slot
                    if let dbz = player.timeline.dbz[step], dbz > 5,
                       let rgb = RadarPalette.colour(dbz: dbz, palette: player.palette) {
                        let height = max(2, barArea * CGFloat(min(dbz, peak) - 5) / CGFloat(peak - 5))
                        let colour = Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
                            .opacity(player.timeline.isForecast(step) ? 0.72 : 1)
                        context.fill(Path(CGRect(x: x + slot * 0.15, y: barArea - height, width: slot * 0.7, height: height)),
                                     with: .color(colour))
                    }
                    if let now = player.timeline.now, (step - now) % 3600 == 0 {
                        let text = Text(player.timeline.offsetLabel(step, now: NSLocalizedString("native_map_now", comment: "")))
                            .font(.system(size: 9, weight: step == now ? .bold : .regular))
                            .foregroundStyle(.secondary)
                        // Kept inside the strip at both ends.
                        let resolved = context.resolve(text)
                        let half = resolved.measure(in: size).width / 2
                        context.draw(resolved, at: CGPoint(x: min(max(x + slot / 2, half), size.width - half), y: size.height - 5))
                    }
                }
                // The needle.
                let needle = CGFloat(player.index) * slot + slot / 2
                context.fill(Path(roundedRect: CGRect(x: needle - 1.5, y: 0, width: 3, height: barArea + 2), cornerRadius: 1.5),
                             with: .color(.primary))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard steps.count > 1 else { return }
                let slot = geometry.size.width / CGFloat(steps.count)
                player.scrub(to: Int(value.location.x / slot))
            })
        }
        .accessibilityElement()
        .accessibilityLabel(NSLocalizedString("native_map_timeline", comment: ""))
        .accessibilityValue(player.label)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: player.scrub(to: player.index + 1)
            case .decrement: player.scrub(to: player.index - 1)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("nativeMap.timeline")
    }
}
