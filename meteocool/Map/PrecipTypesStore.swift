import Foundation
import Observation

@MainActor
@Observable
final class PrecipTypesStore {
    private(set) var tileId: String?
    private(set) var processedTime: Date?

    nonisolated let api: MeteocoolAPI

    init(api: MeteocoolAPI = MeteocoolAPI()) {
        self.api = api
    }

    func refresh() async throws {
        let layer = try await api.precipTypesLayer()
        tileId = layer.tile_id
        processedTime = Date(timeIntervalSince1970: layer.processed_time)
    }
}
