import UIKit
import Vision

/// Render the production Live Activity at Apple's watch and CarPlay sizes.
/// Run with scripts/check-activity.sh; the runner includes this in the view's
/// source file so the check can exercise its private views without test APIs.
@main
struct RainActivityLayoutCheck: App {
    var body: some Scene {
        WindowGroup {
            Color.clear.task { await Self.check() }
        }
    }

    @MainActor private static func check() async {
        let language = Locale.preferredLanguages.first!.hasPrefix("de") ? "de" : "en"
        let german = language == "de"
        let locale = Locale(identifier: german ? "de_DE" : "en_US")
        let directory = URL.documentsDirectory.appendingPathComponent(language, isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let arrival = Int(Date().timeIntervalSince1970) + 12 * 60 + 15
        let end = arrival + 45 * 60
        let extreme = german ? "Extremer Regen" : "Extreme rain"
        let stronger = german ? "Stärkerer Regen" : "Intense rain"
        var forecast = RainForecast(start: arrival - 5 * 300, interval: 300,
                                    dbz: [0, 0, 0, 0, 0, 48, 48, 40, 30, 20, 0, 0, 0, 0, 0, 0, 0],
                                    observed: 3, threshold: 20)
        forecast.headline = .init(title: "\(extreme) {in:arrival}", detail: "unused detail", intensity: extreme,
                                  times: ["arrival": arrival])
        var raining = forecast
        raining.headline = .init(title: "\(stronger) \(german ? "bis" : "until") {at:end}",
                                 intensity: stronger, times: ["end": end])
        var openEnded = forecast
        openEnded.dbz = Array(repeating: 48, count: 17)
        openEnded.headline = nil
        var dry = forecast
        dry.dbz = Array(repeating: 0, count: 17)
        dry.headline = nil
        var fallback = forecast
        fallback.headline = nil
        var distant = forecast
        distant.headline?.times?["arrival"] = arrival + 100 * 60
        let cases: [(String, RainForecast, Bool)] = [
            ("arrival", forecast, false), ("raining", raining, false),
            ("open-ended", openEnded, false), ("dry", dry, false),
            ("fallback", fallback, false), ("distant", distant, false),
            ("stale", forecast, true),
        ]
        let sizes: [(String, CGFloat, CGFloat)] = [
            ("watch40", 152, 69.5), ("watch41", 165, 72.5),
            ("watch44", 173, 76.5), ("watch45", 184, 80.5), ("watch49", 191, 81.5),
            ("carplay170", 170, 78), ("carplay240", 240, 78), ("carplay-tall", 240, 100),
        ]
        var failures: [String] = []
        var results: [[String: String]] = []
        for (name, state, stale) in cases {
            let reference = Headline(forecast: state, stale: stale).checkedTitle
                .font(.headline).frame(width: 1000, height: 40, alignment: .leading)
                .environment(\.locale, locale)
                .environment(\.colorScheme, .light).background(.white)
            var expected = recognize(render(reference), language: language)
            precondition(!expected.isEmpty, "Title reference must render")
            for (size, width, height) in sizes {
                for large in [false, true] {
                    for dark in [true, false] {
                        let id = "\(name)-\(size)-\(large ? "large" : "normal")-\(dark ? "dark" : "light")"
                        let view = ActivityContentView(forecast: state, stale: stale)
                            .environment(\.activityFamily, .small)
                            .environment(\.locale, locale)
                            .environment(\.dynamicTypeSize, large ? .xxxLarge : .large)
                            .environment(\.colorScheme, dark ? .dark : .light)
                            .frame(width: width, height: height)
                            .background(dark ? Color.black : Color.white)
                            .clipped()
                        let image = render(view)
                        try! image.pngData()!.write(to: directory.appendingPathComponent("\(id).png"))
                        let text = recognize(image, language: language,
                                             ignoringSymbolsBefore: stale ? 0 : large ? 32 : 26)
                        // A live countdown can tick while the size matrix runs.
                        if !normalized(text).contains(normalized(expected)) {
                            expected = recognize(render(reference), language: language)
                            precondition(!expected.isEmpty, "Title reference must render")
                        }
                        let barHeights = chartBarHeights(image)
                        let peakHeight = barHeights.max() ?? 0
                        let heightRange = peakHeight - (barHeights.min() ?? 0)
                        results.append(["id": id, "text": text, "expected": expected,
                                        "peakBarHeight": "\(peakHeight)", "barHeightRange": "\(heightRange)"])
                        if !normalized(text).contains(normalized(expected)) {
                            failures.append("\(id): missing '\(expected)' in '\(text)'")
                        }
                        if text.contains("unused detail") {
                            failures.append("\(id): compact layout must prioritize timing over detail")
                        }
                        if stale {
                            let warning = german ? "Warte auf Radardaten" : "Waiting for radar data"
                            if !normalized(text).contains(normalized(warning)) {
                                failures.append("\(id): missing stale warning in '\(text)'")
                            }
                            if !barHeights.isEmpty {
                                failures.append("\(id): stale content must omit the chart")
                            }
                        } else if name == "dry" {
                            let now = german ? "Jetzt" : "Now"
                            if !normalized(text).contains(normalized(now)) {
                                failures.append("\(id): missing the fresh chart's time axis")
                            }
                        } else {
                            if peakHeight < 10 {
                                failures.append("\(id): chart peak is only \(peakHeight) pt tall")
                            }
                            if name != "open-ended", heightRange < 4 {
                                failures.append("\(id): chart intensities differ by only \(heightRange) pt")
                            }
                        }
                        await Task.yield()
                    }
                }
            }
            print("\(language) \(name): rendered \(sizes.count * 4) cases")
            fflush(nil)
        }
        for stale in [false, true] {
            let phone = render(ActivityContentView(forecast: forecast, stale: stale)
                .environment(\.activityFamily, .medium)
                .environment(\.locale, locale)
                .environment(\.colorScheme, .dark)
                .frame(width: 371, height: 112).background(.black))
            let name = stale ? "iphone-stale" : "iphone"
            try! phone.pngData()!.write(to: directory.appendingPathComponent("\(name).png"))
            let text = recognize(phone, language: language)
            if !normalized(text).contains(normalized(extreme)) {
                failures.append("\(name): missing the phone's rain headline in '\(text)'")
            }
            if stale {
                let warning = german ? "Warte auf neue Radardaten" : "Waiting for new radar data"
                if !normalized(text).contains(normalized(warning)) {
                    failures.append("\(name): missing the phone's full stale warning in '\(text)'")
                }
            }
        }
        let report: [String: Any] = ["language": language, "results": results, "failures": failures]
        try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("report.json"))
        print("\(language): \(results.count) rendered cases, \(failures.count) failures")
        exit(0)
    }

    @MainActor private static func render(_ view: some View) -> UIImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        return renderer.uiImage!
    }

    private static func recognize(_ image: UIImage, language: String, ignoringSymbolsBefore x: CGFloat = 0) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = [language == "de" ? "de-DE" : "en-US"]
        request.usesLanguageCorrection = true
        try! VNImageRequestHandler(cgImage: image.cgImage!).perform([request])
        return (request.results ?? []).filter { $0.boundingBox.maxX * image.size.width > x }
            .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
            .compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    private static func normalized(_ text: String) -> String {
        String(text.folding(options: .diacriticInsensitive, locale: nil)
            .lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Count colored pixels per column below the header, excluding grayscale text and axis marks.
    private static func chartBarHeights(_ image: UIImage) -> [CGFloat] {
        let source = image.cgImage!
        let chart = source.cropping(to: CGRect(x: 0, y: source.height / 2,
                                              width: source.width, height: source.height / 2))!
        let width = chart.width, height = chart.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                    bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(chart, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var heights: [CGFloat] = []
        var barHeight = 0
        for x in 0..<width {
            let count = (0..<height).filter { y in
                let offset = (y * width + x) * 4
                let rgb = pixels[offset..<offset + 3]
                return Int(rgb.max()!) - Int(rgb.min()!) > 30
            }.count
            if count > 0 {
                barHeight = max(barHeight, count)
            } else if barHeight > 0 {
                heights.append(CGFloat(barHeight) / image.scale)
                barHeight = 0
            }
        }
        if barHeight > 0 { heights.append(CGFloat(barHeight) / image.scale) }
        return heights
    }
}

private extension Headline {
    var checkedTitle: Text { title }
}
