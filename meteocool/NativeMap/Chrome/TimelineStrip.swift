//
//  TimelineStrip.swift
//  meteocool
//
//  core's timeline strip (`components/Timeline.svelte`): the steps as a
//  ruler with the rain at the point, the needle, drag, flick and settle.
//

import QuartzCore
import SwiftUI
import UIKit

/// The needle in motion: a finger, a flick's glide, or the settle onto a
/// step. Reports each whole step it passes to the player.
@MainActor
final class StripMotion: ObservableObject {
    /// Fractional step under the needle while it moves; nil at rest.
    @Published private(set) var position: Double?
    @Published private(set) var dragging = false

    weak var player: RadarPlayer?
    private var velocity = 0.0
    private var lastMove: CFTimeInterval = 0
    private var startX: CGFloat = 0
    private var moved = false
    private var link: CADisplayLink?
    private var linkTarget: LinkTarget?
    private var lastFrame: CFTimeInterval = 0
    private var settle: (from: Double, to: Int, start: CFTimeInterval)?
    private var reported: Int?
    private let tick = UIImpactFeedbackGenerator(style: .light)
    private let detent = UIImpactFeedbackGenerator(style: .medium)

    private var reach: TimelinePhysics.Reach { player?.reach ?? .all(0) }
    private var last: Int { reach.last }
    private var nowIndex: Int? { player?.nowIndex }

    func touch(at x: CGFloat, start: CGFloat, width: CGFloat, count: Int) {
        guard count > 0, width > 0 else { return }
        if !dragging {
            stopLink()
            dragging = true
            moved = false
            startX = start
            velocity = 0
            lastMove = CACurrentMediaTime()
            reported = player?.index
            player?.grab()
            tick.prepare()
        }
        if !moved, abs(x - startX) < TimelinePhysics.slop { return }
        moved = true
        let raw = Double(x / width) * Double(count) - 0.5
        let p = TimelinePhysics.rubberBand(raw, reach: reach)
        let now = CACurrentMediaTime()
        let dt = max((now - lastMove) * 1000, 1)
        if let previous = position {
            velocity = 0.7 * ((p - previous) / dt) + 0.3 * velocity
        }
        lastMove = now
        position = p
        report(p)
    }

    func lift(at x: CGFloat, width: CGFloat, count: Int) {
        guard dragging else { return }
        dragging = false
        if !moved {
            // A tap: straight to that step.
            let raw = Double(x / width) * Double(count) - 0.5
            let to = TimelinePhysics.restingStep(raw, reach: reach, detent: nil)
            position = nil
            report(Double(to))
            player?.release()
            return
        }
        let flick = (CACurrentMediaTime() - lastMove) * 1000 <= TimelinePhysics.flickWindow && abs(velocity) > TimelinePhysics.atRest
        if !flick { velocity = 0 }
        startLink()
    }

    /// Steps the glide, then the settle, once per frame.
    fileprivate func frame(_ time: CFTimeInterval) {
        let dt = lastFrame == 0 ? 16 : (time - lastFrame) * 1000
        lastFrame = time
        if let settle {
            let k = (time - settle.start) * 1000 / TimelinePhysics.settleDuration
            let p = settle.from + (Double(settle.to) - settle.from) * TimelinePhysics.ease(k)
            position = p
            report(p)
            if k >= 1 { finish(at: settle.to) }
            return
        }
        guard let p = position else { return finish(at: player?.index ?? 0) }
        if velocity != 0 {
            let next = TimelinePhysics.glideStep(position: p, velocity: velocity, dt: dt, reach: reach, detent: nowIndex)
            position = next.position
            velocity = next.velocity
            report(next.position)
            return
        }
        settle = (p, TimelinePhysics.restingStep(p, reach: reach, detent: nowIndex), time)
    }

    private func finish(at index: Int) {
        stopLink()
        settle = nil
        position = nil
        report(Double(index))
        player?.release()
    }

    /// Each whole step the needle reaches is shown, with a tick, or a firmer
    /// one on now and the ends (core's `tick`/`detent` haptics).
    private func report(_ p: Double) {
        let step = max(reach.first, min(last, Int(p.rounded())))
        guard step != reported else { return }
        reported = step
        player?.scrub(to: step)
        if step == nowIndex || step == reach.first || step == last { detent.impactOccurred() } else { tick.impactOccurred() }
    }

    private func startLink() {
        stopLink()
        lastFrame = 0
        let target = LinkTarget(owner: self)
        let link = CADisplayLink(target: target, selector: #selector(LinkTarget.fire(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        linkTarget = target
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
        linkTarget = nil
    }

    /// The display link's target, which holds the motion weakly; the link
    /// runs on the main run loop.
    @MainActor
    private final class LinkTarget: NSObject {
        weak var owner: StripMotion?
        init(owner: StripMotion) { self.owner = owner }
        @objc func fire(_ link: CADisplayLink) {
            owner?.frame(link.timestamp)
        }
    }
}

/// The strip: 56 pt of plot over a 16 pt axis.
struct TimelineStrip: View {
    @ObservedObject var player: RadarPlayer
    let theme: ChromeTheme
    @StateObject private var motion = StripMotion()

    static let plotHeight: CGFloat = 56
    static let axisHeight: CGFloat = 16

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let count = player.timeline.steps.count
            ZStack(alignment: .topLeading) {
                Canvas { context, size in draw(in: &context, size: size) }
                if let position = motion.position, count > 0 {
                    readout(position: position, width: width, count: count)
                }
                if player.loading {
                    StripSkeleton(theme: theme)
                        .frame(height: Self.plotHeight)
                } else if let gap = player.timeline.forecastGap {
                    Text(CoreStrings.t("forecast_none_here"))
                        .scaledFont(12, relativeTo: .caption)
                        .foregroundStyle(theme.text2)
                        .multilineTextAlignment(.center)
                        .frame(width: width * (1 - gap), height: Self.plotHeight)
                        .offset(x: width * gap)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    motion.touch(at: value.location.x, start: value.startLocation.x, width: width, count: count)
                }
                .onEnded { value in
                    motion.lift(at: value.location.x, width: width, count: count)
                })
            .onAppear { motion.player = player }
        }
        .frame(height: Self.plotHeight + Self.axisHeight)
        .accessibilityElement()
        .accessibilityLabel(CoreStrings.t("chrome.playback.timeline"))
        .accessibilityValue(player.label)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: player.scrub(to: TimelinePhysics.stepOver(player.index, by: 1, reach: player.reach))
            case .decrement: player.scrub(to: TimelinePhysics.stepOver(player.index, by: -1, reach: player.reach))
            @unknown default: break
            }
        }
        .accessibilityIdentifier("nativeMap.timeline")
    }

    /// The step under the needle while it moves (core's readout).
    private func readout(position: Double, width: CGFloat, count: Int) -> some View {
        let index = max(0, min(player.lastIndex, Int(position.rounded())))
        let x = (CGFloat(max(-1.5, min(position, Double(count) + 0.5))) + 0.5) * width / CGFloat(count)
        let text = player.timeline.steps.indices.contains(index) ? player.offsetLabel(player.timeline.steps[index]) : ""
        return Text(text)
            .scaledFont(11, weight: .semibold, relativeTo: .caption2, digits: true)
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(theme.accent, in: Capsule())
            .fixedSize()
            .position(x: min(max(x, 24), width - 24), y: 10)
            .allowsHitTesting(false)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let timeline = player.timeline
        let steps = timeline.steps
        guard steps.count > 1 else { return }
        let n = CGFloat(steps.count)
        let slot = size.width / n
        let plot = Self.plotHeight
        let nowIndex = player.nowIndex
        let gridNow = timeline.gridNow

        context.drawLayer { plotLayer in
            plotLayer.clip(to: Path(roundedRect: CGRect(x: 0, y: 0, width: size.width, height: plot), cornerRadius: 10))
            // Frames ready to show, filling from the bottom.
            plotLayer.drawLayer { fill in
                fill.opacity = theme.preloadOpacity
                for (i, step) in steps.enumerated() where player.preloaded.contains(step) {
                    fill.fill(Path(CGRect(x: CGFloat(i) * slot - 0.5, y: 0, width: slot + 1, height: plot)), with: .color(theme.brand))
                }
            }
            // An open radar's steps without a sweep, hatched (core's `sweepGaps`).
            for run in TimelinePhysics.gaps(steps: steps, only: player.only) {
                let rect = CGRect(x: CGFloat(run.lowerBound) * slot, y: 0, width: CGFloat(run.count) * slot, height: plot)
                plotLayer.drawLayer { hatch in
                    hatch.clip(to: Path(rect))
                    var stripes = Path()
                    var x = rect.minX - plot
                    while x < rect.maxX {
                        stripes.move(to: CGPoint(x: x, y: plot))
                        stripes.addLine(to: CGPoint(x: x + plot, y: 0))
                        x += 6
                    }
                    hatch.stroke(stripes, with: .color(theme.text2.opacity(0.22)), lineWidth: 1.5)
                }
            }
            // The past, tinted up to now.
            if let nowIndex {
                plotLayer.fill(Path(CGRect(x: 0, y: 0, width: (CGFloat(nowIndex) + 0.5) * slot, height: plot)),
                               with: .color(theme.text2.opacity(0.06)))
            }
            // The ruler.
            for (i, step) in steps.enumerated() {
                let major = TimelinePhysics.isMajor(step, gridNow: gridNow)
                let height: CGFloat = major ? 13 : 7
                let opacity = !timeline.isPlayable(step) ? 0.12 : major ? 0.5 : 0.28
                let x = (CGFloat(i) + 0.5) * slot - 0.75
                plotLayer.fill(Path(roundedRect: CGRect(x: x, y: plot - height, width: 1.5, height: height), cornerRadius: 0.75),
                               with: .color(theme.text2.opacity(opacity)))
            }
            // The rain at the point.
            let ceiling = timeline.barCeiling
            for (i, step) in steps.enumerated() {
                guard let dbz = timeline.dbz[step], dbz > 0,
                      let rgb = RadarPalette.colour(dbz: dbz, palette: player.palette) else { continue }
                let height = max(2, CGFloat(dbz / ceiling) * (plot - 4))
                let width = max(1, slot - 1.5)
                let colour = Color(red: rgb.red, green: rgb.green, blue: rgb.blue).opacity(timeline.isForecast(step) ? 0.72 : 1)
                plotLayer.fill(Path(roundedRect: CGRect(x: CGFloat(i) * slot + (slot - width) / 2, y: plot - height, width: width, height: height),
                                    cornerRadius: min(1.5, slot / 4)), with: .color(colour))
            }
            // Now: the newest observation.
            if let nowIndex {
                var line = Path()
                let x = (CGFloat(nowIndex) + 0.5) * slot
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: plot))
                plotLayer.stroke(line, with: .color(theme.text2.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
        }

        // The needle, over everything and unclipped.
        let position = motion.position ?? Double(player.index)
        let needleX = (CGFloat(max(-1.5, min(position, Double(steps.count) + 0.5))) + 0.5) * slot
        let needle = Path(roundedRect: CGRect(x: needleX - 1.5, y: 0.5, width: 3, height: 55), cornerRadius: 1.5)
        context.fill(needle, with: .color(theme.accent))
        context.stroke(needle, with: .color(.white.opacity(0.55)), lineWidth: 1)
        let scale: CGFloat = motion.dragging ? 1.15 : 1
        let knob = CGRect(x: needleX - 7 * scale, y: plot / 2 - 11 * scale, width: 14 * scale, height: 22 * scale)
        var shadowed = context
        shadowed.addFilter(.shadow(color: .black.opacity(0.25), radius: 1, y: 1))
        shadowed.fill(Path(roundedRect: knob, cornerRadius: 7 * scale), with: .color(theme.accent))
        context.stroke(Path(roundedRect: knob, cornerRadius: 7 * scale), with: .color(.white.opacity(0.7)), lineWidth: 1)
        for dx: CGFloat in [-2.5, 1] {
            context.fill(Path(roundedRect: CGRect(x: needleX + dx, y: plot / 2 - 5, width: 1.5, height: 10), cornerRadius: 0.75),
                         with: .color(.white.opacity(0.85)))
        }

        // The axis.
        for tick in TimelinePhysics.axisTicks(steps: steps, gridNow: gridNow) {
            let label = context.resolve(Text(player.offsetLabel(tick.step))
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(theme.text2))
            let half = label.measure(in: size).width / 2
            let x = tick.at == 0 ? half : tick.at == 1 ? size.width - half : tick.at * size.width
            context.draw(label, at: CGPoint(x: x, y: plot + Self.axisHeight / 2))
        }
    }
}

/// Placeholder bars while the steps load (`ChartSkeleton.svelte`): a crest
/// of light sweeping across them.
struct StripSkeleton: View {
    let theme: ChromeTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            Canvas { graphics, size in
                let count = 25
                let gap: CGFloat = 2
                let width = (size.width - gap * CGFloat(count - 1)) / CGFloat(count)
                let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.6) / 2.6
                for i in 0 ..< count {
                    let share = 0.34 + 0.26 * abs(sin(0.9 * Double(i))) + 0.12 * abs(sin(0.31 * Double(i)))
                    let height = size.height * share
                    let phase = (Double(i) / Double(count) - t + 1).truncatingRemainder(dividingBy: 1)
                    let crest = reduceMotion ? 0.5 : max(0.4, 1 - abs(phase - 0.14) * 4)
                    graphics.fill(Path(roundedRect: CGRect(x: CGFloat(i) * (width + gap), y: size.height - height, width: width, height: height),
                                       cornerRadius: 2), with: .color(theme.tint.opacity(0.55 * crest * 1.6)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}
