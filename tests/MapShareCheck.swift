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

        precondition(share?.viewSearch == "?layer=cells3d&cell=2026100402050000012345",
                     "The view to come back to is the link without its shared stamp")
        let view = MapShare(json: #"{"url":"https://app.meteocool.com/?shared=20261006T1234Z&share_lang=de&layer=cells3d&view=11.5,48.1,9.2,40,-15&cloud=20261005T015000/de-T100053300344","title":"t"}"#, mapHost: host)
        precondition(view?.viewSearch == "?layer=cells3d&view=11.5,48.1,9.2,40,-15&cloud=20261005T015000/de-T100053300344")
        precondition(MapShare(json: #"{"url":"https://app.meteocool.com/?shared=20261006T1234Z","title":"t"}"#, mapHost: host)?.viewSearch == nil,
                     "A link that says nothing but when it was shared is no view")
        sharePreview()
        print("Map share parsing checks passed")
    }

    /// The card a link previews as (core's `shareTargets.test.ts`, its card
    /// tests; the services' own pages are the web's share dialog's).
    static func sharePreview() {
        let link = "https://meteocool.com/?layer=radar&latLonZ=48.13510,11.58200,9.00&shared=20261006T1234Z"
        func card(_ url: String) -> String? {
            MapShare(json: #"{"url":"\#(url)","title":"t"}"#, mapHost: URL(string: url)?.host)?.previewURL?.absoluteString
        }
        // the card is asked for at the link's view, commas as they are
        precondition(card(link) == "https://meteocool.com/v3/preview/og.png?aspectRatio=wide&frame=true&latLonZ=48.13510,11.58200,9.00")
        // a link without a view gets the default card
        precondition(card("https://meteocool.com/?layer=radar") == "https://meteocool.com/v3/preview/og.png?aspectRatio=wide&frame=true&default")
        precondition(MapShare.previewPath(nil) == "/v3/preview/og.png?aspectRatio=wide&frame=true&default")
        // a view that is not one cannot break out of its parameter
        precondition(MapShare.previewPath("1,2,3&default\"><x") == "/v3/preview/og.png?aspectRatio=wide&frame=true&latLonZ=1,2,3%26default%22%3E%3Cx")
        // From the link's own origin, the simulator's loopback map's port and all.
        precondition(card("http://127.0.0.1:18765/?latLonZ=1,2,3") == "http://127.0.0.1:18765/v3/preview/og.png?aspectRatio=wide&frame=true&latLonZ=1,2,3")
        precondition(card("https://demo.meteocool.com/?latLonZ=50.1,8.6,7.00&layer=cells3d") == "https://demo.meteocool.com/v3/preview/og.png?aspectRatio=wide&frame=true&latLonZ=50.1,8.6,7.00")
    }
}
