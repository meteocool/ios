import CoreLocation
import SwiftUI
import UIKit
import Vision
import WidgetKit

/// Renders the production map widget; scripts/check-radar-widget.sh runs it on iOS 27.
@main
struct RadarMapLayoutCheck: App {
    var body: some Scene {
        WindowGroup { Color.clear.task { await Self.check() } }
    }

    @MainActor private static func check() async {
        guard #available(iOS 27, *) else { fatalError("This check needs iOS 27") }
        let language = Locale.preferredLanguages.first!.hasPrefix("de") ? "de" : "en"
        let directory = URL.documentsDirectory.appendingPathComponent("radar-widget-\(language)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let names = ["Map Center", "Alpha", "Beta", "Gamma", "Delta", "Fifth"]
        let sample = RainTimeline.sample()
        let location = CLLocation(latitude: 48, longitude: 11)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let map = UIGraphicsImageRenderer(size: CGSize(width: 660, height: 1248), format: format).image { context in
            UIColor(red: 0.1, green: 0.7, blue: 0.2, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 660, height: 1248))

        }
        let snapshot = MapSnapshot(image: map, rendered: Date(),
                                   card: PreviewCard(latitude: 48, longitude: 11, zoom: 9.5, wide: false),
                                   location: location.coordinate)
        var failures: [String] = []
        failures += await WidgetReviewCheck.check(map: map, directory: directory)
        if language == "en", ProcessInfo.processInfo.arguments.contains("--native") {
            failures += await NativeWidgetMapCheck.check(in: directory)
        }
        if ProcessInfo.processInfo.arguments.contains("--native-only") || ProcessInfo.processInfo.arguments.contains("--review-only") {
            let report: [String: Any] = ["failures": failures, "mapHeights": [:]]
            try! JSONSerialization.data(withJSONObject: report).write(to: directory.appendingPathComponent("report.json"))
            exit(failures.isEmpty ? 0 : 1)
        }
        var missing = sample.main!.forecast!
        missing.dbz[missing.nowIndex] = nil
        let missingPlace = PlaceRain(id: "missing", name: "Unknown", isCurrent: false, location: location,
                                     forecast: missing, fetched: Date())
        precondition(missingPlace.problem == .noData, "Missing current readings must also mark the map forecast unavailable")
        let missingRenderer = ImageRenderer(content: PlaceRow(place: missingPlace, range: .nextHour)
            .frame(width: 330, height: 80).background(.white))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try! VNImageRequestHandler(cgImage: missingRenderer.uiImage!.cgImage!).perform([request])
        let missingText = request.results!.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        if !missingText.contains(String(localized: "widget_no_data")) {
            failures.append("A location with a missing current reading must show unavailable")
        }
        let now = Int(sample.main!.forecast!.now.timeIntervalSince1970)
        let partialJSON = """
        {"frames":{"\(now-300)":{"source":"observation","dbz":0},
         "\(now)":{"source":"nowcast_phys","dbz":0},
         "\(now+300)":{"source":"nowcast_phys","dbz":25},
         "\(now+600)":{"source":"nowcast_phys","dbz":25},"\(now+900)":null}}
        """
        let partial = RainForecast.fromTimeseries(Data(partialJSON.utf8), threshold: 20)!
        let munich = PlaceRain(id: "munich", name: "Munich", isCurrent: true, location: location,
                               forecast: partial, fetched: Date())
        let partialTimeline = RainTimeline.entries(places: [munich], map: snapshot, now: partial.now)
        precondition(partialTimeline.first!.main!.problem == nil,
                     "A decoded forecast with an absent tail must still show upcoming rain")
        precondition(partialTimeline.last!.date == Date(timeIntervalSince1970: TimeInterval(now + 900))
                     && partialTimeline.last!.main!.forecast == nil,
                     "The timeline must expire at the last available reading")
        let partialRenderer = ImageRenderer(content: PlaceRow(place: partialTimeline.first!.main!, range: .nextHour)
            .frame(width: 330, height: 80).background(.white))
        let partialImage = partialRenderer.uiImage!
        try! partialImage.pngData()!.write(to: directory.appendingPathComponent("partial-forecast-row.png"))
        try! VNImageRequestHandler(cgImage: partialImage.cgImage!).perform([request])
        let partialText = request.results!.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        if !partialText.contains("Munich") || partialText.contains(String(localized: "widget_no_data")) {
            failures.append("Upcoming rain must remain visible in the Places row: \(partialText)")
        }
        var dryDial = partial.advanced(to: partial.now)
        dryDial.dbz = Array(repeating: 0, count: 13)
        var partialDial = dryDial
        partialDial.dbz = Array(partialDial.dbz.prefix(3))
        func dial(_ forecast: RainForecast) -> UIImage {
            ImageRenderer(content: RainDial(forecast: forecast, steps: 12, now: partial.now, lineWidth: 13, gap: 1.2)
                .frame(width: 180, height: 180).background(.white)).uiImage!
        }
        if dial(partialDial).pngData() == dial(dryDial).pngData() {
            failures.append("The Rain Clock must distinguish absent forecast segments from known dry weather")
        }
        func clock(_ place: PlaceRain) -> UIImage {
            let entry = RainClockEntry(entry: RainEntry(date: partial.now, places: [place]), span: .hour)
            return ImageRenderer(content: RainClockView(entry: entry)
                .frame(width: 170, height: 170).background(.white)).uiImage!
        }
        if clock(missingPlace).pngData() != clock(missingPlace.withoutForecast()).pngData() {
            failures.append("The Rain Clock must show the same unavailable state for missing current data and no forecast")
        }
        let unavailableCenter = PlaceRain(id: "center", name: "Map Center", isCurrent: false, location: location,
                                          forecast: nil, fetched: nil)
        let validRow = PlaceRain(id: "row", name: "Alpha", isCurrent: false, location: location,
                                 forecast: sample.main?.forecast, fetched: Date())
        let timeline = RainTimeline.entries(places: [unavailableCenter, validRow], map: nil)
        if timeline.count < 2 || timeline.last?.places.last?.forecast != nil {
            failures.append("A row must advance and expire even when the map center has no forecast")
        }
        var heights: [Int: Int] = [:]
        for (family, width, height) in [(WidgetFamily.systemExtraLargePortrait, 330.0, 624.0),
                                         (.systemExtraLarge, 680.0, 330.0), (.systemLarge, 330.0, 350.0)] {
            for count in [0, 1, 4, 5] {
                for large in [false, true] {
                    for dark in [false, true] {
                        let places = names.prefix(count + 1).enumerated().map { index, name in
                            PlaceRain(id: "place-\(index)", name: name, isCurrent: false, location: location,
                                      forecast: index == 3 ? nil : sample.main?.forecast, fetched: Date())
                        }
                        let entry = RainEntry(date: Date(), places: places, map: snapshot)
                        let view = RadarMapContent(entry: entry, overlay: .headline, family: family)
                            .environment(\.colorScheme, dark ? .dark : .light)
                            .dynamicTypeSize(large ? .accessibility1 : .large)
                            .frame(width: width, height: height)
                            .background(dark ? Color.black : Color.white)
                        let renderer = ImageRenderer(content: view)
                        renderer.scale = 2
                        let image = renderer.uiImage!
                        let id = "\(family.rawValue)-\(count)-\(large ? "large" : "normal")-\(dark ? "dark" : "light")"
                        try! image.pngData()!.write(to: directory.appendingPathComponent("\(id).png"))
                        let request = VNRecognizeTextRequest()
                        request.recognitionLevel = .accurate
                        try! VNImageRequestHandler(cgImage: image.cgImage!).perform([request])
                        let text = request.results!.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")

                        if !text.contains("Map Center") || greenRows(image) < 160 {
                            failures.append("\(id): map and its location must stay visible with larger text")
                        }
                        let expectedCount = family == .systemLarge ? 0 : min(count, 4)
                        for index in 1...5 {
                            if text.contains(names[index]) != (index <= expectedCount) {
                                failures.append("\(id): unexpected visibility for \(names[index]): \(text)")
                            }
                        }
                        if family == .systemExtraLargePortrait && !dark && !large {
                            heights[count] = greenRows(image)
                        }
                    }
                }
            }
        }
        if !(heights[0, default: 0] > heights[1, default: 0] && heights[1, default: 0] > heights[4, default: 0]) {
            failures.append("Map must grow as location rows are removed: \(heights)")
        }
        let report: [String: Any] = ["failures": failures, "mapHeights": Dictionary(uniqueKeysWithValues: heights.map { (String($0.key), $0.value) })]
        try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("report.json"))
        print("Radar widget: \(failures.count) failures")
        exit(failures.isEmpty ? 0 : 1)
    }

    private static func greenRows(_ image: UIImage) -> Int {
        let picture = image.cgImage!
        let width = picture.width, height = picture.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(picture, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (0..<height).filter { row in
            let offset = (row * width + width / 2) * 4
            return pixels[offset + 1] > 130 && pixels[offset] < 70 && pixels[offset + 2] < 90
        }.count
    }
}
