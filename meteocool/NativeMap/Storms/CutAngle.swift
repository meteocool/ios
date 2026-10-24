//
//  CutAngle.swift
//  meteocool
//
//  The slice through an open storm, as words and arithmetic (core's
//  `lib/cutAngle.ts`, and the `cut` of `lib/deepLink.ts`).
//

import Foundation

/// The cut's angle as words and arithmetic (core's `lib/cutAngle.ts`).
enum CutAngle {
    /// What the angle is measured from: the storm's track, or north for a
    /// core with none, whose direction of travel nobody measured.
    enum Reference {
        case track
        case north
    }

    /// Folded into -180 ..< 180: a cut turned half way round is the same
    /// cut, seen from its other side.
    static func normalise(_ degrees: Double) -> Double {
        let folded = ((degrees + 180).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) - 180
        return folded == 0 ? 0 : folded
    }

    /// What the caption says about the slice, named by its angle to the
    /// track (or north); 0 and 180 read the same.
    static func label(_ degrees: Double, reference: Reference, _ t: StormTranslate = { CoreStrings.t($0, $1) }) -> String {
        let off = abs(normalise(degrees))
        let toAxis = min(off, 180 - off)
        let deg = Int(toAxis.rounded())
        switch reference {
        case .north:
            if toAxis < 1 { return t("storm.cut.north_south", [:]) }
            if abs(toAxis - 90) < 1 { return t("storm.cut.east_west", [:]) }
            return t("storm.cut.off_north", ["deg": deg])
        case .track:
            if toAxis < 1 { return t("storm.cut.along", [:]) }
            if abs(toAxis - 90) < 1 { return t("storm.cut.across", [:]) }
            return t("storm.cut.off_track", ["deg": deg])
        }
    }

    /// The two snap buttons' labels.
    static func snapLabels(_ reference: Reference, _ t: StormTranslate = { CoreStrings.t($0, $1) }) -> (String, String) {
        switch reference {
        case .north: (t("storm.cut.snap_ns", [:]), t("storm.cut.snap_ew", [:]))
        case .track: (t("storm.cut.snap_along", [:]), t("storm.cut.snap_across", [:]))
        }
    }

    /// A link's `cut`, or nil for none or nonsense.
    static func fromLink(_ text: String?) -> Double? {
        guard let text, let value = Double(text), value.isFinite else { return nil }
        return normalise(value.rounded())
    }

    /// The `cut` a link carries: whole degrees, and nothing for a cut along
    /// the track, which is where every storm opens anyway.
    static func toLink(_ degrees: Double) -> String? {
        let whole = normalise(degrees.rounded())
        return whole == 0 ? nil : String(Int(whole))
    }
}
