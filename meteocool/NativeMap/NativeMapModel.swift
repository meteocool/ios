//
//  NativeMapModel.swift
//  meteocool
//
//  The native map's state that its controls and sheets show.
//

import Combine
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
        case precipitationTypes = "precipitation_types"
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
}
