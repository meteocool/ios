import MapKit
import UIKit

final class MapCoordinator: NSObject, MKMapViewDelegate {
    private weak var mapView: MKMapView?
    private var radarOverlay: MeteocoolTileOverlay?
    private var radarConfig: TileOverlayConfig?
    private var snowOverlay: SnowTileOverlay?
    private var snowTemplate: String?
    private var baseLayer: MapBaseLayer?
    private var cyclosmOverlay: MKTileOverlay?
    private var lightningAnnotations: [LightningAnnotation] = []
    private var mesocycloneAnnotations: [MesocycloneAnnotation] = []
    private let lightningColors: [UIColor] = LightningAnnotation.colors
    private var lastCenterRequestId: UUID?

    func attach(_ mapView: MKMapView) {
        self.mapView = mapView
    }

    func setRadarOverlay(config: TileOverlayConfig?) {
        guard let mapView else { return }
        guard let config else {
            if let radarOverlay {
                mapView.removeOverlay(radarOverlay)
                self.radarOverlay = nil
                radarConfig = nil
            }
            return
        }

        if radarOverlay == nil || radarConfig != config {
            if let radarOverlay {
                mapView.removeOverlay(radarOverlay)
            }
            let overlay = MeteocoolTileOverlay(urlTemplate: config.template)
            overlay.canReplaceMapContent = false
            overlay.tileSize = config.tileSize
            overlay.minimumZ = config.minimumZ
            overlay.maximumZ = config.maximumZ
            radarOverlay = overlay
            radarConfig = config
            mapView.addOverlay(overlay, level: .aboveLabels)
        }
    }

    func setBaseLayer(_ value: MapBaseLayer) {
        guard let mapView else { return }
        guard baseLayer != value else { return }
        baseLayer = value

        if value == .cyclosm {
            let config = MKStandardMapConfiguration(elevationStyle: .flat)
            config.emphasisStyle = .muted
            mapView.preferredConfiguration = config

            if cyclosmOverlay == nil {
                let overlay = MKTileOverlay(urlTemplate: "https://tile-cyclosm.openstreetmap.fr/cyclosm/{z}/{x}/{y}.png")
                overlay.canReplaceMapContent = false
                cyclosmOverlay = overlay
                mapView.addOverlay(overlay, level: .aboveLabels)
            }
            return
        }

        if let cyclosmOverlay {
            mapView.removeOverlay(cyclosmOverlay)
            self.cyclosmOverlay = nil
        }

        switch value {
        case .system:
            let config = MKStandardMapConfiguration(elevationStyle: .flat)
            config.emphasisStyle = .default
            mapView.preferredConfiguration = config
        default:
            let config = MKStandardMapConfiguration(elevationStyle: .flat)
            config.emphasisStyle = .default
            mapView.preferredConfiguration = config
        }
    }

    func setLightningStrikes(_ strikes: [LightningStore.Strike]) {
        guard let mapView else { return }
        mapView.removeAnnotations(lightningAnnotations)
        let annotations = strikes.map { LightningAnnotation(coordinate: $0.coordinate, time: $0.time) }
        lightningAnnotations = annotations
        mapView.addAnnotations(annotations)
    }

    func setMesocyclones(_ cyclones: [MesocycloneStore.Cyclone]) {
        guard let mapView else { return }
        mapView.removeAnnotations(mesocycloneAnnotations)
        let annotations = cyclones.map { MesocycloneAnnotation(coordinate: $0.coordinate, time: $0.time, intensity: $0.intensity) }
        mesocycloneAnnotations = annotations
        mapView.addAnnotations(annotations)
    }

    func setSnowOverlay(active: Bool, tileId: String?) {
        guard let mapView else { return }
        guard active, let tileId else {
            if let snowOverlay {
                mapView.removeOverlay(snowOverlay)
                self.snowOverlay = nil
                snowTemplate = nil
            }
            return
        }

        let template = "https://tiles-a.meteocool.com/meteoradar/\(tileId)/{z}/{x}/{y}.pbf"
        if snowOverlay == nil || snowTemplate != template {
            if let snowOverlay {
                mapView.removeOverlay(snowOverlay)
            }
            let overlay = SnowTileOverlay(urlTemplate: template)
            overlay.canReplaceMapContent = false
            overlay.tileSize = CGSize(width: 512, height: 512)
            overlay.minimumZ = 0
            overlay.maximumZ = 5
            snowOverlay = overlay
            snowTemplate = template
            mapView.addOverlay(overlay, level: .aboveLabels)
        }
    }

    func centerIfNeeded(_ request: MapCenterRequest?) {
        guard let mapView, let request else { return }
        guard request.id != lastCenterRequestId else { return }
        lastCenterRequestId = request.id
        let region = MKCoordinateRegion(center: request.coordinate, latitudinalMeters: request.meters, longitudinalMeters: request.meters)
        mapView.setRegion(region, animated: true)
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        if let tileOverlay = overlay as? MKTileOverlay {
            let renderer = MKTileOverlayRenderer(tileOverlay: tileOverlay)
            if overlay is SnowTileOverlay {
                renderer.alpha = 0.5
            }
            return renderer
        }
        return MKOverlayRenderer(overlay: overlay)
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        if let lightning = annotation as? LightningAnnotation {
            let view = MKAnnotationView(annotation: lightning, reuseIdentifier: "lightning")
            let minutes = max(0, Date().timeIntervalSince(lightning.time) / 60.0)
            let color = lightningColors[min(Int(round(minutes)), lightningColors.count - 1)]
            let image = UIImage(systemName: "bolt.fill")?.withTintColor(color, renderingMode: .alwaysOriginal)
            view.image = image
            view.clusteringIdentifier = "lightning"
            return view
        }

        if let cyclone = annotation as? MesocycloneAnnotation {
            let view = MKAnnotationView(annotation: cyclone, reuseIdentifier: "mesocyclone")
            let ageMinutes = max(0, Date().timeIntervalSince(cyclone.time) / 60.0)
            let opacity: CGFloat
            switch ageMinutes {
            case 0..<5: opacity = 1.0
            case 5..<10: opacity = 0.8
            case 10..<20: opacity = 0.6
            case 20..<40: opacity = 0.4
            case 40..<50: opacity = 0.2
            default: opacity = 0.1
            }
            let size: CGFloat
            switch cyclone.intensity {
            case 4...: size = 55
            case 3..<4: size = 46
            case 2..<3: size = 38
            case 1..<2: size = 30
            default: size = 22
            }
            let config = UIImage.SymbolConfiguration(pointSize: size, weight: .regular)
            let image = UIImage(systemName: "tornado", withConfiguration: config)?
                .withTintColor(UIColor.systemPurple.withAlphaComponent(opacity), renderingMode: .alwaysOriginal)
            view.image = image
            return view
        }

        return nil
    }
}

final class MeteocoolTileOverlay: MKTileOverlay {
    private static var didLogInvalidTemplate = false

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        let flippedY = (1 << path.z) - 1 - path.y
        let urlString = urlTemplate?
            .replacingOccurrences(of: "{z}", with: "\(path.z)")
            .replacingOccurrences(of: "{x}", with: "\(path.x)")
            .replacingOccurrences(of: "{y}", with: "\(path.y)")
            .replacingOccurrences(of: "{-y}", with: "\(flippedY)") ?? ""
        if let url = URL(string: urlString), !urlString.isEmpty {
            return url
        }
        if !Self.didLogInvalidTemplate {
            Self.didLogInvalidTemplate = true
            NSLog("Invalid tile URL template: \(String(describing: urlTemplate))")
        }
        return URL(string: "about:blank")!
    }
}

final class LightningAnnotation: NSObject, MKAnnotation {
    static let colors: [UIColor] = [
        "#ffffcc", "#fffec9", "#fffdc6", "#fffcc4", "#fffac1", "#fff9be", "#fff8bb", "#fff7b9",
        "#fff5b5", "#fff4b2", "#fff3af", "#fff2ac", "#fff1a9", "#fff0a7", "#ffefa4", "#ffeda0",
        "#ffec9d", "#ffea9b", "#ffe998", "#ffe895", "#ffe793", "#ffe590", "#ffe48d", "#fee289",
        "#fee187", "#fee084", "#fede82", "#fedd7f", "#fedc7c", "#fedb7a", "#fed976", "#fed673",
        "#fed470", "#fed16e", "#fecf6b", "#fecc68", "#feca66", "#fec863", "#fec45f", "#fec15d",
        "#febf5a", "#febd57", "#feba55", "#feb852", "#feb54f", "#feb24c", "#feaf4b", "#fead4a",
        "#feab49", "#fea848", "#fea647", "#fea446", "#fea145", "#fd9e43", "#fd9c42", "#fd9941",
        "#fd9740", "#fd953f", "#fd923e", "#fd903d", "#fd8c3c", "#fd883b", "#fd8439", "#fd8038",
        "#fd7c37", "#fd7836", "#fd7435", "#fd7034", "#fc6a32", "#fc6631", "#fc6330", "#fc5f2f",
        "#fc5b2e", "#fc572c", "#fc532b", "#fc4d2a", "#fa4a29", "#f84628", "#f74327", "#f54026",
        "#f43d25", "#f23924", "#f13624", "#ee3122", "#ed2e21", "#eb2b21", "#e92720", "#e8241f",
        "#e6211e", "#e51e1d", "#e2191c", "#e0181d", "#dd161d", "#db141e", "#d9131f", "#d6111f",
        "#d41020", "#d10e21", "#ce0c22", "#cb0a22", "#c90823", "#c70723", "#c40524", "#c20325",
        "#c00225", "#bb0026", "#b70026", "#b40026", "#b00026", "#ac0026", "#a80026", "#a40026",
        "#a10026", "#9b0026", "#970026", "#930026", "#8f0026", "#8b0026", "#880026", "#840026",
        "#7e0025",
    ].compactMap { UIColor(hex: $0) }

    let coordinate: CLLocationCoordinate2D
    let time: Date

    init(coordinate: CLLocationCoordinate2D, time: Date) {
        self.coordinate = coordinate
        self.time = time
    }
}

final class MesocycloneAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let time: Date
    let intensity: Double

    init(coordinate: CLLocationCoordinate2D, time: Date, intensity: Double) {
        self.coordinate = coordinate
        self.time = time
        self.intensity = intensity
    }
}

private extension UIColor {
    convenience init?(hex: String) {
        var normalized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("#") { normalized.removeFirst() }
        guard normalized.count == 6, let value = Int(normalized, radix: 16) else { return nil }
        let red = CGFloat((value >> 16) & 0xFF) / 255.0
        let green = CGFloat((value >> 8) & 0xFF) / 255.0
        let blue = CGFloat(value & 0xFF) / 255.0
        self.init(red: red, green: green, blue: blue, alpha: 1.0)
    }
}
