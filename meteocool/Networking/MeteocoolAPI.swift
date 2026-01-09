import Foundation

struct RadarTimeseries: Decodable {
    struct Frame: Decodable {
        let tile_id: String
        let processed_time: TimeInterval
        let source: String
        let reported_intensity: Double?
    }

    let server_time: TimeInterval
    let frames: [String: Frame?]
}

struct LightningLayer: Decodable {
    let tile_id: String
    let processed_time: TimeInterval
    let most_recent_strike: Int
}

struct LightningBaseline: Decodable {
    struct Strike: Decodable {
        let lat: Double
        let lon: Double
        let time_wall: TimeInterval
    }

    let strikes: [Strike]
}

struct Mesocyclone: Decodable {
    let lat: Double
    let lon: Double
    let intensity: Double
    let time: TimeInterval
}

struct SnowOverlayStatus: Decodable {
    let tile_id: String
    let active: Bool
}

struct PrecipTypesLayer: Decodable {
    let tile_id: String
    let processed_time: TimeInterval
}

actor MeteocoolAPI: Sendable {
    private let v3Base = URL(string: "https://api.meteocool.com/v3")!
    private let dataBase = URL(string: "https://data.meteocool.com")!

    func radarTimeseries(lat: Double?, lon: Double?) async throws -> RadarTimeseries {
        var url = v3Base.appendingPathComponent("radar/timeseries")
        if let lat, let lon {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "lat", value: "\(lat)"),
                URLQueryItem(name: "lon", value: "\(lon)"),
            ]
            url = components.url ?? url
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(RadarTimeseries.self, from: data)
    }

    func lightningLayer() async throws -> LightningLayer {
        let url = v3Base.appendingPathComponent("lightning/layer")
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(LightningLayer.self, from: data)
    }

    func lightningBaseline(baseline: Int) async throws -> LightningBaseline {
        var components = URLComponents(url: v3Base.appendingPathComponent("lightning/baseline"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "baseline", value: "\(baseline)")]
        let url = components.url ?? v3Base.appendingPathComponent("lightning/baseline")
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(LightningBaseline.self, from: data)
    }

    func mesocyclonesAll() async throws -> [Mesocyclone] {
        let url = dataBase.appendingPathComponent("mesocyclones/all/")
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode([Mesocyclone].self, from: data)
    }

    func snowOverlayStatus() async throws -> SnowOverlayStatus {
        let url = v3Base.appendingPathComponent("radar/snow")
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(SnowOverlayStatus.self, from: data)
    }

    func precipTypesLayer() async throws -> PrecipTypesLayer {
        let url = v3Base.appendingPathComponent("radar/classification")
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(PrecipTypesLayer.self, from: data)
    }
}
