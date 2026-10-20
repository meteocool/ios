//
//  NativeMapFeature.swift
//  meteocool
//
//  How the native map's parts plug into it.
//

import MapKit
import SwiftUI
import UIKit

/// What the native map hands to its parts: the map, its shared state, where
/// data comes from, and the app around it.
@MainActor
protocol NativeMapContext: AnyObject {
    var mapView: MKMapView { get }
    var model: NativeMapModel { get }
    var player: RadarPlayer { get }
    var endpoints: NativeMapEndpoints { get }
    /// The app around the map: sheets, covers, AR, sharing.
    var host: NativeMapHost? { get }
    /// OpenLayers' zoom of the view, as core's links and rules use it.
    var zoomLevel: Double { get }
    /// The radar composite on screen and the ground each network covers.
    var radar: RadarEngine { get }
    /// A stored layer switch (`nativeMap.<name>`), on unless turned off.
    func isOn(_ layer: NativeMapLayer) -> Bool
    /// GET `url`; `handler` gets 2xx bodies on the main actor, nil otherwise.
    func fetch(_ url: URL, _ handler: @escaping @MainActor (Data?, Int?) -> Void)
    /// Moves the map to a view, as a link does.
    func place(_ link: NativeMapLink, animated: Bool)
}

/// One part of the native map: an overlay, marks, a sheet, a capability.
/// Every hook is optional; the map calls them in the order parts were added.
@MainActor
protocol NativeMapFeature: AnyObject {
    func attach(to map: NativeMapContext)
    func renderer(for overlay: MKOverlay) -> MKOverlayRenderer?
    func view(for annotation: MKAnnotation, in mapView: MKMapView) -> MKAnnotationView?
    /// An annotation was tapped; true when this part handled it.
    func didSelect(_ annotation: MKAnnotation) -> Bool
    /// The map was tapped away from any annotation; true when handled.
    func didTap(at coordinate: CLLocationCoordinate2D, point: CGPoint) -> Bool
    /// A long press on the map; true when handled.
    func didLongPress(at coordinate: CLLocationCoordinate2D) -> Bool
    func regionDidChange()
    /// The step on screen changed (also when the timeline was replaced).
    func stepDidChange(_ step: RadarStep)
    /// Everything should be fetched again: launch, foreground, reconnect.
    func wake()
    /// Every 30 s while the map runs.
    func tick()
    /// A socket.io event on `/radar` (core's `api/events.ts`).
    func socketEvent(_ name: String, _ data: Data)
    /// Stored settings or layer switches changed.
    func settingsDidChange()
    /// The map was put away or the app went to the background.
    func stop()
}

extension NativeMapFeature {
    func attach(to map: NativeMapContext) {}
    func renderer(for overlay: MKOverlay) -> MKOverlayRenderer? { nil }
    func view(for annotation: MKAnnotation, in mapView: MKMapView) -> MKAnnotationView? { nil }
    func didSelect(_ annotation: MKAnnotation) -> Bool { false }
    func didTap(at coordinate: CLLocationCoordinate2D, point: CGPoint) -> Bool { false }
    func didLongPress(at coordinate: CLLocationCoordinate2D) -> Bool { false }
    func regionDidChange() {}
    func stepDidChange(_ step: RadarStep) {}
    func wake() {}
    func tick() {}
    func socketEvent(_ name: String, _ data: Data) {}
    func settingsDidChange() {}
    func stop() {}
}

/// The step on screen, as parts need to know it.
struct RadarStep: Equatable {
    /// Unix second, nil before the timeline has loaded.
    let time: Int?
    /// The newest observation: what core calls live.
    let isLive: Bool
    let isForecast: Bool
}

/// The app around the native map (`ViewController`).
@MainActor
protocol NativeMapHost: AnyObject {
    /// Presents a sheet or page over the map.
    func presentOverMap(_ controller: UIViewController)
    /// Hides the app's own controls while something of the map's covers them.
    func mapCovered(_ covered: Bool, by owner: String)
    /// Opens the AR view at a storm, where it is offered.
    func openAR(_ target: StormTarget?)
    /// The share sheet for a link, pointing at `source` on an iPad.
    func shareFromMap(_ share: MapShare, source: UIView?)
    /// Whether the AR view can be offered.
    var arAvailable: Bool { get }
}

/// The layer switches the native map stores (`nativeMap.<rawValue>`).
enum NativeMapLayer: String, CaseIterable {
    case lightning, mesocyclones, storms, nowcast, snow, cells3d, terrain3d

    /// Whether it is on before the user has chosen.
    var defaultOn: Bool { true }
}
