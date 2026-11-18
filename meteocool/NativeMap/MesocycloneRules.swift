//
//  MesocycloneRules.swift
//  meteocool
//
//  A mesocyclone as the map draws it, and as a tap finds the storm it turns
//  in: core's `lib/mesocyclones.ts`, rule for rule.
//

import Foundation

// No app dependencies here: `scripts/check.sh` compiles this file alone.

/// A storm still being tracked, where it is drawn now (core's `LiveStorm`).
struct LiveStorm: Equatable, Sendable {
    var storm: String
    var coordinates: LonLat
}

/// DWD's detections name no storm, only a place and an intensity. A tap on
/// one is taken for the tracked storm nearest it, so that what a reader
/// reaches for when a storm rotates (its ring) opens that storm, and with it
/// the motion storm-relative velocity takes out.
enum MesocycloneRules {
    /// The mark's size class by intensity, in the units the icon is scaled by.
    static func size(_ intensity: Int) -> Double {
        if intensity > 4 { return 55 }
        if intensity > 3 { return 46 }
        if intensity > 2 { return 38 }
        if intensity > 1 { return 30 }
        return 22
    }

    /// The icon's scale for an intensity.
    static func scale(_ intensity: Int) -> Double { 0.2 * (size(intensity) / 40) }

    /// The icon's width in its own pixels (`MapMesocyclone`, core's `assets/mesocyclone.png`).
    static let iconPx = 183.0

    /// How far from its centre the mark reaches on screen, points: a tap
    /// anywhere on the ring, or in it.
    static func radiusPx(_ intensity: Int) -> Double { iconPx * scale(intensity) / 2 }

    /// How far from a storm's centre a mesocyclone may be and still be taken
    /// for its own: a supercell's updraft sits within a few kilometres of the
    /// cell's centroid, and the two are measured minutes apart.
    static let stormWithinM = 15_000.0

    /// The tracked storm nearest a mesocyclone at `lon`, `lat`, within
    /// `withinM`; nil with none that near.
    static func stormAt(_ storms: [LiveStorm], lon: Double, lat: Double, withinM: Double = stormWithinM) -> String? {
        var best: String?
        var bestM = withinM
        for live in storms {
            let groundM = groundDistanceM(live.coordinates, LonLat(lon, lat))
            if groundM <= bestM {
                best = live.storm
                bestM = groundM
            }
        }
        return best
    }

    /// Great-circle distance, metres (core's `fromSite` in `lib/sweepGeometry.ts`).
    static func groundDistanceM(_ a: LonLat, _ b: LonLat) -> Double {
        let rad = Double.pi / 180
        let phi1 = a.lat * rad, phi2 = b.lat * rad
        let dPhi = phi2 - phi1
        let dLambda = (b.lon - a.lon) * rad
        let h = pow(sin(dPhi / 2), 2) + cos(phi1) * cos(phi2) * pow(sin(dLambda / 2), 2)
        return 2 * 6_371_000 * asin(min(1, h.squareRoot()))
    }
}
