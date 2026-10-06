import Foundation

@main
enum MapShareCheck {
    static func main() {
        let host = "app.meteocool.com"
        let link = "https://app.meteocool.com/?layer=cells3d&cell=2026100402050000012345&shared=20261006T1234Z"

        let share = MapShare(json: #"{"url":"\#(link)","title":"Strong storm · meteocool","x":10,"y":20.5,"width":44,"height":44}"#, mapHost: host)
        precondition(share?.url.absoluteString == link)
        precondition(share?.title == "Strong storm · meteocool")
        precondition(share?.sourceRect == CGRect(x: 10, y: 20.5, width: 44, height: 44))

        let started = MapShare(json: #"{"url":"\#(link)","title":"  "}"#, mapHost: host)
        precondition(started?.sourceRect == nil, "A share the app starts has no control to point at")
        precondition(started?.title == "meteocool", "An empty title falls back to the app's name")

        precondition(MapShare(json: #"{"url":"https://evil.example/?x","title":"t"}"#, mapHost: host) == nil,
                     "Only links back to the map's own host are shared")
        precondition(MapShare(json: #"{"url":"http://app.meteocool.com/","title":"t"}"#, mapHost: host) == nil,
                     "Plain http is for the simulator's loopback map only")
        precondition(MapShare(json: #"{"url":"http://127.0.0.1:18765/?layer=radar","title":"t"}"#, mapHost: "127.0.0.1") != nil)
        precondition(MapShare(json: #"{"url":"javascript:alert(1)","title":"t"}"#, mapHost: host) == nil)
        precondition(MapShare(json: "null", mapHost: host) == nil, "window.shareLink() before the map is up")
        precondition(MapShare(json: "not json", mapHost: host) == nil)
        precondition(MapShare(json: #"{"url":"\#(link)"}"#, mapHost: nil) == nil)

        let odd = MapShare(json: #"{"url":"\#(link)","title":"t","x":true,"y":1,"width":-4,"height":2}"#, mapHost: host)
        precondition(odd != nil && odd?.sourceRect == nil, "A malformed rect is dropped, not the share")
        let long = MapShare(json: #"{"url":"\#(link)","title":"\#(String(repeating: "a", count: 500))"}"#, mapHost: host)
        precondition(long?.title.count == MapShare.maxTitleLength)
        print("Map share parsing checks passed")
    }
}
