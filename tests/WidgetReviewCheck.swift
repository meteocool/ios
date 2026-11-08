import CoreLocation
import SwiftUI
import UIKit
import Vision
import WidgetKit

/// Reproduces the two map review findings through rendered views and the HTTP/file cache.
enum WidgetReviewCheck {
    @MainActor static func check(map: UIImage, directory: URL) async -> [String] {
        guard #available(iOS 27, *) else { return ["Widget review check requires iOS 27"] }
        var failures: [String] = []
        let fresh = Date(), old = fresh.addingTimeInterval(-7200)
        let location = CLLocation(latitude: 48, longitude: 11)
        var snapshot = MapSnapshot(image: map, darkImage: map, rendered: fresh,
            card: PreviewCard(latitude: 48, longitude: 11, zoom: 9.5, wide: false), location: location.coordinate)
        snapshot.darkRendered = old
        @MainActor func text<Content: View>(_ content: Content, name: String) -> String {
            let renderer = ImageRenderer(content: content)
            renderer.scale = 3
            let image = renderer.uiImage!
            try! image.pngData()!.write(to: directory.appendingPathComponent("review-\(name).png"))
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try! VNImageRequestHandler(cgImage: image.cgImage!).perform([request])
            return request.results!.compactMap { $0.topCandidates(1).first?.string }.joined().filter { !$0.isWhitespace }
        }
        let oldText = text(MapChip { Text(old, style: .time) }.frame(width: 130, height: 40).background(.black), name: "expected-old-time")
#if !BETTERRAIN
        let places = [PlaceRain(id: "center", name: "Map Center", isCurrent: false, location: location,
                               forecast: RainForecast.sample(), fetched: fresh)]
#endif
        @MainActor func content(_ picture: MapSnapshot) -> some View {
#if BETTERRAIN
            let entry = RadarMapEntry(date: fresh, center: WidgetLoader.sampleRows(1).first, places: [], map: picture, overlay: .none)
            return RadarMapContent(entry: entry, family: .systemExtraLargePortrait)
#else
            let entry = RainEntry(date: fresh, places: places, map: picture)
            return RadarMapContent(entry: entry, overlay: .none, family: .systemExtraLargePortrait)
#endif
        }
        let darkText = text(content(snapshot).environment(\.colorScheme, .dark).frame(width: 330, height: 624).background(.black), name: "dark-map-time")
        if oldText.isEmpty || !darkText.contains(oldText) {
            failures.append("Dark map must show its own older frame time: expected \(oldText), got \(darkText)")
        }
        let freshText = text(MapChip { Text(fresh, style: .time) }.frame(width: 130, height: 40).background(.black), name: "expected-fresh-time")
        if !text(content(snapshot).environment(\.colorScheme, .light).frame(width: 330, height: 624).background(.white), name: "light-map-time").contains(freshText) {
            failures.append("The light map must retain its fresh frame time")
        }
        var fallback = snapshot
        fallback.darkImage = nil
        if !text(content(fallback).environment(\.colorScheme, .dark).frame(width: 330, height: 624).background(.black), name: "fallback-map-time").contains(freshText) {
            failures.append("A dark view falling back to the light image must also use its frame time")
        }
#if !BETTERRAIN
        let selected = MeteocoolEnvironment.stored(in: WidgetStore.defaults)
        let previous: MeteocoolEnvironment = selected == .demo ? .app : .demo
        let switched = RainTimeline.entries(places: places, map: snapshot, environment: previous)
        if switched.contains(where: { $0.map != nil || $0.places.contains(where: { $0.forecast != nil }) }) {
            failures.append("A mode change while loading must discard both the old forecasts and the map")
        }
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("WidgetReview-\(UUID())", isDirectory: true)
        try! FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cache) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReviewForecastProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let demo = await WidgetStore.forecast(at: location, threshold: 20, environment: .demo, cacheDirectory: cache, session: session)
        let app = await WidgetStore.forecast(at: location, threshold: 20, environment: .app, cacheDirectory: cache, session: session)
        if demo?.forecast.value(at: 0) != 30 || app?.forecast.value(at: 0) != 0 || ReviewForecastProtocol.state.urls.count != 2 {
            failures.append("Same-place demo and app forecasts must have independent file-cache entries")
        }
        let urls = ReviewForecastProtocol.state.urls
        if urls.map(\.host) != [MeteocoolEnvironment.demo.apiBaseURL.host, MeteocoolEnvironment.app.apiBaseURL.host] {
            failures.append("Forecast requests must use the environment captured by the loader")
        }
#endif
        return failures
    }
}

#if !BETTERRAIN
private final class ReviewForecastProtocol: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var requested: [URL] = []
        var urls: [URL] { lock.withLock { requested } }
        func add(_ url: URL) -> Int { lock.withLock { requested.append(url); return requested.count } }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.path == "/v3/radar/timeseries" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let count = Self.state.add(request.url!)
        let value = count == 1 ? 30 : 0
        let now = Int(Date().timeIntervalSince1970) / 300 * 300
        let data = Data("""
        {"frames":{"\(now-300)":{"source":"observation","dbz":\(value)},
         "\(now)":{"source":"nowcast_phys","dbz":0},"\(now+300)":{"source":"nowcast_phys","dbz":0}}}
        """.utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
