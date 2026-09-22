import Foundation

@main
enum NetworkHelperCheck {
    static func main() {
        let url = URL(string: "https://example.invalid/unregister")!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let accepted = Data(#"{"success":true}"#.utf8)
        let rejected = Data(#"{"success":false,"message":"bad request"}"#.utf8)
        precondition(NetworkHelper.checkResponse(data: accepted, response: response, error: nil) == accepted)
        precondition(NetworkHelper.checkResponse(data: rejected, response: response, error: nil) == nil,
                     "HTTP 200 with success:false must be treated as failure")
        precondition(NetworkHelper.checkResponse(data: accepted, response: nil, error: nil) == nil)
        precondition(NetworkHelper.checkResponse(data: Data("broken".utf8), response: response, error: nil) == nil)
        precondition(NetworkHelper.createJSONPostRequest(dst: "post_location", dictionary: ["lat": Double.nan]) == nil)
        print("Network response and serialization checks passed")
    }
}
