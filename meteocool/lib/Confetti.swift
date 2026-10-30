//
//  Confetti.swift
//  meteocool
//
//  Three quick taps on the logo: a burst of confetti in the radar's colours.
//

import UIKit

/// Counts taps that come in a quick run: `tap()` is true on the tap that
/// makes `taps` of them within `within` seconds, and the count starts over.
/// Counting leaves every tap its own action at once, which a recogniser for
/// several taps would hold back until it gave up.
struct TapRun {
    let taps: Int
    let within: TimeInterval
    private var times: [Date] = []

    init(taps: Int, within: TimeInterval) {
        self.taps = taps
        self.within = within
    }

    mutating func tap(at date: Date = Date()) -> Bool {
        times = times.filter { date.timeIntervalSince($0) <= within } + [date]
        guard times.count >= taps else { return false }
        times = []
        return true
    }
}

/// A short burst of confetti from a view (the logo) across the screen.
///
/// It lives in a view of its own over everything else, which takes no
/// touches and removes itself once the last piece has gone. Under Reduce
/// Motion a few still pieces fade in and out around the source instead.
/// Either way a success haptic comes with it.
@MainActor
enum Confetti {
    /// The burst's view, for UI tests.
    static let identifier = "map.confetti"

    /// The radar's colours, drizzle to hail, as the classic palette draws
    /// them, and the app's blue.
    private static let colors: [UIColor] = [
        0x007AFF, 0x60B3D4, 0x34D65B, 0x11B116, 0xFFE200, 0xFF9300, 0xE90000, 0xE92AEB, 0x9300EF,
    ].map { UIColor(red: CGFloat($0 >> 16 & 0xFF) / 255, green: CGFloat($0 >> 8 & 0xFF) / 255, blue: CGFloat($0 & 0xFF) / 255, alpha: 1) }

    /// How long the burst emits, and how long its longest-lived piece lasts.
    private static let emitting: TimeInterval = 0.15
    private static let lifetime: Float = 4

    static func burst(in container: UIView, from source: UIView) {
        let host = UIView(frame: container.bounds)
        host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.isUserInteractionEnabled = false
        host.accessibilityIdentifier = identifier
        container.addSubview(host)
        let origin = source.convert(CGPoint(x: source.bounds.midX, y: source.bounds.midY), to: host)

        UINotificationFeedbackGenerator().notificationOccurred(.success)
        let calm = reduceMotion
        // Which of the two it is, for UI tests.
        host.accessibilityValue = calm ? "still" : "burst"
        let duration = calm ? still(in: host, around: origin) : emit(in: host, from: origin)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { host.removeFromSuperview() }
    }

    /// Reduce Motion, or `--reduce-motion` for UI tests (debug builds only):
    /// the simulator cannot turn the setting on from a test.
    private static var reduceMotion: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--reduce-motion") { return true }
        #endif
        return UIAccessibility.isReduceMotionEnabled
    }

    /// The burst: pieces thrown down and to the right of the logo, falling
    /// as they turn and fade. Returns how long it lasts.
    private static func emit(in host: UIView, from origin: CGPoint) -> TimeInterval {
        let emitter = CAEmitterLayer()
        emitter.frame = host.bounds
        emitter.emitterPosition = origin
        emitter.emitterShape = .circle
        emitter.emitterSize = CGSize(width: 24, height: 24)
        // Without it the layer starts as if it had been emitting for a while.
        emitter.beginTime = CACurrentMediaTime()
        emitter.emitterCells = colors.flatMap { color in
            [piece(.strip, across: host.bounds.size), piece(.dot, across: host.bounds.size)].map { cell in
                cell.color = color.cgColor
                return cell
            }
        }
        host.layer.addSublayer(emitter)
        DispatchQueue.main.asyncAfter(deadline: .now() + emitting) { emitter.birthRate = 0 }
        return emitting + TimeInterval(lifetime) + 0.5
    }

    private enum Shape { case strip, dot }

    /// A kind of piece, thrown hard enough to cross a screen of `size` in
    /// a couple of seconds and stay on it while it falls.
    private static func piece(_ shape: Shape, across size: CGSize) -> CAEmitterCell {
        let cell = CAEmitterCell()
        let image = image(shape)
        cell.contents = image.cgImage
        cell.birthRate = 45
        cell.lifetime = lifetime
        cell.lifetimeRange = 0.6
        let speed = min(max(size.width * 0.65, 240), 520)
        cell.velocity = speed
        cell.velocityRange = speed * 0.55
        // Down and out from the corner the logo sits in, fanning from nearly
        // level to nearly straight down, then pulled down as they slow.
        cell.emissionLongitude = .pi * 0.3
        cell.emissionRange = .pi * 0.25
        cell.xAcceleration = -speed * 0.1
        cell.yAcceleration = size.height * 0.12
        cell.spin = 3
        cell.spinRange = 8
        // The cell draws the image's pixels as points: scaled back to its size.
        cell.scale = 1 / image.scale
        cell.scaleRange = 0.3 / image.scale
        cell.alphaSpeed = -0.2
        return cell
    }

    /// A white piece, tinted by its cell's colour.
    private static func image(_ shape: Shape) -> UIImage {
        let size = shape == .strip ? CGSize(width: 6, height: 11) : CGSize(width: 7, height: 7)
        return UIGraphicsImageRenderer(size: size).image { _ in
            UIColor.white.setFill()
            let rect = CGRect(origin: .zero, size: size)
            (shape == .strip ? UIBezierPath(roundedRect: rect, cornerRadius: 1.5) : UIBezierPath(ovalIn: rect)).fill()
        }
    }

    /// Reduce Motion: a dozen pieces lie still round the logo, fade in, and
    /// fade out again. Nothing moves. Returns how long it lasts.
    private static func still(in host: UIView, around origin: CGPoint) -> TimeInterval {
        var pieces: [UIView] = []
        for index in 0 ..< 14 {
            let strip = index.isMultiple(of: 2)
            let piece = UIView(frame: CGRect(x: 0, y: 0, width: strip ? 8 : 9, height: strip ? 15 : 9))
            piece.backgroundColor = colors[index % colors.count]
            piece.layer.cornerRadius = strip ? 2 : 4.5
            // Fanned out below and right of the logo, as the burst would throw them.
            let angle = 0.3 + Double(index) / 13 * (.pi / 2 - 0.1)
            let distance = 70 + Double((index * 37) % 100)
            piece.center = CGPoint(x: origin.x + CGFloat(cos(angle) * distance), y: origin.y + CGFloat(sin(angle) * distance))
            piece.transform = CGAffineTransform(rotationAngle: CGFloat(index) * 0.7)
            piece.alpha = 0
            host.addSubview(piece)
            pieces.append(piece)
        }
        // One after the other: set up at once, the fade out would cancel the fade in.
        UIView.animate(withDuration: 0.25, animations: { pieces.forEach { $0.alpha = 1 } }, completion: { _ in
            UIView.animate(withDuration: 0.6, delay: 1.8) { pieces.forEach { $0.alpha = 0 } }
        })
        return 2.8
    }
}
