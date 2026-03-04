import MapKit
import SwiftUI

struct TileOverlayConfig: Equatable {
    let template: String
    let minimumZ: Int
    let maximumZ: Int
    let tileSize: CGSize
}

struct MapCenterRequest {
    let id: UUID
    let coordinate: CLLocationCoordinate2D
    let meters: CLLocationDistance
}

struct MapView: UIViewRepresentable {
    var primaryOverlay: TileOverlayConfig?
    var lightningStrikes: [LightningStore.Strike] = []
    var mesocyclones: [MesocycloneStore.Cyclone] = []
    var snowOverlayActive: Bool = false
    var snowTileId: String?
    var baseLayer: MapBaseLayer = .system
    var mapRotationEnabled: Bool = false
    var centerRequest: MapCenterRequest?
    @Binding var userTrackingMode: MKUserTrackingMode

    func makeCoordinator() -> MapCoordinator {
        MapCoordinator()
    }

    static func dismantleUIView(_ uiView: MKMapView, coordinator: MapCoordinator) {
        coordinator.onTrackingModeChange = nil
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.isRotateEnabled = mapRotationEnabled
        mapView.isZoomEnabled = true
        mapView.isScrollEnabled = true
        mapView.isPitchEnabled = true
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.showsUserLocation = true
        mapView.userTrackingMode = userTrackingMode
        context.coordinator.attach(mapView)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        mapView.isRotateEnabled = mapRotationEnabled
        mapView.isZoomEnabled = true
        mapView.isScrollEnabled = true
        mapView.isPitchEnabled = true
        if mapView.userTrackingMode != userTrackingMode {
            mapView.setUserTrackingMode(userTrackingMode, animated: true)
        }
        // Re-set on every update so the closure captures a fresh binding reference
        context.coordinator.onTrackingModeChange = { [self] mode in
            userTrackingMode = mode
        }
        context.coordinator.setBaseLayer(baseLayer)
        context.coordinator.setRadarOverlay(config: primaryOverlay)
        context.coordinator.setLightningStrikes(lightningStrikes)
        context.coordinator.setMesocyclones(mesocyclones)
        context.coordinator.setSnowOverlay(active: snowOverlayActive, tileId: snowTileId)
        context.coordinator.centerIfNeeded(centerRequest)
    }
}
