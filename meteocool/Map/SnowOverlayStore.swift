import Foundation
import Observation

@MainActor
@Observable
final class SnowOverlayStore {
    private(set) var active: Bool = false
    private(set) var tileId: String?

    nonisolated let api: MeteocoolAPI

    init(api: MeteocoolAPI = MeteocoolAPI()) {
        self.api = api
    }

    func refresh() async throws {
        let status = try await api.snowOverlayStatus()
        active = status.active
        tileId = status.tile_id
    }
}
