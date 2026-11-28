//
//  CloudStyle.swift
//  meteocool
//
//  How the 3D map draws its storms: core's `lib/cloudStyle.ts`.
//
//  No app dependencies here: `scripts/check.sh` and `scripts/check-ar.sh`
//  compile this file alone.
//

/// How the 3D map draws a storm's volume: the same field, two pictures of
/// it (core's `CloudStyle`).
///
/// - `cloud`: a lit, soft cloud of everything from light rain up. What a
///   storm looks like from outside; its core shows once it peels or is cut.
/// - `glow`: the field as light, unlit and see-through, from the faintest
///   echo up. Every reflectivity keeps its own colour, so the core shows
///   through the envelope around it.
///
/// Core's third, `shells` (a surface at every tenth dBZ, nested), is not
/// offered: core took it off its map again two commits on (`c7fc1307`, kept
/// to its Studio), since a storm left whole is only its outermost shell. A
/// link naming it opens the cloud, as core's map does now.
enum CloudStyle: String, CaseIterable, Sendable {
    case cloud, glow

    static let `default` = CloudStyle.cloud

    /// The style a stored setting or a link names; the default for anything else (`cloudStyleOf`).
    static func of(_ value: String?) -> CloudStyle {
        value.flatMap(CloudStyle.init(rawValue:)) ?? .default
    }

    /// The weakest echo it shows, in dBZ, and where its peel starts from
    /// (`STYLE_FIELD`).
    var floor: Double {
        switch self {
        case .cloud: 20
        case .glow: 5
        }
    }

    /// How many dBZ above `floor` the echo takes to reach its full opacity.
    var band: Double {
        switch self {
        case .cloud: 14
        case .glow: 45
        }
    }
}
