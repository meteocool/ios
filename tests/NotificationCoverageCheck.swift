import Foundation

// Checks NotificationCoverage: the request for a point's domain, and reading
// whether the alerts reach it. Compiled with meteocool/lib/NotificationCoverage.swift alone.

@inline(__always) func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition {
        FileHandle.standardError.write("NotificationCoverageCheck line \(line): \(message)\n".data(using: .utf8)!)
        exit(1)
    }
}

@main
enum NotificationCoverageCheck {
    static func main() {
        let token = String(repeating: "a", count: 64)
        let request = NotificationCoverage.request(api: URL(string: "https://app.meteocool.com/")!, token: token,
                                                   latitude: 30.04, longitude: 31.23)
        check(request?.url?.absoluteString == "https://app.meteocool.com/v3/mobile/forecast?lat=30.0400&lon=31.2300", "the route and the point")
        check(request?.httpMethod == "GET", "a GET")
        check(request?.value(forHTTPHeaderField: "X-Push-Token") == token, "the token header")
        check(request?.url?.query?.contains(token) == false, "the token never in the URL")

        func outside(_ json: String) -> Bool? { NotificationCoverage.outside(Data(json.utf8)) }
        check(outside(#"{"domain": null, "frames": {}, "server_time": 1}"#) == true, "off every domain")
        check(outside(#"{"domain": "de", "frames": {}, "server_time": 1}"#) == false, "DWD's grid")
        check(outside(#"{"domain": "fr", "frames": {}, "server_time": 1}"#) == false, "a network's domain")
        check(outside(#"{"frames": {}}"#) == nil, "no domain at all says nothing")
        check(outside(#"{"detail": "Not authenticated"}"#) == nil, "an error says nothing")
        check(outside("not json") == nil, "garbage says nothing")
        print("NotificationCoverageCheck passed")
    }
}
