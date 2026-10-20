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
    /// Stores a layer switch; every part hears it as a settings change.
    func setOn(_ layer: NativeMapLayer, _ on: Bool)
    /// GET `url`; `handler` gets 2xx bodies on the main actor, nil otherwise.
    func fetch(_ url: URL, _ handler: @escaping @MainActor (Data?, Int?) -> Void)
    /// Moves the map to a view, as a link does.
    func place(_ link: NativeMapLink, animated: Bool)
    /// The view the map's parts add controls to (`addChrome`), above the map.
    var view: UIView { get }
    /// Hosts a SwiftUI control over the map, sized to fit; the caller places
    /// it against `view`'s anchors.
    @discardableResult
    func addChrome<Content: View>(_ content: Content) -> UIView
    /// Hosts a SwiftUI bar in the dock above the tray, over core's strips
    /// (`SwipeDock`); the caller shows and hides it with `isHidden`.
    @discardableResult
    func addToDock<Content: View>(_ content: Content) -> UIView
    /// Switches between core's maps (`lm.setTarget`).
    func setCapability(_ capability: NativeMapModel.Capability)
    /// A link's query, handed to every part as a link opening the map is
    /// (`storm`, `cell`, `point`, …), without moving the map.
    func openLink(_ parameters: [String: String])
    /// The share sheet for a link to what is on screen, under `title`;
    /// centred on `center` when given, with `extra` added to the query.
    func shareMap(title: String, source: UIView?, center: CLLocationCoordinate2D?, extra: [String: String])
}

extension NativeMapContext {
    func shareMap(title: String, source: UIView?) {
        shareMap(title: title, source: source, center: nil, extra: [:])
    }
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
    /// The map is about to move (a pan, a zoom, a link).
    func regionWillChange()
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
    /// Another of core's maps is shown (`NativeMapModel.capability`).
    func capabilityDidChange(_ capability: NativeMapModel.Capability)
    /// A link's query (core's `lib/deepLink.ts`: `storm`, `cell`, `cloud`,
    /// `point`, …), every part in turn; true when this part took it.
    func open(_ link: [String: String]) -> Bool
    /// What this part adds to a link to the map on screen.
    func linkParameters() -> [String: String]
    /// Where a link to the map on screen looks, where this part draws the
    /// map instead of the flat one (the 3D map's camera); nil otherwise.
    func linkView() -> NativeMapLink?
}

extension NativeMapFeature {
    func attach(to map: NativeMapContext) {}
    func renderer(for overlay: MKOverlay) -> MKOverlayRenderer? { nil }
    func view(for annotation: MKAnnotation, in mapView: MKMapView) -> MKAnnotationView? { nil }
    func didSelect(_ annotation: MKAnnotation) -> Bool { false }
    func didTap(at coordinate: CLLocationCoordinate2D, point: CGPoint) -> Bool { false }
    func didLongPress(at coordinate: CLLocationCoordinate2D) -> Bool { false }
    func regionWillChange() {}
    func regionDidChange() {}
    func stepDidChange(_ step: RadarStep) {}
    func wake() {}
    func tick() {}
    func socketEvent(_ name: String, _ data: Data) {}
    func settingsDidChange() {}
    func stop() {}
    func capabilityDidChange(_ capability: NativeMapModel.Capability) {}
    func open(_ link: [String: String]) -> Bool { false }
    func linkParameters() -> [String: String] { [:] }
    func linkView() -> NativeMapLink? { nil }
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
    /// Presents a sheet or page over the map; false when something else is
    /// already up.
    @discardableResult
    func presentOverMap(_ controller: UIViewController) -> Bool
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
    case lightning, mesocyclones, storms, snow, cells3d, terrain3d

    /// Whether it is on before the user has chosen: as core's settings
    /// (`layer3dCells` off, the rest on).
    var defaultOn: Bool { self != .cells3d }
}
