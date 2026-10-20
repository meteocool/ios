//
//  SliceDial.swift
//  meteocool
//
//  Turning the cut on the 3D map, with the storm itself as the picture
//  (core's `SliceDial.svelte`): the map already draws the open storm cut,
//  so the panel needs no second picture of it, only a way to turn the
//  slice. A ruler dragged under a fixed needle, as a photo editor's
//  straighten dial: an angle has no ends, so the ruler runs on for ever, a
//  flick carries on, and it settles on the two directions that mean
//  something with a tick of haptics.
//

import QuartzCore
import SwiftUI
import UIKit

struct SliceDial: View {
    @ObservedObject var cut: StormCut
    let reference: CutAngle.Reference

    /// About 140 degrees across a phone, 5-degree ticks 12 pt apart
    /// (`PX_PER_DEG`, `MINOR`, `MAJOR`).
    static let pointsPerDegree = 2.4
    static let minor = 5.0
    static let major = 45.0
    /// How close to a named direction a released dial settles on it.
    static let detent = 7.0
    /// Momentum's decay per millisecond: a flick glides about a quarter turn.
    static let friction = 0.0045

    /// The dial's own angle, unwrapped, so the ruler scrolls on through the
    /// seam at 180; the cut gets it folded.
    @State private var angle = 0.0
    @State private var held = false
    @State private var sideways: Bool?
    @State private var lastX: CGFloat = 0
    @State private var lastTime: TimeInterval = 0
    /// Degrees per millisecond, smoothed over the last few moves.
    @State private var velocity = 0.0
    @State private var motion: Task<Void, Never>?
    @State private var lastDetent: Int?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(CutAngle.label(cut.shown, reference: reference))
                    .font(.subheadline.weight(.semibold))
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                if abs(CutAngle.normalise(cut.shown)).truncatingRemainder(dividingBy: 180) >= 1 {
                    Button(action: reset) {
                        Label(CoreStrings.t(reference == .north ? "storm.cut.reset_north" : "storm.cut.reset_track"),
                              systemImage: "arrow.uturn.backward")
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 12)
                            .frame(minHeight: 30)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                            // The hit region a finger needs, round a smaller capsule.
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScale())
                    .transition(.opacity)
                    .accessibilityIdentifier("nativeMap.storm.dial.reset")
                }
            }
            .frame(minHeight: 44)
            .animation(.easeOut(duration: 0.15), value: abs(CutAngle.normalise(cut.shown)).truncatingRemainder(dividingBy: 180) >= 1)
            ruler
        }
        .onAppear { angle = cut.shown }
        // A link, the swing or the cutaway turned it: the ruler follows, the
        // short way round.
        .onChange(of: cut.shown) { _, shown in
            guard !held, motion == nil else { return }
            angle += CutAngle.normalise(shown - angle)
        }
        .onDisappear { stop() }
    }

    private var ruler: some View {
        Canvas { gc, size in
            let ppd = Self.pointsPerDegree
            let span = Double(size.width) / 2 / ppd + Self.minor
            var deg = (ceil((angle - span) / Self.minor) * Self.minor).rounded()
            while deg <= angle + span {
                let x = size.width / 2 + CGFloat((deg - angle) * ppd)
                let major = deg.truncatingRemainder(dividingBy: Self.major) == 0
                let name = major ? named(deg) : nil
                let height: CGFloat = major ? 15 : 9
                gc.fill(Path(roundedRect: CGRect(x: x - 0.75, y: size.height - 6 - height, width: 1.5, height: height), cornerRadius: 1),
                        with: .color(.primary.opacity(name != nil ? 0.85 : major ? 0.6 : 0.35)))
                if major {
                    // Above the ticks and clear of the needle, so the
                    // direction under it is always legible; that one in the
                    // accent.
                    let centred = abs(x - size.width / 2) < CGFloat(Self.major * ppd / 4)
                    let text = Text(name ?? "\(Int(abs(CutAngle.normalise(deg))))°")
                        .font(.caption2.weight(centred ? .semibold : .regular).monospacedDigit())
                        .foregroundStyle(centred ? Color.accentColor : Color.primary.opacity(0.6))
                    gc.draw(text, at: CGPoint(x: x, y: size.height - 24), anchor: .bottom)
                }
                deg += Self.minor
            }
            // Among the ticks only, with a light edge to stand off them.
            let needle = Path(roundedRect: CGRect(x: size.width / 2 - 1.5, y: size.height - 25, width: 3, height: 22), cornerRadius: 2)
            gc.stroke(needle, with: .color(.white.opacity(0.5)), lineWidth: 2)
            gc.fill(needle, with: .color(.accentColor))
        }
        .frame(height: 52)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        // Fading out at both ends, so it reads as running on past them.
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                                     .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                             startPoint: .leading, endPoint: .trailing))
        .contentShape(Rectangle())
        .gesture(drag)
        .accessibilityElement()
        .accessibilityLabel(CoreStrings.t("storm.cut.dial_aria"))
        .accessibilityValue(CutAngle.label(cut.shown, reference: reference))
        .accessibilityAdjustableAction { direction in
            cut.stopSweep(keep: true)
            stop()
            angle = cut.shown
            turn(to: angle + (direction == .increment ? 5 : -5))
        }
        .accessibilityIdentifier("nativeMap.storm.dial")
    }

    /// The name a major tick carries, if it is one of the two directions
    /// that mean something.
    private func named(_ deg: Double) -> String? {
        let folded = abs(CutAngle.normalise(deg)).truncatingRemainder(dividingBy: 180)
        let (along, across) = CutAngle.snapLabels(reference)
        if folded == 0 { return along }
        if folded == 90 { return across }
        return nil
    }

    // MARK: Turning

    private var drag: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                // Sideways only: a drag that sets off up or down is the sheet's.
                if sideways == nil { sideways = abs(value.translation.width) >= abs(value.translation.height) }
                guard sideways == true else { return }
                let now = value.time.timeIntervalSinceReferenceDate * 1000
                if !held {
                    // Taking hold stops the swing where it is, rather than
                    // letting it carry on under the finger or jump back.
                    cut.stopSweep(keep: true)
                    stop()
                    angle += CutAngle.normalise(cut.shown - angle)
                    held = true
                    lastX = value.startLocation.x
                    lastTime = now - 16
                    velocity = 0
                }
                // Dragging the ruler left brings larger angles under the
                // needle, as scrolling content does.
                let delta = -Double(value.location.x - lastX) / Self.pointsPerDegree
                let dt = max(now - lastTime, 1)
                velocity = 0.7 * (delta / dt) + 0.3 * velocity
                lastX = value.location.x
                lastTime = now
                turn(to: angle + delta)
            }
            .onEnded { value in
                defer { sideways = nil }
                guard held else { return }
                held = false
                // A finger held still before letting go means "here".
                if value.time.timeIntervalSinceReferenceDate * 1000 - lastTime > 80 { velocity = 0 }
                glide()
            }
    }

    /// Sets the angle, telling the cut, with a tick crossing a named direction.
    private func turn(to next: Double) {
        angle = next
        cut.set(next.rounded())
        let detent = Int((next / 90).rounded())
        if abs(next - Double(detent) * 90) < 1, detent != lastDetent {
            lastDetent = detent
            UISelectionFeedbackGenerator().selectionChanged()
        } else if abs(next - Double(lastDetent ?? 0) * 90) > Self.detent {
            lastDetent = nil
        }
    }

    private func stop() {
        motion?.cancel()
        motion = nil
    }

    /// Carries on at the release speed, slowing, then settles.
    private func glide() {
        stop()
        let start = velocity
        motion = Task { @MainActor in
            var v = start
            var last = CACurrentMediaTime()
            while abs(v) >= 0.02 {
                try? await Task.sleep(for: .milliseconds(16))
                if Task.isCancelled { return }
                let now = CACurrentMediaTime()
                let dt = (now - last) * 1000
                last = now
                v *= exp(-Self.friction * dt)
                turn(to: angle + v * dt)
            }
            // A named direction if it is close, the nearest degree if not.
            let detent = (angle / 90).rounded() * 90
            await ease(to: abs(angle - detent) <= Self.detent ? detent : angle.rounded(), milliseconds: 220)
            if !Task.isCancelled { motion = nil }
        }
    }

    /// Back along the track (or north–south), from whichever side it is
    /// turned to.
    private func reset() {
        cut.stopSweep(keep: true)
        stop()
        angle += CutAngle.normalise(cut.shown - angle)
        let target = (angle / 180).rounded() * 180
        motion = Task { @MainActor in
            await ease(to: target, milliseconds: 320)
            if !Task.isCancelled { motion = nil }
        }
    }

    private func ease(to target: Double, milliseconds: Double) async {
        let from = angle
        let start = CACurrentMediaTime()
        while !Task.isCancelled {
            let t = min((CACurrentMediaTime() - start) * 1000 / milliseconds, 1)
            turn(to: from + (target - from) * (1 - pow(1 - t, 3)))
            if t >= 1 { return }
            try? await Task.sleep(for: .milliseconds(16))
        }
    }
}
