//
//  StationMarks.swift
//  meteocool
//
//  DWD's weather stations over the radar map (core's `layers/stations.ts`
//  and `lib/StationManager.ts`): a WMO wind barb at each for the wind and the
//  gusts, a number for everything else, thinned further out than zoom 8,
//  greyed on a forecast frame, and a station's sheet when one is tapped.
//

import Combine
import MapKit
import SwiftUI
import UIKit

/// The stations' state, for the tray's picker.
@MainActor
final class StationState: ObservableObject {
    /// Which parameter they show, kept (core's `stationParameter`).
    @Published var choice = StationRules.parseChoice(StationState.defaults?.string(forKey: StationState.choiceKey)) {
        didSet { StationState.defaults?.set(choice.rawValue, forKey: StationState.choiceKey) }
    }
    /// When the newest of the stations on the map measured; nil for none.
    @Published fileprivate(set) var observedAt: Date?
    /// Whether an answer is in, so "no observations" means none.
    @Published fileprivate(set) var answered = false

    private static let choiceKey = "nativeMap.stationParameter"
    private static let defaults = UserDefaults(suiteName: "group.org.frcy.app.meteocool")
}

/// A station on the map, as the choice draws it.
final class StationAnnotation: NSObject, MKAnnotation {
    let station: ObservedStation
    let choice: StationChoice
    let coordinate: CLLocationCoordinate2D

    init(_ station: ObservedStation, choice: StationChoice) {
        self.station = station
        self.choice = choice
        coordinate = CLLocationCoordinate2D(latitude: station.lat, longitude: station.lon)
    }
}

/// A barb or a number, drawn once per look and kept.
final class StationMarkView: MKAnnotationView {
    static let reuse = "station"
    private static var images: [String: UIImage] = [:]

    var dark = false
    var stale = false
    var palette = "classic"
    var heading: CGFloat = 0 { didSet { transform = CGAffineTransform(rotationAngle: -heading * .pi / 180) } }

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        displayPriority = .required
        collisionMode = .none
        canShowCallout = false
        // Over the radar, under the storm marks (850): a storm is what is tapped where both are.
        zPriority = MKAnnotationViewZPriority(rawValue: 500)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var annotation: MKAnnotation? { didSet { update() } }

    func update() {
        guard let mark = annotation as? StationAnnotation else { return }
        let choice = mark.choice, station = mark.station
        let ink = dark ? UIColor(white: 0.95, alpha: 1) : UIColor(red: 0.067, green: 0.078, blue: 0.102, alpha: 1)
        let casing = dark ? UIColor(red: 0.067, green: 0.078, blue: 0.102, alpha: 0.85) : UIColor(white: 1, alpha: 0.9)
        var label = station.name
        if StationRules.isWind(choice), let wind = StationRules.wind(choice, station) {
            let shape = WindBarb.shape(knots: wind.knots, fromDeg: wind.fromDeg)
            let key = "barb:\(WindBarb.roundKnots(wind.knots)):\(Int(wind.fromDeg.rounded())):\(dark)"
            image = Self.images[key] ?? Self.cache(key, Self.drawBarb(shape, ink: ink, casing: casing))
            label += ", \(Int(WindBarb.roundKnots(wind.knots))) kt, \(Int(wind.fromDeg.rounded()))°"
        } else if let value = StationRules.value(choice, station) {
            var colour: UIColor?
            if !stale, choice == .temperature { colour = Self.rgb(StationRules.temperatureColour(value)) }
            if choice == .precipitation {
                if let dbz = StationRules.precipitationDbz(value) {
                    if !stale, let rgb = RadarPalette.colour(dbz: dbz, palette: palette) {
                        colour = UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
                    }
                } else {
                    // A gauge that measured nothing: a small ring, so the network still shows.
                    let key = "dry:\(dark)"
                    image = Self.images[key] ?? Self.cache(key, Self.drawDry(ink: ink, casing: casing))
                    accessibilityLabel = label + ", 0 mm"
                    accessibilityIdentifier = "nativeMap.station.\(station.id)"
                    alpha = stale ? 0.45 : 1
                    return
                }
            }
            let text = StationRules.formatValue(choice, value, language: CoreStrings.language)
            let key = "text:\(text):\(colour?.description ?? "ink"):\(dark)"
            image = Self.images[key] ?? Self.cache(key, Self.drawText(text, fill: colour ?? ink,
                                                                     halo: colour == nil ? casing : UIColor(red: 0.047, green: 0.063, blue: 0.086, alpha: 0.85)))
            label += ", " + text
        } else {
            image = nil
        }
        alpha = stale ? 0.45 : 1
        accessibilityLabel = label
        accessibilityIdentifier = "nativeMap.station.\(station.id)"
    }

    private static func cache(_ key: String, _ image: UIImage) -> UIImage {
        if images.count > 600 { images.removeAll() }
        images[key] = image
        return image
    }

    private static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// A barb (or the calm circle) on a square of its own, the station in its middle.
    private static func drawBarb(_ shape: WindBarb.Shape, ink: UIColor, casing: UIColor) -> UIImage {
        let reach: Double
        switch shape {
        case .calm(let radius): reach = radius
        case .barb(_, let shaft, let feathers, let pennants):
            let points = [shaft.0, shaft.1] + feathers.flatMap { [$0.0, $0.1] } + pennants.flatMap { [$0.0, $0.1, $0.2] }
            reach = points.map { max(abs($0.x), abs($0.y)) }.max() ?? 0
        }
        let half = CGFloat((reach + 3).rounded(.up))
        return UIGraphicsImageRenderer(size: CGSize(width: half * 2, height: half * 2)).image { context in
            let cg = context.cgContext
            cg.translateBy(x: half, y: half)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            // Twice: the casing wide underneath, then the ink.
            for (colour, width) in [(casing, 3.4), (ink, 1.5)] {
                cg.setStrokeColor(colour.cgColor)
                cg.setFillColor(colour.cgColor)
                cg.setLineWidth(width)
                switch shape {
                case .calm(let radius):
                    cg.strokeEllipse(in: CGRect(x: -radius, y: -radius, width: 2 * radius, height: 2 * radius))
                case .barb(_, let shaft, let feathers, let pennants):
                    for (a, b) in [shaft] + feathers {
                        cg.move(to: CGPoint(x: a.x, y: a.y))
                        cg.addLine(to: CGPoint(x: b.x, y: b.y))
                    }
                    cg.strokePath()
                    for (a, b, c) in pennants {
                        cg.move(to: CGPoint(x: a.x, y: a.y))
                        cg.addLine(to: CGPoint(x: b.x, y: b.y))
                        cg.addLine(to: CGPoint(x: c.x, y: c.y))
                        cg.closePath()
                        cg.drawPath(using: .fillStroke)
                    }
                    let dot: CGFloat = width == 1.5 ? 2 : 3
                    cg.fillEllipse(in: CGRect(x: -dot, y: -dot, width: 2 * dot, height: 2 * dot))
                }
            }
        }
    }

    private static func drawText(_ text: String, fill: UIColor, halo: UIColor) -> UIImage {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 14, weight: .bold),
            .foregroundColor: fill,
            .strokeColor: halo,
            .strokeWidth: -3.5,
        ]
        let string = text as NSString
        let size = string.size(withAttributes: attributes)
        return UIGraphicsImageRenderer(size: CGSize(width: size.width + 4, height: size.height + 2)).image { _ in
            string.draw(at: CGPoint(x: 2, y: 1), withAttributes: attributes)
        }
    }

    private static func drawDry(ink: UIColor, casing: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 9, height: 9)).image { context in
            let ring = CGRect(x: 2, y: 2, width: 5, height: 5)
            context.cgContext.setFillColor(casing.cgColor)
            context.cgContext.fillEllipse(in: ring)
            context.cgContext.setStrokeColor(ink.cgColor)
            context.cgContext.setLineWidth(1)
            context.cgContext.strokeEllipse(in: ring)
        }
    }
}

@MainActor
final class StationMarks: NativeMapFeature {
    private weak var map: NativeMapContext?
    private var stations: [ObservedStation] = []
    private var drawnChoice: StationChoice?
    private var marks: [String: StationAnnotation] = [:]
    private var shown = false
    private var stale = false
    private var at: Int?
    private var lastFetch = Date.distantPast
    private var generation = 0
    private var scrub: Timer?
    private var observers = Set<AnyCancellable>()

    private var state: StationState? { map?.model.stations }

    func attach(to map: NativeMapContext) {
        self.map = map
        map.mapView.register(StationMarkView.self, forAnnotationViewWithReuseIdentifier: StationMarkView.reuse)
        map.model.stations.$choice.dropFirst().removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.fetch() } }
            .store(in: &observers)
        map.model.$isDark.dropFirst().removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.restyle() } }
            .store(in: &observers)
        settingsDidChange()
    }

    func settingsDidChange() {
        guard let map else { return }
        let next = map.isOn(.stations) && map.model.capability == .radar
        if next != shown {
            shown = next
            if shown { fetch() } else { clear() }
        } else if shown {
            restyle()
        }
    }

    func capabilityDidChange(_ capability: NativeMapModel.Capability) { settingsDidChange() }

    func wake() { if shown { fetch() } }

    func tick() {
        if shown, Date().timeIntervalSince(lastFetch) >= StationRules.refreshSeconds { fetch() }
    }

    /// The frame on screen: greyed at once on a forecast frame; asked about
    /// once the scrub comes to rest there.
    func stepDidChange(_ step: RadarStep) {
        guard let map else { return }
        let newest = map.player.timeline.now ?? 0
        let shownAt = step.time ?? 0
        let following = step.isLive
        let nextStale = !following && StationRules.stale(shown: shownAt, newest: newest)
        if nextStale != stale {
            stale = nextStale
            restyle()
        }
        let nextAt = following ? nil : StationRules.at(shown: shownAt, newest: newest)
        scrub?.invalidate()
        scrub = Timer.scheduledTimer(withTimeInterval: StationRules.scrubDebounce, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, nextAt != self.at else { return }
                self.at = nextAt
                if self.shown { self.fetch() }
            }
        }
    }

    func regionDidChange() {
        guard shown else { return }
        thin()
        let heading = CGFloat(map?.mapView.camera.heading ?? 0)
        for mark in marks.values { (map?.mapView.view(for: mark) as? StationMarkView)?.heading = heading }
    }

    func view(for annotation: MKAnnotation, in mapView: MKMapView) -> MKAnnotationView? {
        guard annotation is StationAnnotation,
              let view = mapView.dequeueReusableAnnotationView(withIdentifier: StationMarkView.reuse, for: annotation) as? StationMarkView
        else { return nil }
        style(view)
        view.annotation = annotation
        view.update()
        return view
    }

    /// A station tapped: its sheet, the storm's put away (one sheet at a time).
    func didSelect(_ annotation: MKAnnotation) -> Bool {
        guard let mark = annotation as? StationAnnotation, let map else { return false }
        map.mapView.deselectAnnotation(annotation, animated: false)
        map.model.selectedStorm = nil
        var controller: UIViewController?
        let sheet = StationSheet(station: mark.station, endpoints: map.endpoints, fetch: { [weak map] url, done in map?.fetch(url, done) },
                                 close: { controller?.dismiss(animated: true) })
        let host = UIHostingController(rootView: sheet)
        controller = host
        host.modalPresentationStyle = .pageSheet
        host.sheetPresentationController?.detents = [.medium(), .large()]
        host.sheetPresentationController?.prefersGrabberVisible = true
        host.sheetPresentationController?.largestUndimmedDetentIdentifier = .medium
        map.host?.presentOverMap(host)
        return true
    }

    // MARK: - Fetching and drawing

    private func fetch() {
        guard let map, shown else { return }
        let choice = map.model.stations.choice
        generation += 1
        let generation = generation
        lastFetch = Date()
        var components = URLComponents(url: map.endpoints.data.appendingPathComponent("stations/observations"), resolvingAgainstBaseURL: false)!
        components.queryItems = StationRules.parameters(choice).map { URLQueryItem(name: "parameter", value: $0) }
            + [URLQueryItem(name: "max_age_minutes", value: String(StationRules.maxAgeMinutes))]
            + (at.map { [URLQueryItem(name: "at", value: ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval($0))))] } ?? [])
        map.fetch(components.url!) { [weak self] data, status in
            guard let self, generation == self.generation, self.shown else { return }
            // None served (a 404) is an empty overlay; anything else keeps
            // what is drawn, unless it was drawn for another choice.
            let answer = data.flatMap(ObservedStation.decode) ?? (status == 404 || self.drawnChoice != choice ? [] : nil)
            guard let answer else { return }
            self.stations = answer
            self.drawnChoice = choice
            self.draw()
            let newest = answer.compactMap { StationHistory.seconds($0.observedAt) }.max()
            self.state?.observedAt = newest.map { Date(timeIntervalSince1970: $0) }
            self.state?.answered = true
        }
    }

    private func draw() {
        guard let map else { return }
        map.mapView.removeAnnotations(Array(marks.values))
        marks = [:]
        guard let choice = drawnChoice else { return }
        for station in stations { marks[station.id] = StationAnnotation(station, choice: choice) }
        thin()
    }

    /// One station per cell further out than zoom 8, spread evenly; a gauge
    /// with rain over a dry one.
    private func thin() {
        guard let map, let choice = drawnChoice else { return }
        let zoom = map.zoomLevel
        let perPoint = MKMapSize.world.width / (256 * pow(2, zoom))
        let placed = marks.values.compactMap { mark -> StationRules.Placed? in
            let station = mark.station
            let drawn = StationRules.isWind(choice) ? StationRules.wind(choice, station) != nil : StationRules.value(choice, station) != nil
            guard drawn else { return nil }
            let point = MKMapPoint(mark.coordinate)
            let rank = choice == .precipitation ? (StationRules.value(choice, station) ?? 0) : 0
            return StationRules.Placed(id: station.id, x: point.x / perPoint, y: point.y / perPoint, rank: rank)
        }
        let kept = StationRules.thinToGrid(placed, cell: StationRules.thinningCell(zoom))
        let onMap = Set(map.mapView.annotations.compactMap { ($0 as? StationAnnotation)?.station.id })
        map.mapView.removeAnnotations(marks.values.filter { onMap.contains($0.station.id) && !kept.contains($0.station.id) })
        map.mapView.addAnnotations(marks.values.filter { !onMap.contains($0.station.id) && kept.contains($0.station.id) })
    }

    private func style(_ view: StationMarkView) {
        guard let map else { return }
        view.dark = map.model.isDark
        view.stale = stale
        view.palette = map.player.palette
        view.heading = CGFloat(map.mapView.camera.heading)
    }

    private func restyle() {
        guard let map else { return }
        for mark in marks.values {
            guard let view = map.mapView.view(for: mark) as? StationMarkView else { continue }
            style(view)
            view.update()
        }
    }

    private func clear() {
        guard let map else { return }
        generation += 1
        map.mapView.removeAnnotations(Array(marks.values))
        marks = [:]
        stations = []
        drawnChoice = nil
        state?.observedAt = nil
        state?.answered = false
    }
}
