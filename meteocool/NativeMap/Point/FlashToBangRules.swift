//
//  FlashToBangRules.swift
//  meteocool
//
//  Flash to bang: the gap between a flash and its thunder as a distance,
//  and the strike in the live feed it most likely was.
//
//  No app dependencies here: `scripts/check.sh` compiles this file alone.
//

import Foundation

enum FlashToBangRules {
    /// Sound in air at 20 °C, in metres per second. Without a temperature at
    /// hand the distance is "about": at 0 °C sound is 3 % slower.
    static let speedOfSound = 343.0
    /// Past about 20 km thunder is not heard: a minute without it ends the count.
    static let maxGap: TimeInterval = 60
    /// Two taps closer than this are one tap that bounced.
    static let debounce: TimeInterval = 0.15
    /// Strikes reach the feed seconds after they happen: the search goes on
    /// this long after the thunder.
    static let searchFor: TimeInterval = 20
    /// The strike's own time against the flash tap, which comes a reaction
    /// time after the flash: from 2.5 s before the tap to 0.5 s after it,
    /// most likely half a second before.
    static let windowBefore: TimeInterval = 2.5
    static let windowAfter: TimeInterval = 0.5
    static let reaction: TimeInterval = 0.5
    /// How far off the strike's time may be before it counts against it as
    /// much as a distance at the edge of the tolerance.
    static let timeScale: TimeInterval = 1.5
    /// Below this, lightning can reach you.
    static let strikingRange = 5_000.0
    /// The strikes kept around the user while counting, and those that tick.
    static let keepWithin = 30_000.0
    static let tickWithin = 10_000.0
    /// Strikes older than this are of no use to a count.
    static let keepFor: TimeInterval = maxGap + searchFor + windowBefore + 30

    /// Mean Earth radius (IUGG), metres.
    static let earthRadius = 6_371_008.8

    struct Place: Equatable, Sendable {
        let latitude: Double
        let longitude: Double
        /// The fix's horizontal accuracy in metres; 0 when unknown.
        var accuracy: Double = 0
    }

    /// One strike: where, and when it happened (Unix seconds).
    struct Strike: Equatable, Sendable {
        let latitude: Double
        let longitude: Double
        let time: TimeInterval
    }

    // MARK: Distance

    /// The distance sound travels in `seconds`.
    static func distance(seconds: TimeInterval) -> Double {
        max(0, seconds) * speedOfSound
    }

    /// Great-circle distance in metres.
    static func metres(from a: Place, to b: Strike) -> Double {
        let (φ1, φ2) = (a.latitude * .pi / 180, b.latitude * .pi / 180)
        let Δφ = φ2 - φ1, Δλ = (b.longitude - a.longitude) * .pi / 180
        let h = sin(Δφ / 2) * sin(Δφ / 2) + cos(φ1) * cos(φ2) * sin(Δλ / 2) * sin(Δλ / 2)
        return 2 * earthRadius * asin(min(1, h.squareRoot()))
    }

    /// The initial bearing from `a` to `b`, degrees clockwise from north, 0..<360.
    static func bearing(from a: Place, to b: Strike) -> Double {
        let (φ1, φ2) = (a.latitude * .pi / 180, b.latitude * .pi / 180)
        let Δλ = (b.longitude - a.longitude) * .pi / 180
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        let degrees = atan2(y, x) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    /// The point `metres` from `place` towards `bearing` (degrees from north).
    static func destination(from place: Place, metres: Double, bearing: Double) -> (latitude: Double, longitude: Double) {
        let δ = metres / earthRadius, θ = bearing * .pi / 180
        let φ1 = place.latitude * .pi / 180, λ1 = place.longitude * .pi / 180
        let φ2 = asin(sin(φ1) * cos(δ) + cos(φ1) * sin(δ) * cos(θ))
        let λ2 = λ1 + atan2(sin(θ) * sin(δ) * cos(φ1), cos(δ) - sin(φ1) * sin(φ2))
        return (φ2 * 180 / .pi, λ2 * 180 / .pi)
    }

    /// The eight-point compass word for a bearing (core's `compass_*` keys).
    static func compass8(_ degrees: Double) -> String {
        let points = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let index = Int((degrees / 45).rounded()) % 8
        return points[(index + 8) % 8]
    }

    /// How far a strike may lie from the counted distance, below and above
    /// it: 500 m or 15 %, whichever is more, plus the fix's own uncertainty
    /// (at most a kilometre). Wider below, because a count runs long more
    /// often than short: the tap comes late, or at the loud part of the rumble.
    static func tolerance(estimate: Double, accuracy: Double) -> (below: Double, above: Double) {
        let base = max(500, 0.15 * estimate) + min(max(accuracy, 0), 1_000)
        return (base * 1.5, base)
    }

    // MARK: Matching

    enum Quality: String, Equatable, Sendable {
        case close, fair, loose
    }

    struct Match: Equatable, Sendable {
        let strike: Strike
        /// From the user, metres.
        let distance: Double
        let bearing: Double
        /// The strike's time less the flash tap's: negative when it came first.
        let offset: TimeInterval
        /// Both residuals together, each 1 at the edge of what is allowed.
        let score: Double
        let quality: Quality
        /// How many strikes fitted.
        let candidates: Int
    }

    /// The strike that best fits a flash tapped at `flash` and a count of
    /// `estimate` metres, heard at `place`; nil when none fits. Each
    /// candidate is scored by its time against the expected one (half a
    /// second before the tap) and its distance against the count, each
    /// scaled to its tolerance. A close second elsewhere makes it less sure.
    static func match(flash: TimeInterval, estimate: Double, place: Place, strikes: [Strike]) -> Match? {
        let tolerance = tolerance(estimate: estimate, accuracy: place.accuracy)
        var scored: [(strike: Strike, distance: Double, score: Double)] = []
        for strike in strikes {
            let offset = strike.time - flash
            guard offset >= -windowBefore, offset <= windowAfter else { continue }
            let distance = metres(from: place, to: strike)
            let residual = distance - estimate
            let spatial = residual < 0 ? -residual / tolerance.below : residual / tolerance.above
            guard spatial <= 1 else { continue }
            let temporal = (offset + reaction) / timeScale
            scored.append((strike, distance, spatial * spatial + temporal * temporal))
        }
        // Ties go to the earlier strike, so the answer does not hang on the order strikes came in.
        scored.sort { $0.score != $1.score ? $0.score < $1.score : $0.strike.time < $1.strike.time }
        guard let best = scored.first else { return nil }
        var quality: Quality = best.score < 0.35 ? .close : best.score < 1.2 ? .fair : .loose
        if let second = scored.dropFirst().first, second.score - best.score < 0.25,
           metres(from: Place(latitude: best.strike.latitude, longitude: best.strike.longitude), to: second.strike) > 1_000 {
            quality = quality == .close ? .fair : .loose
        }
        return Match(strike: best.strike, distance: best.distance, bearing: bearing(from: place, to: best.strike),
                     offset: best.strike.time - flash, score: best.score, quality: quality, candidates: scored.count)
    }

    // MARK: The count

    /// One count, from the flash to the strike found: what the panel shows.
    /// The view feeds it the taps, the clock, the place and the strikes.
    struct Session: Equatable, Sendable {
        enum Phase: Equatable, Sendable {
            case idle
            /// Flash tapped, waiting for the thunder.
            case counting(flash: TimeInterval)
            case measured(Measurement)
            /// No thunder within `maxGap`.
            case tooFar
        }

        struct Measurement: Equatable, Sendable {
            let flash: TimeInterval
            let bang: TimeInterval
            let place: Place
            var match: Match?
            /// Still looking in the feed for the strike.
            var searching = true

            var gap: TimeInterval { bang - flash }
            var estimate: Double { distance(seconds: gap) }
            /// The strike's distance once found, else the count's.
            var best: Double { match?.distance ?? estimate }
            var withinStrikingRange: Bool { best < strikingRange }
        }

        enum Tap: Equatable, Sendable {
            case flash, bang, ignored
        }

        private(set) var phase: Phase = .idle

        init() {}

        /// A tap on the one target at `now`: the flash, then the thunder,
        /// heard at `place`. A tap after a result starts over.
        @discardableResult
        mutating func tap(now: TimeInterval, place: Place) -> Tap {
            if case .counting(let flash) = phase {
                let gap = now - flash
                if gap < debounce { return .ignored }
                if gap <= maxGap {
                    phase = .measured(Measurement(flash: flash, bang: now, place: place))
                    return .bang
                }
            }
            phase = .counting(flash: now)
            return .flash
        }

        /// Back to the start.
        mutating func reset() {
            phase = .idle
        }

        /// The clock moved or strikes came in: a count runs out, a search
        /// finds its strike or ends. True when anything changed.
        @discardableResult
        mutating func update(now: TimeInterval, strikes: [Strike]) -> Bool {
            switch phase {
            case .counting(let flash):
                guard now - flash > maxGap else { return false }
                phase = .tooFar
                return true
            case .measured(var measurement):
                guard measurement.searching else { return false }
                let before = measurement
                measurement.match = FlashToBangRules.match(flash: measurement.flash, estimate: measurement.estimate,
                                                           place: measurement.place, strikes: strikes) ?? measurement.match
                if now - measurement.bang >= searchFor { measurement.searching = false }
                phase = .measured(measurement)
                return measurement != before
            case .idle, .tooFar:
                return false
            }
        }

        var measurement: Measurement? {
            if case .measured(let measurement) = phase { return measurement }
            return nil
        }
    }

    // MARK: Text

    /// A number as the language writes it, to `digits` decimals.
    static func decimal(_ value: Double, digits: Int = 1, language: String) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: language)
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.\(digits)f", value)
    }

    /// Kilometres to one decimal.
    static func kilometres(_ metres: Double, language: String) -> String {
        decimal(metres / 1000, language: language)
    }
}
