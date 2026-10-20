//
//  PointFeature.swift
//  meteocool
//
//  A hold on the radar map and what it leads to: the menu (core's
//  `PointMenu.svelte`), the inspected point and its ring
//  (`inspectLatLon`), a link to the place, and the model comparison.
//

import Combine
import MapKit
import SwiftUI
import UIKit

@MainActor
final class PointFeature: NativeMapFeature {
    private weak var map: NativeMapContext?
    private var overlay: PointMenuOverlay?
    private var menu: PointMenuModel?
    private var menuAt: CLLocationCoordinate2D?
    private let ring = InspectedPointAnnotation()
    private var ringShown = false
    private var compare: ModelCompareDrawer?
    private var outlook: DryOutlookDock?
    private var observers = Set<AnyCancellable>()

    func attach(to map: NativeMapContext) {
        self.map = map
        map.mapView.register(InspectRingView.self, forAnnotationViewWithReuseIdentifier: InspectRingView.reuse)
        compare = ModelCompareDrawer(map: map)
        outlook = DryOutlookDock(map: map) { [weak self] coordinate, hours in self?.openCompare(at: coordinate, hours: hours) }
        map.model.$point
            .sink { [weak self] point in DispatchQueue.main.async { self?.showRing(point) } }
            .store(in: &observers)
        // A storm tapped, or another map: the question is somewhere else.
        map.model.$selectedStorm
            .sink { [weak self] storm in
                guard storm != nil else { return }
                DispatchQueue.main.async {
                    self?.closeMenu()
                    self?.compare?.close()
                }
            }
            .store(in: &observers)
        map.player.$playing
            .sink { [weak self] playing in if playing { DispatchQueue.main.async { self?.compare?.close() } } }
            .store(in: &observers)
    }

    // MARK: - The hold

    func didLongPress(at coordinate: CLLocationCoordinate2D) -> Bool {
        guard let map, map.model.capability == .radar else { return false }
        openMenu(at: coordinate)
        return true
    }

    func regionWillChange() {
        // The point is under the finger that held it; once the map moves it is not.
        closeMenu()
    }

    func capabilityDidChange(_ capability: NativeMapModel.Capability) {
        closeMenu()
        if capability != .radar { compare?.close() }
        showRing(map?.model.point)
    }

    func stop() {
        closeMenu()
    }

    private func openMenu(at coordinate: CLLocationCoordinate2D) {
        guard let map else { return }
        closeMenu()
        // A storm's selection and a point's menu do not stand together.
        map.model.selectedStorm = nil
        let point = map.mapView.convert(coordinate, toPointTo: map.view)
        let placement = PointMenuLayout.placement(x: point.x, y: point.y, width: map.view.bounds.width, shareAvailable: true)
        let menu = PointMenuModel(placement: placement, shareAvailable: true,
                                  onRadar: { [weak self] in self?.inspect(coordinate) },
                                  onForecast: { [weak self] in
                                      self?.closeMenu()
                                      self?.openCompare(at: coordinate, hours: 24)
                                  },
                                  onShare: { [weak self] in self?.sharePoint(coordinate) })
        let overlay = PointMenuOverlay(frame: map.view.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.onClose = { [weak self] in self?.closeMenu() }
        let host = UIHostingController(rootView: PointMenuView(menu: menu).environment(\.colorScheme, map.model.isDark ? .dark : .light))
        host.view.backgroundColor = .clear
        host.sizingOptions = .intrinsicContentSize
        map.view.addSubview(overlay)
        overlay.place(host.view, at: point, placement: placement)
        overlay.becomeFirstResponder()
        self.overlay = overlay
        self.menu = menu
        menuAt = coordinate
        // The app's buttons in the top corner can be under it; they go while it is up.
        map.model.covers.insert("pointMenu")
        UIAccessibility.post(notification: .screenChanged, argument: host.view)
        let language = CoreStrings.language
        Task { [weak self, weak menu] in
            let name = await ReverseGeocoder.shared.name(latitude: coordinate.latitude, longitude: coordinate.longitude, language: language)
            guard let self, let menu, self.menu === menu else { return }
            menu.place = name
        }
    }

    private func closeMenu() {
        guard let overlay else { return }
        self.overlay = nil
        menu = nil
        menuAt = nil
        map?.model.covers.remove("pointMenu")
        UIView.animate(withDuration: 0.12, animations: { overlay.alpha = 0 }) { _ in overlay.removeFromSuperview() }
    }

    // MARK: - The inspected point

    /// "Radar": the bars and the readings are for the point now (`inspectLatLon`).
    private func inspect(_ coordinate: CLLocationCoordinate2D) {
        closeMenu()
        guard let map else { return }
        map.model.point = coordinate
        map.radar.point = coordinate
    }

    private func showRing(_ point: CLLocationCoordinate2D?) {
        guard let mapView = map?.mapView else { return }
        let wanted = point != nil && map?.model.capability == .radar
        if let point { ring.coordinate = point }
        if wanted != ringShown {
            ringShown = wanted
            if wanted { mapView.addAnnotation(ring) } else { mapView.removeAnnotation(ring) }
        }
    }

    func view(for annotation: MKAnnotation, in mapView: MKMapView) -> MKAnnotationView? {
        annotation === ring ? mapView.dequeueReusableAnnotationView(withIdentifier: InspectRingView.reuse, for: annotation) : nil
    }

    // MARK: - Links

    /// A link to the map on the point, with its precipitation open, as
    /// "Radar" opens it here.
    private func sharePoint(_ coordinate: CLLocationCoordinate2D) {
        guard let map else { return }
        let source = overlay?.card
        let place = menu?.place
        map.shareMap(title: place.map { CoreStrings.t("share.title_about", ["subject": $0]) } ?? CoreStrings.t("share.title"),
                     source: source, center: coordinate,
                     extra: ["point": PointLink.pair(latitude: coordinate.latitude, longitude: coordinate.longitude)])
        closeMenu()
    }

    func open(_ link: [String: String]) -> Bool {
        guard let pair = PointLink.parsePair(link["point"]), let map else { return false }
        let coordinate = CLLocationCoordinate2D(latitude: pair.latitude, longitude: pair.longitude)
        map.model.point = coordinate
        map.radar.point = coordinate
        return false
    }

    func linkParameters() -> [String: String] {
        guard let point = map?.model.point else { return [:] }
        return ["point": PointLink.pair(latitude: point.latitude, longitude: point.longitude)]
    }

    // MARK: - Model comparison

    private func openCompare(at coordinate: CLLocationCoordinate2D, hours: Int) {
        guard let map else { return }
        map.model.selectedStorm = nil
        compare?.open(latitude: coordinate.latitude, longitude: coordinate.longitude, hours: hours)
    }

    func wake() {
        outlook?.wake()
    }

    func tick() {
        outlook?.update()
    }

    func stepDidChange(_ step: RadarStep) {
        outlook?.update()
    }
}
