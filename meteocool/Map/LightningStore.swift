import CoreLocation
import Foundation
import Observation

@MainActor
@Observable
final class LightningStore {
    struct Strike: Identifiable {
        let id: UUID
        let coordinate: CLLocationCoordinate2D
        let time: Date

        init(id: UUID = UUID(), coordinate: CLLocationCoordinate2D, time: Date) {
            self.id = id
            self.coordinate = coordinate
            self.time = time
        }
    }

    private(set) var strikes: [Strike] = []
    private(set) var latestLayer: LightningLayer?

    nonisolated let api: MeteocoolAPI

    init(api: MeteocoolAPI = MeteocoolAPI()) {
        self.api = api
    }

    func refresh() async throws {
        let layer = try await api.lightningLayer()
        let baseline = try await api.lightningBaseline(baseline: layer.most_recent_strike)
        latestLayer = layer
        strikes = baseline.strikes.map {
            Strike(coordinate: CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon),
                   time: Date(timeIntervalSince1970: $0.time_wall))
        }
    }
}
