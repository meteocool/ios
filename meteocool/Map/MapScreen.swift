import MapKit
import SwiftUI

struct MapScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(SettingsStore.self) private var settings
    @State private var radarStore = RadarTimelineStore()
    @State private var lightningStore = LightningStore()
    @State private var mesocycloneStore = MesocycloneStore()
    @State private var snowStore = SnowOverlayStore()
    @State private var precipTypesStore = PrecipTypesStore()
    @State private var timelineIndex: Int = 0
    @State private var isPlaying: Bool = true
    @State private var showLayerSwitcher: Bool = false
    @State private var showSettings: Bool = false
    @State private var userTrackingMode: MKUserTrackingMode = .none
    @State private var centerRequest: MapCenterRequest?
    @State private var locationObserver = LocationObserverBox()
    @State private var showOnboarding: Bool = false

    private var timestamps: [TimeInterval] {
        guard let frames = radarStore.timeseries?.frames else { return [] }
        return frames.keys.compactMap { TimeInterval($0) }.sorted()
    }

    private var liveTimestamp: TimeInterval? {
        radarStore.mostRecentObservation()
    }

    private var liveIndex: Int? {
        guard let liveTimestamp else { return nil }
        let liveInt = Int(liveTimestamp)
        if let exact = timestamps.firstIndex(where: { Int($0) == liveInt }) {
            return exact
        }
        return timestamps.enumerated()
            .min(by: { abs($0.element - liveTimestamp) < abs($1.element - liveTimestamp) })?
            .offset
    }

    private var radarOverlayTemplate: String? {
        guard let frames = radarStore.timeseries?.frames else { return nil }
        let index = min(max(timelineIndex, 0), max(timestamps.count - 1, 0))
        let timestamp = radarStore.selectedTimestamp ?? (timestamps.isEmpty ? radarStore.mostRecentObservation() : timestamps[index])
        guard let ts = timestamp, let frame = frames[String(Int(ts))] ?? nil else { return nil }
        let bucket = frame.source == "observation" ? "meteoradar" : "meteonowcast"
        return "https://tiles-a.meteocool.com/\(bucket)/\(frame.tile_id)/{z}/{x}/{-y}.png"
    }

    private var primaryOverlay: TileOverlayConfig? {
        switch appState.activeCapability {
        case .radar:
            guard let template = radarOverlayTemplate else { return nil }
            return TileOverlayConfig(template: template, minimumZ: 3, maximumZ: 8, tileSize: CGSize(width: 512, height: 512))
        case .precipTypes:
            guard let tileId = precipTypesStore.tileId else { return nil }
            let template = "https://tiles-a.meteocool.com/meteoradar/\(tileId)/{z}/{x}/{-y}.png"
            return TileOverlayConfig(template: template, minimumZ: 3, maximumZ: 8, tileSize: CGSize(width: 512, height: 512))
        case .satellite:
            let template = "https://tiles3.ororatech.com/worldgrid3/s3_olci_worldgrid/{z}/{x}/{-y}.png"
            return TileOverlayConfig(template: template, minimumZ: 0, maximumZ: 8, tileSize: CGSize(width: 256, height: 256))
        case .aerosols:
            let template = "https://tiles2.ororatech.com/worldgrid2/s5p_ai354/{z}/{x}/{-y}.png"
            return TileOverlayConfig(template: template, minimumZ: 0, maximumZ: 8, tileSize: CGSize(width: 256, height: 256))
        case .lightning:
            return nil
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            MapView(
                primaryOverlay: primaryOverlay,
                lightningStrikes: settings.layerLightning ? lightningStore.strikes : [],
                mesocyclones: settings.layerMesocyclones ? mesocycloneStore.cyclones : [],
                snowOverlayActive: settings.layerSnow && snowStore.active,
                snowTileId: snowStore.tileId,
                baseLayer: settings.mapBaseLayer,
                mapRotationEnabled: settings.mapRotation,
                centerRequest: centerRequest,
                userTrackingMode: $userTrackingMode
            )
                .accessibilityIdentifier("MapScreen")
                .ignoresSafeArea()

            TopRightSettingsButton(showSettings: $showSettings)
                .padding(.top, 12)
                .padding(.trailing, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

            VStack(spacing: 12) {
                HStack {
                    Spacer()
                    BottomRightMapButtons(showLayerSwitcher: $showLayerSwitcher, userTrackingMode: $userTrackingMode) {
                        SharedLocationUpdater.requestLocation(observer: locationObserver, explicit: true)
                    }
                }

                if appState.activeCapability == .radar {
                    TimelineControls(timestamps: timestamps, selectedIndex: $timelineIndex, isPlaying: $isPlaying)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .onChange(of: isPlaying) { _, newValue in
            radarStore.trackingMode = newValue ? .live : .manual
            if newValue, let liveIndex {
                timelineIndex = liveIndex
                radarStore.selectedTimestamp = timestamps[liveIndex]
            }
        }
        .onChange(of: timelineIndex) { _, newValue in
            guard !timestamps.isEmpty else { return }
            radarStore.selectedTimestamp = timestamps[newValue]
        }
        .onChange(of: settings.onboardingCompleted) { _, newValue in
            showOnboarding = !newValue
        }
        .task {
            try? await radarStore.refresh(lat: nil, lon: nil)
            if isPlaying, let liveIndex {
                timelineIndex = liveIndex
                radarStore.selectedTimestamp = timestamps[liveIndex]
            }
            try? await lightningStore.refresh()
            try? await mesocycloneStore.refresh()
            try? await snowStore.refresh()
            try? await precipTypesStore.refresh()
        }
        .onAppear {
            locationObserver.onUpdate = { location in
                centerRequest = MapCenterRequest(id: UUID(), coordinate: location.coordinate, meters: 1500)
            }
            showOnboarding = !settings.onboardingCompleted
        }
        .sheet(isPresented: $showLayerSwitcher) {
            LayerSwitcherView()
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsScreen()
            }
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView {
                settings.onboardingCompleted = true
                showOnboarding = false
            }
            .interactiveDismissDisabled(true)
        }
    }
}

private struct TopRightSettingsButton: View {
    @Binding var showSettings: Bool

    var body: some View {
        Button(action: { showSettings = true }) {
            Image(systemName: "gearshape.fill")
                .font(.title3)
                .padding(12)
        }
        .accessibilityIdentifier("OpenSettings")
        .modifier(GlassCircleBackground())
    }
}

private struct BottomRightMapButtons: View {
    @Binding var showLayerSwitcher: Bool
    @Binding var userTrackingMode: MKUserTrackingMode
    let onLocate: () -> Void

    var body: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: 12) {
                VStack(spacing: 12) {
                    Button(action: {
                        userTrackingMode = .follow
                        onLocate()
                    }) {
                        Image(systemName: "location.fill")
                            .font(.title3)
                            .padding(12)
                    }
                    .accessibilityIdentifier("LocateMe")
                    .modifier(GlassCircleBackground())

                    Button(action: { showLayerSwitcher = true }) {
                        Image(systemName: "square.3.layers.3d")
                            .font(.title2)
                            .padding(12)
                    }
                    .accessibilityIdentifier("LayerSwitcher")
                    .modifier(GlassCircleBackground())
                }
            }
        } else {
            VStack(spacing: 12) {
                Button(action: {
                    userTrackingMode = .follow
                    onLocate()
                }) {
                    Image(systemName: "location.fill")
                        .font(.title3)
                        .padding(12)
                }
                .accessibilityIdentifier("LocateMe")
                .modifier(GlassCircleBackground())

                Button(action: { showLayerSwitcher = true }) {
                    Image(systemName: "square.3.layers.3d")
                        .font(.title2)
                        .padding(12)
                }
                .accessibilityIdentifier("LayerSwitcher")
                .modifier(GlassCircleBackground())
            }
        }
    }
}

private struct GlassCircleBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
                .glassEffect(.regular.interactive(), in: .circle)
        } else {
            content
                .background(.ultraThinMaterial, in: Circle())
        }
    }
}

private final class LocationObserverBox: LocationObserver {
    var onUpdate: ((CLLocation) -> Void)?

    func notify(location: CLLocation) {
        onUpdate?(location)
    }
}
