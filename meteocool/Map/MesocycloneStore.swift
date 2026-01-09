import CoreLocation
import Foundation
import Observation

@MainActor
@Observable
final class MesocycloneStore {
    struct Cyclone: Identifiable {
        let id: TimeInterval
        let coordinate: CLLocationCoordinate2D
        let intensity: Double
        let time: Date
    }

    private(set) var cyclones: [Cyclone] = []

    nonisolated let api: MeteocoolAPI

    init(api: MeteocoolAPI = MeteocoolAPI()) {
        self.api = api
    }

    func refresh() async throws {
        let items = try await api.mesocyclonesAll()
        cyclones = items.map { item in
            let timeInterval: TimeInterval
            if item.time > 2_000_000_000 {
                timeInterval = item.time / 1000
            } else {
                timeInterval = item.time
            }
            return Cyclone(
                id: item.time,
                coordinate: CLLocationCoordinate2D(latitude: item.lat, longitude: item.lon),
                intensity: item.intensity,
                time: Date(timeIntervalSince1970: timeInterval)
            )
        }
    }
}
