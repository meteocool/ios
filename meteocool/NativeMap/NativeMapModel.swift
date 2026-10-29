//
//  NativeMapModel.swift
//  meteocool
//
//  The native map's state that its controls and sheets show.
//

import Combine
import MapKit
import CoreLocation
import Foundation

/// What the native map's SwiftUI parts observe: which map is shown, what is
/// selected, who to credit, what the newest data is.
@MainActor
final class NativeMapModel: ObservableObject {
    /// core's maps (`lm.currentCap`): the radar, the lightning map, the
    /// precipitation types, the 3D storms.
    enum Capability: String, CaseIterable {
        case radar
        case lightning
        /// As core names it in a link (`layer=precipTypes`).
        case precipitationTypes = "precipTypes"
        case cells3d
    }

    @Published var capability: Capability = .radar
    /// Who the data on screen is from (core's `layers/attributions.ts`).
    @Published var credits = ""
    /// The selected storm's id (`/storms/{id}`), nil without one.
    @Published var selectedStorm: String?
    /// The long-pressed point (core's `point=`), nil without one.
    @Published var point: CLLocationCoordinate2D?
    /// The user's position while the location button is on.
    @Published var userLocation: CLLocation?
    /// The newest observed scan on the radar, and the server's clock then.
    @Published var newestScan: Date?
    @Published var serverTime: Date?
    /// Whether the socket is connected: live, rather than polled.
    @Published var connected = false
    /// The map is drawn dark (core's dark basemap rules: labels, casings, wash).
    @Published var isDark = false
    /// Something the map put over the controls, by owner; the controls hide
    /// while any is set.
    @Published var covers = Set<String>()
    /// The tray is out of the way (a storm's sheet is up).
    @Published var trayHidden = false
    /// The model comparison is open (`modelCompareAt`).
    @Published var compareOpen = false
    /// When the other maps' picture was made (`capLastUpdated`).
    @Published var lastUpdated: Date?
    /// A box of sky to open as a storm, from the 3D map (core's `cloud`).
    @Published var volumeRequest: RadarVolume?
    /// Whether a storm is open anywhere: the 3D map lets go of its own
    /// highlight when it closes.
    @Published var stormOpen = false
    /// The storm cores listed now (`/cells/volumes`), for the selection.
    @Published var volumes: [RadarVolume] = []
    /// Where the 3D map opens next instead of the flat map's view
    /// (`openStormIn3D`).
    var focus3D: ThreeDFocus?
    /// The map and view a storm was opened on the 3D map from (core's
    /// `open3d.ts` origin): closing that storm goes back. The view is
    /// dropped once the 3D map is moved, and the whole of it once another
    /// map is picked.
    var detour: (capability: Capability, camera: MKMapCamera?)?
    /// The place the tray's bars are for (core's strip title): the place
    /// name once known, else what the bars measure; nil without a position.
    @Published var trayTitle: String?
    /// The name of the place the bars are for, from reverse geocoding.
    @Published var placeName: String?
    /// The legend shows dBZ values instead of pictograms (`radarLegendUnit`).
    @Published var legendDBZ = false
    /// The observed picture chosen (`radarProduct`).
    @Published var product = RadarProduct.hx
    /// The radar is behind (core's `radarStale`): dimmed, "Out of date".
    @Published var stale = false
    /// A toast at the top (core's `reportToast`), gone after a while.
    @Published var toast: String?
    /// The open storm's slice, turned in its panel, cut on the 3D map.
    let cut = StormCut()
    /// The radar open on the flat map in its own sweep (site mode).
    let site = SiteSweepState()
    /// DWD's weather stations over the radar map.
    let stations = StationState()
    /// The layer switches that are on, for the chrome that follows them.
    @Published var layersOn = Set<NativeMapLayer>()
    /// What the storm key turned off (core's `hiddenStormMarks`), kept.
    @Published var hiddenStormMarks: Set<StormMarkToggle> = NativeMapModel.storedHiddenMarks() {
        didSet {
            NativeMapModel.defaults?.set(hiddenStormMarks.map(\.rawValue).sorted(), forKey: NativeMapModel.hiddenMarksKey)
        }
    }

    private static let hiddenMarksKey = "nativeMap.hiddenStormMarks"
    private static let defaults = UserDefaults(suiteName: "group.org.frcy.app.meteocool")
    private static func storedHiddenMarks() -> Set<StormMarkToggle> {
        Set((defaults?.stringArray(forKey: hiddenMarksKey) ?? []).compactMap(StormMarkToggle.init))
    }
    /// The storm open, as the 3D map finds and cuts it; nil without one.
    @Published var opened: OpenedStorm?
}

/// The open storm, by what the 3D map knows its storms by: a tracked cell's
/// code, a volume's path; and the way its track runs, which its cut is
/// measured from.
struct OpenedStorm: Equatable {
    var cell: String?
    var volume: String?
    var headingDeg: Double?

    init(_ selection: StormSelection) {
        cell = selection.cell?.code
        volume = selection.cell?.volume?.path ?? selection.volume?.path
        headingDeg = StormSelect.headingOf(selection)
    }

    /// The same storm, perhaps with a newer heading.
    func isSame(as other: OpenedStorm?) -> Bool {
        guard let other else { return false }
        return cell == other.cell && volume == other.volume
    }
}

/// A storm to frame when the 3D map opens: where, and how big as drawn.
struct ThreeDFocus: Equatable {
    var latitude: Double
    var longitude: Double
    var widthM: Double
    var heightM: Double

    /// A box of sky's or a storm's, from its area above the threshold; its
    /// height as the 3D map stretches it, the echo top where one is known.
    init(latitude: Double, longitude: Double, areaKm2: Double?, topM: Double?) {
        self.latitude = latitude
        self.longitude = longitude
        widthM = max(2 * (max(areaKm2 ?? 300, 1) / .pi).squareRoot() * 1000, 8_000)
        heightM = (topM ?? 12_000) * ThreeDScale.vertical
    }
}
