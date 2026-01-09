import Foundation
import Observation

@MainActor
@Observable
final class RadarTimelineStore {
    enum TrackingMode {
        case live
        case manual
    }

    private(set) var timeseries: RadarTimeseries?
    private(set) var serverTime: TimeInterval = 0
    var trackingMode: TrackingMode = .live
    var selectedTimestamp: TimeInterval?

    nonisolated let api: MeteocoolAPI

    init(api: MeteocoolAPI = MeteocoolAPI()) {
        self.api = api
    }

    func refresh(lat: Double?, lon: Double?) async throws {
        let payload = try await api.radarTimeseries(lat: lat, lon: lon)
        timeseries = payload
        serverTime = payload.server_time
        if trackingMode == .live {
            selectedTimestamp = mostRecentObservation()
        }
    }

    func mostRecentObservation() -> TimeInterval? {
        guard let timeseries else { return nil }
        var mostRecent = timeseries.server_time
        for (key, frame) in timeseries.frames {
            guard let frame else { continue }
            if frame.source == "observation", let ts = TimeInterval(key), ts > mostRecent {
                mostRecent = ts
            }
        }
        return mostRecent
    }

    func frame(for timestamp: TimeInterval) -> RadarTimeseries.Frame? {
        guard let timeseries else { return nil }
        return timeseries.frames[String(Int(timestamp))] ?? nil
    }
}
