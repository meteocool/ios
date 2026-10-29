//
//  StormLogDetailViewController.swift
//  meteocool
//
//  One storm of the storm log: its way past the point on a small map, what
//  it brought, and a share link that opens the map where it came closest.
//  The point is drawn as the area it was in, never a pin: the backend keeps
//  only a coarse position.
//

import MapKit
import UIKit

final class StormLogDetailViewController: UITableViewController, MKMapViewDelegate {
    private let passage: StormPassage
    private let map = MKMapView()
    /// Where the point it passed was, roughly: a circle round the coarse
    /// position, and a label in it.
    private lazy var area = MKCircle(center: CLLocationCoordinate2D(latitude: passage.lat, longitude: passage.lon),
                                     radius: StormLogRules.approximateRadius(passage))
    private let nearHere = MKPointAnnotation()
    private lazy var rows: [(String, String)] = Self.rows(passage)

    init(passage: StormPassage) {
        self.passage = passage
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = StormLogViewController.severityName(passage.severity)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "reading")
        tableView.accessibilityIdentifier = "stormLog.detail"
        if StormLogRules.shareURL(passage, mapURL: MeteocoolEnvironment.current.mapURL) != nil {
            let share = UIBarButtonItem(systemItem: .action, primaryAction: UIAction { [weak self] _ in self?.share() })
            share.accessibilityLabel = NSLocalizedString("map_share", value: "Share", comment: "")
            navigationItem.rightBarButtonItem = share
        }
        setUpMap()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // A header view keeps the height it is given; follow the table's width.
        if let header = tableView.tableHeaderView, header.frame.width != tableView.bounds.width {
            header.frame.size.width = tableView.bounds.width
            tableView.tableHeaderView = header
        }
    }

    // MARK: Map

    private func setUpMap() {
        let holder = UIView(frame: CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 280))
        map.translatesAutoresizingMaskIntoConstraints = false
        map.delegate = self
        map.layer.cornerRadius = 12
        map.layer.cornerCurve = .continuous
        map.clipsToBounds = true
        map.pointOfInterestFilter = .excludingAll
        map.accessibilityLabel = StormLogViewController.text("storm_log_map", "Map of the storm's track")
        holder.addSubview(map)
        NSLayoutConstraint.activate([
            map.topAnchor.constraint(equalTo: holder.topAnchor, constant: 8),
            map.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -8),
            map.leadingAnchor.constraint(equalTo: holder.layoutMarginsGuide.leadingAnchor),
            map.trailingAnchor.constraint(equalTo: holder.layoutMarginsGuide.trailingAnchor),
        ])
        tableView.tableHeaderView = holder

        let track = StormLogRules.trackPoints(passage.track).map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        if track.count > 1 {
            map.addOverlay(MKPolyline(coordinates: track, count: track.count))
        }
        if let last = track.last {
            let head = MKPointAnnotation()
            head.coordinate = last
            head.title = StormLogViewController.severityName(passage.severity)
            map.addAnnotation(head)
        }
        map.addOverlay(area, level: .aboveRoads)
        nearHere.coordinate = area.coordinate
        nearHere.title = StormLogViewController.text("storm_log_near_here", "Near here")
        map.addAnnotation(nearHere)

        let box = StormLogRules.region(passage)
        map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: box.centerLat, longitude: box.centerLon),
                                         span: MKCoordinateSpan(latitudeDelta: box.spanLat, longitudeDelta: box.spanLon)),
                      animated: false)
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        if let circle = overlay as? MKCircle {
            let renderer = MKCircleRenderer(circle: circle)
            renderer.fillColor = UIColor.systemBlue.withAlphaComponent(0.15)
            renderer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.6)
            renderer.lineWidth = 1.5
            renderer.lineDashPattern = [4, 4]
            return renderer
        }
        guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
        let renderer = MKPolylineRenderer(polyline: line)
        renderer.strokeColor = StormLogViewController.color(passage.severity)
        renderer.lineWidth = 4
        renderer.lineCap = .round
        renderer.lineJoin = .round
        return renderer
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        if annotation === nearHere {
            return NearHereView(annotation: annotation, place: StormLogViewController.where(passage))
        }
        let marker = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: nil)
        marker.markerTintColor = StormLogViewController.color(passage.severity)
        marker.glyphImage = UIImage(systemName: "cloud.bolt.fill")
        marker.displayPriority = .required
        return marker
    }

    // MARK: Readings

    /// What the storm brought, label and value, each only when known.
    private static func rows(_ passage: StormPassage) -> [(String, String)] {
        let text = StormLogViewController.text
        var rows: [(String, String)] = [
            (text("storm_log_place", "Place"), StormLogViewController.where(passage)),
            (text("storm_log_when", "When"), StormLogRules.when(passage)),
            (text("storm_log_closest_label", "Closest"), passage.over
                ? text("storm_log_over", "Overhead")
                : String(format: text("storm_log_closest", "%@ away"), StormLogRules.kilometres(passage.closestKm))),
            (text("storm_log_severity", "Severity"), StormLogViewController.severityName(passage.severity)),
        ]
        if let peak = passage.peakDbz { rows.append((text("storm_log_peak", "Strongest echo"), StormLogRules.dbz(peak))) }
        if let top = passage.topKm { rows.append((text("storm_log_top_label", "Echo top"), StormLogRules.top(top))) }
        if let vil = passage.vilKgM2 {
            rows.append(("VIL", vil.formatted(.number.precision(.fractionLength(0))) + " kg/m²"))
        }
        rows.append((text("storm_log_strikes_label", "Lightning within 10 km"), String(passage.strikes)))
        if passage.hail { rows.append((NSLocalizedString("native_map_hail", value: "Hail", comment: ""), text("storm_log_yes", "Yes"))) }
        if passage.meso {
            rows.append((NSLocalizedString("native_map_layer_mesocyclones", value: "Mesocyclones", comment: ""), text("storm_log_yes", "Yes")))
        }
        return rows
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        passage.endedAt == nil ? StormLogViewController.text("storm_log_ongoing_footer", "The storm is still near; this entry is updated as it moves.") : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "reading", for: indexPath)
        var content = UIListContentConfiguration.valueCell()
        content.text = rows[indexPath.row].0
        content.secondaryText = rows[indexPath.row].1
        content.prefersSideBySideTextAndSecondaryText = !traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        return cell
    }

    // MARK: Sharing

    private func share() {
        guard let url = StormLogRules.shareURL(passage, mapURL: MeteocoolEnvironment.current.mapURL) else { return }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(sheet, animated: true)
    }
}

/// The label in the area round the point: a caption, not a pin, since the
/// position is only the centre of the area the point was in.
private final class NearHereView: MKAnnotationView {
    init(annotation: MKAnnotation, place: String) {
        super.init(annotation: annotation, reuseIdentifier: nil)
        let label = UILabel()
        label.text = annotation.title ?? nil
        label.font = UIFont.preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.translatesAutoresizingMaskIntoConstraints = false
        let capsule = UIView()
        capsule.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.85)
        capsule.layer.cornerCurve = .continuous
        capsule.isUserInteractionEnabled = false
        capsule.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: capsule.topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: capsule.bottomAnchor, constant: -3),
            label.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -8),
        ])
        let size = capsule.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        capsule.frame = CGRect(origin: .zero, size: size)
        capsule.layer.cornerRadius = size.height / 2
        addSubview(capsule)
        frame = capsule.frame
        canShowCallout = false
        displayPriority = .required
        isAccessibilityElement = true
        accessibilityLabel = "\(place), \(label.text ?? "")"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
