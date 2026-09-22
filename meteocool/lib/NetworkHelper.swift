import Foundation

class NetworkHelper {
    static var apiURL: URL { simulatorTestAPI ?? MeteocoolEnvironment.current.apiBaseURL }

    /// UI tests exercise real HTTP requests against a loopback recorder.
    /// Release builds and physical devices cannot override the API origin.
    static var simulatorTestAPI: URL? {
        #if DEBUG && targetEnvironment(simulator)
        guard let value = ProcessInfo.processInfo.environment["MC_TEST_API_URL"],
              let url = URL(string: value), url.scheme == "http", url.host == "127.0.0.1" else { return nil }
        return url
        #else
        return nil
        #endif
    }

    static func createRequest(dst: String, method: String) -> URLRequest? {
        guard let url = URL(string: dst, relativeTo: apiURL) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        return request
    }

    static func createJSONPostRequest(dst: String, dictionary: [String: Any]) -> URLRequest? {
        guard JSONSerialization.isValidJSONObject(dictionary),
              let json = try? JSONSerialization.data(withJSONObject: dictionary),
              var request = createRequest(dst: dst, method: "POST") else { return nil }
        request.httpBody = json
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    static func checkResponse(data: Data?, response: URLResponse?, error: Error?) -> Data? {
        guard error == nil, let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode), let data,
              let status = try? JSONDecoder().decode(Status.self, from: data),
              status.success else {
            // Payloads contain device tokens and precise locations. Log only status.
            NSLog("API request failed (HTTP %d)", (response as? HTTPURLResponse)?.statusCode ?? 0)
            return nil
        }
        return data
    }

    private struct Status: Decodable {
        let success: Bool
    }
}
