//
//  ThreeDFraming.swift
//  meteocool
//
//  Where to stand to look at an opened storm, and how the slice turns.
//

import Foundation

/// The part of the screen an opened storm is framed into, in points.
struct FramingRoom: Equatable, Sendable {
    var width: Double
    var height: Double
    var top: Double
    var bottom: Double
    var left: Double
    var right: Double

    /// core's `OPEN_TOP_PX`, `OPEN_SHEET_FRACTION`, `OPEN_PANEL_PX`,
    /// `OPEN_PANEL_MARGIN_PX`, `OPEN_TRAY_PX` (`Cells3DCapability.ts`).
    static let top = 64.0
    static let sheetFraction = 0.32
    static let panel = 392.0
    static let panelMargin = 12.0
    static let tray = 88.0

    /// A phone's room: above the sheet at rest. A wide screen's: left of the
    /// panel, above the tray.
    static func of(width: Double, height: Double, phone: Bool) -> FramingRoom {
        if phone {
            return FramingRoom(width: width, height: height, top: top, bottom: height * (1 - sheetFraction), left: 0, right: width)
        }
        let panelWidth = min(panel, width - 2 * panelMargin) + 2 * panelMargin
        return FramingRoom(width: width, height: height, top: top, bottom: height - tray, left: 0,
                           right: max(width - panelWidth, width / 2))
    }
}

/// core's `lib/stormFrame.ts` `framingCamera`.
///
/// No app dependencies here: `scripts/check.sh` compiles this file alone.
enum StormFraming {
    /// How much of the room the storm is given.
    static let openFill = 0.9
    static let worldMetresAtZoom0 = 40_075_016.686 / 512
    static let kmPerDegree = 111.32

    struct Camera: Equatable {
        var lon: Double
        var lat: Double
        /// MapLibre's zoom.
        var zoom: Double
        /// How far right of and below the middle of the screen the centre is drawn.
        var offsetX: Double
        var offsetY: Double
    }

    /// Where to stand for a storm's cut, running along `directionDeg`, to
    /// fill the room, square on and from low down.
    static func camera(lon boxLon: Double, lat boxLat: Double, extentM: SIMD3<Double>, extent: StormExtent,
                       directionDeg: Double, room: FramingRoom, pitchDeg: Double = MapCamera.openPitch,
                       maxZoom: Double = MapCamera.maxZoom, verticalScale: Double = Mercator.verticalScale) -> Camera {
        let latRad = boxLat * .pi / 180
        let lon = boxLon + extent.centreKm.x / (kmPerDegree * cos(latRad))
        let lat = boxLat + extent.centreKm.y / kmPerDegree
        let along = directionDeg * .pi / 180
        let widthM = 2000 * (extent.halfKm.x * abs(sin(along)) + extent.halfKm.y * abs(cos(along)))
        let heightM = (extentM.z / 2 + 1000 * (extent.centreKm.z + extent.halfKm.z)) * verticalScale
        let tilt = pitchDeg * .pi / 180
        let atFoot = max(widthM / ((room.right - room.left) * openFill),
                         heightM * sin(tilt) / ((room.bottom - room.top) * openFill))
        let foot = (room.top + room.bottom) / 2 + heightM * sin(tilt) / atFoot / 2
        let focal = room.height / 2 / tan(MapCamera.fov / 2)
        let above = atan((room.height / 2 - foot) / focal)
        let atMiddle = atFoot * cos(tilt + above) / cos(tilt)
        let zoom = min(log2(worldMetresAtZoom0 * cos(latRad) / atMiddle), maxZoom)
        return Camera(lon: lon, lat: lat, zoom: zoom, offsetX: (room.left + room.right) / 2 - room.width / 2,
                      offsetY: foot - room.height / 2)
    }

    /// Which way to face the cut: the side of the plane nearer the current
    /// bearing, keeping the turn within a quarter (`frameOpened`). Returns
    /// the turn from the bearing and whether the cut flipped half round.
    static func facing(direction: Double, bearing: Double) -> (off: Double, flipped: Bool) {
        let offFacing = CloudMath.normaliseCut(direction - 90 - bearing)
        let offFlipped = CloudMath.normaliseCut(direction + 90 - bearing)
        return abs(offFlipped) < abs(offFacing) ? (offFlipped, true) : (offFacing, false)
    }

    /// Whether the camera is still about where `framed` left it (`stillAt`,
    /// `CAMERA_KEPT`): a nudge, not a view of the reader's own.
    static func stillAt(_ camera: MapCamera, _ framed: MapCamera) -> Bool {
        let turned = abs((camera.bearing - framed.bearing + 540).truncatingRemainder(dividingBy: 360) - 180)
        let p = Mercator.point(lon: framed.lon, lat: framed.lat)
        let at = camera.project(SIMD3(p.x, p.y, camera.elevationMercator)).point
        let shift = hypot(at.x - camera.width / 2, at.y - camera.height / 2) / min(camera.width, camera.height)
        return abs(camera.zoom - framed.zoom) <= 0.5 && turned <= 10 && abs(camera.pitch - framed.pitch) <= 4 && shift <= 0.1
    }
}

/// The slice swinging through an opened storm on its own (core's `lib/cutSweep.ts`).
enum CutSweep {
    static let amplitude = 70.0
    static let period = 24.0
    static let swings = 2.0
    static let fps = 20.0

    /// The swing at `seconds` since it started, nil once it has come to rest.
    static func angle(at seconds: Double) -> Double? {
        guard seconds < swings * period else { return nil }
        return amplitude * sin(seconds / period * 2 * .pi)
    }
}

/// The dial's physics (core's `components/SliceDial.svelte`).
enum SliceDialMath {
    static let pointsPerDegree = 2.4
    static let friction = 0.0045
    static let stopSpeed = 0.02
    static let snapDegrees = 7.0

    /// Where a released dial comes to rest: on an axis within 7°, else on a whole degree.
    static func settle(_ angle: Double) -> Double {
        let axis = (angle / 90).rounded() * 90
        return abs(angle - axis) <= snapDegrees ? axis : angle.rounded()
    }

    /// The reset: the nearest half turn.
    static func reset(_ angle: Double) -> Double { (angle / 180).rounded() * 180 }

    /// Whether a slice lies off both axes, so the reset chip shows.
    static func offAxis(_ shown: Double) -> Bool {
        abs(CloudMath.normaliseCut(shown)).truncatingRemainder(dividingBy: 180) >= 1
    }
}
