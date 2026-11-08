import ImageIO
import MapKit
import UIKit
import UniformTypeIdentifiers

/// Uses real MapKit snapshots and HTTP fixtures for weather. Opt in with
/// MC_NATIVE_WIDGET_CHECK=1; Apple basemap rendering requires network access.
enum NativeWidgetMapCheck {
    @MainActor static func check(in directory: URL) async -> [String] {
        var failures: [String] = []
        let suite = "NativeWidgetMapCheck.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let initiallyNative = MapStyle.stored(dark: false, defaults: defaults).native
#if BETTERRAIN
        if !initiallyNative { failures.append("Better Rain must default to native maps") }
#else
        if initiallyNative { failures.append("Meteocool must preserve its web map default") }
#endif
        defaults.set(true, forKey: "nativeMap")
        defaults.set("dmax", forKey: "nativeMap.radarProduct")
        defaults.set("turbo", forKey: "radarColorMapping")
        let light = MapStyle.stored(dark: false, defaults: defaults)
        let dark = MapStyle.stored(dark: true, defaults: defaults)
        if !light.native || light.baseLayer != "light" || dark.baseLayer != "dark"
            || light.product != "dmax" || light.colormap != "turbo" || light.key == dark.key {
            failures.append("The widget must follow the app's map settings and separate its appearance caches")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WidgetRadarProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let card = PreviewCard(latitude: 48.1372, longitude: 11.5755, zoom: 9.5, wide: false)
        let pixels = CGSize(width: 660, height: 1248)
        func render(_ mode: String, dark: Bool = false) async -> NativeWidgetMap.Picture? {
            let origin = URL(string: "https://widget-check.invalid/\(mode)/")!
            return await NativeWidgetMap.render(card: card, pixels: pixels,
                style: MapStyle(baseLayer: dark ? "dark" : "light", colormap: "classic", native: true),
                endpoints: NativeMapEndpoints(api: origin, data: origin, tiles: origin), session: session)
        }
        guard let dry = await render("dry"), let rain = await render("rain"),
              let night = await render("rain", dark: true),
              let dryImage = UIImage(data: dry.data)?.cgImage,
              let rainImage = UIImage(data: rain.data)?.cgImage,
              let nightImage = UIImage(data: night.data)?.cgImage else {
            return failures + ["MapKit with valid radar tiles must produce light and dark portrait snapshots"]
        }
        try! dry.data.write(to: directory.appendingPathComponent("native-dry.png"))
        try! rain.data.write(to: directory.appendingPathComponent("native-radar.png"))
        try! night.data.write(to: directory.appendingPathComponent("native-radar-dark.png"))
        if rainImage.height > 1200 || abs(Double(rainImage.width) / Double(rainImage.height) - pixels.width / pixels.height) > 0.002 {
            failures.append("Native maps must preserve portrait proportions and bound decoded image memory")
        }
        let dryPixels = rgba(dryImage), rainPixels = rgba(rainImage), nightPixels = rgba(nightImage)
        var radarPixels = 0, darkPixels = 0
        for index in stride(from: 0, to: rainPixels.count, by: 4) {
            if abs(Int(rainPixels[index]) - Int(dryPixels[index])) > 30
                || abs(Int(rainPixels[index + 1]) - Int(dryPixels[index + 1])) > 30 { radarPixels += 1 }
            if abs(Int(rainPixels[index]) - Int(nightPixels[index])) > 30 { darkPixels += 1 }
        }
        if radarPixels < rainImage.width * rainImage.height / 4 {
            failures.append("The native snapshot must include the weather tiles, not just the basemap")
        }
        if darkPixels < rainImage.width * rainImage.height / 10 {
            failures.append("Dark appearance must render a dark Apple basemap")
        }
        let center = rain.projection.position(of: CLLocationCoordinate2D(latitude: card.latitude, longitude: card.longitude),
                                              image: pixels, frame: pixels)
        if abs(center.x - pixels.width / 2) > 2 || abs(center.y - pixels.height / 2) > 2 {
            failures.append("The native marker projection must agree with MapKit's center")
        }
        let restored = try! JSONDecoder().decode(NativeWidgetMap.Picture.self, from: JSONEncoder().encode(rain))
        if restored.data != rain.data || restored.projection.width != rain.projection.width {
            failures.append("The native cache must retain its image and marker projection")
        }
        if await render("failure") != nil { failures.append("A failed radar tile must not produce a dry-looking map") }
        if await render("corrupt") != nil { failures.append("An invalid radar tile must not produce a dry-looking map") }
        if await render("zero") != nil { failures.append("An empty HTTP 200 tile must not produce a dry-looking map") }
        if await render("absent") == nil { failures.append("An unpublished 404 tile must remain a valid empty radar tile") }
        print("Native MapKit snapshots: \(radarPixels) radar pixels, \(darkPixels) appearance pixels")
        return failures
    }

    private static func rgba(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
}

private final class WidgetRadarProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "widget-check.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let mode = url.pathComponents[1]
        let data: Data
        var status = 200
        if url.pathExtension == "png" {
            if mode == "failure" { status = 503; data = Data() }
            else if mode == "absent" { status = 404; data = Data() }
            else if mode == "zero" { data = Data() }
            else if mode == "corrupt" { data = Data("invalid PNG".utf8) }
            else { data = Self.tile(rain: mode == "rain") }
        } else {
            let now = Int(Date().timeIntervalSince1970) / 300 * 300
            data = Data("""
            {"server_time":\(now),"frames":{"\(now)":{"processed_time":\(now),"tile_id":"unused",
             "source":"observation","values":{"tile_id":"fixture","encoding":"rvp6-u8"}}}}
            """.utf8)
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    private static func tile(rain: Bool) -> Data {
        let values = Data(repeating: rain ? 135 : 0, count: 512 * 512)
        let image = CGImage(width: 512, height: 512, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 512,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                            provider: CGDataProvider(data: values as CFData)!, decode: nil,
                            shouldInterpolate: false, intent: .defaultIntent)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
