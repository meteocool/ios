import CoreLocation
import XCTest

/// The native MapKit map (`meteocool/NativeMap`), against the staging and
/// demo backends: these need the network. Storms, the 3D map and the other
/// maps run on the demo deployment, which always replays a storm.
final class NativeMapUITests: XCTestCase {
    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Starts the app on the native map: `link` is a map search to open at
    /// (`MC_NATIVE_MAP_LINK`, read by simulator debug builds).
    private func launch(link: String? = nil, demo: Bool = false, hiddenFeatures: Bool = false) {
        app.launchArguments = ["--ui-test-reset", "--native-map", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-environment", demo ? "demo" : "staging"] + (hiddenFeatures ? ["--hidden-features"] : [])
        if let link { app.launchEnvironment["MC_NATIVE_MAP_LINK"] = link }
        app.launch()
        if demo {
            // "This Is Not a Real Storm": the demo deployment says so first.
            let proceed = app.alerts.buttons["Continue to Demo"].firstMatch
            if proceed.waitForExistence(timeout: 15) { proceed.tap() }
        }
    }

    private var map: XCUIElement { app.otherElements["nativeMap"].firstMatch }
    private var timeline: XCUIElement { app.descendants(matching: .any)["nativeMap.timeline"].firstMatch }
    private var playButton: XCUIElement { app.buttons["nativeMap.play"].firstMatch }
    private func element(_ identifier: String) -> XCUIElement { app.descendants(matching: .any)[identifier].firstMatch }

    /// The timeline once the series has loaded: its value names a step.
    private func waitForSeries(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(map.waitForExistence(timeout: 15), "No native map", file: file, line: line)
        XCTAssertTrue(timeline.waitForExistence(timeout: 15), "No timeline", file: file, line: line)
        // Polled rather than awaited with a predicate expectation, which now
        // and then never saw the value the element plainly had.
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if let value = timeline.value as? String, !value.isEmpty { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("The series did not load", file: file, line: line)
    }

    /// Polls `element`'s value until `matches` holds: a predicate
    /// expectation now and then never saw the value the element plainly had.
    @discardableResult
    private func waitForValue(_ element: XCUIElement, timeout: TimeInterval = 10, _ matches: (String) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = element.value as? String, matches(value) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return false
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        // Also onto the Mac's disk, to look at without the result bundle
        // (`TEST_RUNNER_SHOT_DIR`).
        if let dir = ProcessInfo.processInfo.environment["SHOT_DIR"] {
            let file = name.replacingOccurrences(of: " ", with: "-") + ".png"
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(file))
        }
    }

    /// The storms' discs and the "3D" tags on screen, from one snapshot:
    /// queried one by one, a live list reorders under the query.
    private func markFrames() -> (storms: [CGRect], tags: [CGRect]) {
        var storms: [CGRect] = [], tags: [CGRect] = []
        func collect(_ node: XCUIElementSnapshot) {
            let id = node.identifier
            if id == "nativeMap.cloudHint" { tags.append(node.frame) }
            // A storm's disc, by its id (a ULID); not its panel's parts.
            if id.hasPrefix("nativeMap.storm.01") { storms.append(node.frame) }
            node.children.forEach(collect)
        }
        if let snapshot = try? app.snapshot() { collect(snapshot) }
        return (storms, tags)
    }

    /// Holds the map at a point given as fractions of its size, or the
    /// nearest spot clear of the marks live data puts there (a core's 3D tag,
    /// a storm's disc), which a hold would open instead.
    private func hold(_ dx: CGFloat, _ dy: CGFloat) {
        let frame = map.frame
        // One snapshot of the screen: the live marks come and go between
        // queries made one by one.
        var marks: [CGRect] = []
        func collect(_ node: XCUIElementSnapshot) {
            let id = node.identifier
            if id == "nativeMap.cloudHint" || (id.hasPrefix("nativeMap.storm.") && id.contains(where: \.isNumber)) {
                marks.append(node.frame.insetBy(dx: -24, dy: -24))
            }
            node.children.forEach(collect)
        }
        if let snapshot = try? app.snapshot() { collect(snapshot) }
        let tries = [(dx, dy), (dx, dy + 0.08), (dx, dy - 0.08), (dx - 0.2, dy), (dx + 0.2, dy), (dx - 0.2, dy + 0.1), (dx + 0.2, dy + 0.1)]
        let spot = tries.first { x, y in
            let point = CGPoint(x: frame.minX + frame.width * x, y: frame.minY + frame.height * y)
            return !marks.contains { $0.contains(point) }
        } ?? (dx, dy)
        map.coordinate(withNormalizedOffset: CGVector(dx: spot.0, dy: spot.1)).press(forDuration: 1.0)
    }

    // MARK: - Radar and its tray

    func testNativeMapOpensOnTheLiveRadar() {
        launch()
        waitForSeries()
        XCTAssertTrue(element("nativeMap.pill").exists)
        XCTAssertTrue(element("nativeMap.legend").exists)
        XCTAssertTrue(app.buttons["map.layers"].isEnabled)
        // Live: no way back to it needed.
        XCTAssertFalse(element("nativeMap.backToNow").exists)
        screenshot("native map")
    }

    func testPlayingMovesThroughTheSteps() {
        // The demo: it always has a forecast to play into, where a live
        // deployment can be without one for a while.
        launch(demo: true)
        waitForSeries()
        let start = timeline.value as? String ?? ""
        playButton.tap()
        XCTAssertEqual(playButton.value as? String, "playing")
        XCTAssertTrue(waitForValue(timeline, timeout: 20) { $0 != start }, "Playback moved on")
        XCTAssertTrue(element("nativeMap.backToNow").waitForExistence(timeout: 5))
        playButton.tap()
        XCTAssertEqual(playButton.value as? String, "paused")
    }

    func testScrubbingBackAndBackToNow() {
        launch()
        waitForSeries()
        let live = timeline.value as? String ?? ""
        let middle = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        let start = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.4))
        middle.press(forDuration: 0.05, thenDragTo: start)
        XCTAssertTrue(waitForValue(timeline) { $0.hasPrefix("-") }, "Scrubbed back")
        let back = element("nativeMap.backToNow")
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        // Live again: the button goes. The live step is the one it left, or
        // a later one if a newer scan came in meanwhile.
        XCTAssertTrue(back.waitForNonExistence(timeout: 5))
        func minutes(_ label: String) -> Int? {
            if label == "Now" { return 0 }
            var total = 0, sign = 1, number = 0
            for character in label {
                if character == "-" { sign = -1 } else if let digit = character.wholeNumberValue { number = number * 10 + digit }
                else if character == "h" { total += number * 60; number = 0 } else if character == "m" { total += number; number = 0 }
            }
            return label.contains(where: \.isNumber) ? sign * total : nil
        }
        // Labels count from the clock: one that ticks past a five-minute
        // cadence before the next scan lands calls the same live step -5m.
        let left = (minutes(live) ?? 0) - 5
        XCTAssertTrue(waitForValue(timeline) { (minutes($0) ?? .min) >= left }, "Back to \(live) or later, at \(timeline.value ?? "")")
    }

    func testLegendSwitchesToDbz() {
        launch()
        waitForSeries()
        let legend = element("nativeMap.legend")
        XCTAssertEqual(legend.label, "Show dBZ values")
        legend.tap()
        XCTAssertEqual(legend.label, "Show pictograms")
        legend.tap()
        XCTAssertEqual(legend.label, "Show dBZ values")
    }

    func testProductMenuSwitchesTheScan() {
        launch()
        waitForSeries()
        element("nativeMap.productPill").tap()
        XCTAssertTrue(element("nativeMap.productMenu").waitForExistence(timeout: 5))
        // The EU composite: in view at the sheet's first height.
        let merged = element("nativeMap.product.merged")
        XCTAssertTrue(merged.waitForExistence(timeout: 5))
        merged.tap()
        XCTAssertTrue(element("nativeMap.productMenu").waitForNonExistence(timeout: 5))
        // Chosen: the menu says so the next time it opens.
        element("nativeMap.productPill").tap()
        XCTAssertTrue(element("nativeMap.product.merged").waitForExistence(timeout: 5))
        XCTAssertTrue(element("nativeMap.product.merged").isSelected)
        screenshot("EU composite")
        // What the pictures are, a tap away.
        element("nativeMap.productHelp").tap()
        XCTAssertTrue(element("nativeMap.explainer").waitForExistence(timeout: 5))
        screenshot("radar explainer")
    }

    func testStatusPillOpensConnectionDetails() {
        launch()
        waitForSeries()
        element("nativeMap.pill").tap()
        XCTAssertTrue(element("nativeMap.connectionDetails").waitForExistence(timeout: 5))
        screenshot("connection details")
        element("nativeMap.connectionDetails").buttons["Close"].firstMatch.tap()
        XCTAssertTrue(element("nativeMap.connectionDetails").waitForNonExistence(timeout: 5))
    }

    func testNoForecastStripWhereNoRunHasComeIn() {
        // France without its nowcast, as when a run has not come in: past
        // now, the forecast ground there is empty.
        app.launchEnvironment["MC_NO_NOWCAST"] = "1"
        launch(link: "?latLonZ=46.6,2.4,9")
        waitForSeries()
        let middle = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        middle.press(forDuration: 0.05, thenDragTo: timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.4)))
        XCTAssertTrue(waitForValue(timeline) { $0.hasPrefix("+") }, "Into the forecast: \(timeline.value ?? "")")
        let strip = element("nativeMap.strip.noForecast")
        XCTAssertTrue(strip.waitForExistence(timeout: 15), "No forecast here")
        screenshot("no forecast here")
        strip.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(strip.waitForNonExistence(timeout: 5))
    }

    func testSharedLinkSaysHowOld() {
        // Shared twenty minutes ago: the map says so.
        let utc = DateFormatter()
        utc.locale = Locale(identifier: "en_US_POSIX")
        utc.timeZone = TimeZone(identifier: "UTC")
        utc.dateFormat = "yyyyMMdd'T'HHmm'Z'"
        let shared = utc.string(from: Date().addingTimeInterval(-20 * 60))
        launch(link: "?latLonZ=48.14,11.58,8&shared=\(shared)")
        let toast = element("nativeMap.toast")
        XCTAssertTrue(toast.waitForExistence(timeout: 15), "The link's age")
        // A link's time is to the minute, so twenty minutes can read one either side.
        let said = toast.descendants(matching: .staticText)
            .matching(NSPredicate(format: "label MATCHES '.*(19|20|21) minutes ago.*'")).firstMatch
        XCTAssertTrue(said.waitForExistence(timeout: 5), "About twenty minutes ago")
        screenshot("shared link age")
    }

    func testNoRadarStripOverTheAtlantic() {
        launch(link: "?latLonZ=30,-40,6")
        waitForSeries()
        let strip = element("nativeMap.strip.noRadar")
        XCTAssertTrue(strip.waitForExistence(timeout: 15))
        screenshot("no radar here")
        strip.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(strip.waitForNonExistence(timeout: 5))
    }

    // MARK: - A hold on the map

    func testHoldInspectsThePoint() {
        launch(link: "?latLonZ=48.14,11.58,8")
        waitForSeries()
        hold(0.5, 0.4)
        XCTAssertTrue(element("nativeMap.point.menu").waitForExistence(timeout: 5))
        screenshot("point menu")
        element("nativeMap.point.radar").tap()
        XCTAssertTrue(element("nativeMap.point.ring").waitForExistence(timeout: 5))
        let clear = element("nativeMap.clearPoint")
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.tap()
        XCTAssertTrue(element("nativeMap.point.ring").waitForNonExistence(timeout: 5))
    }

    func testPointMenuStaysOnScreenNearTheEdges() {
        launch(link: "?latLonZ=48.14,11.58,8")
        waitForSeries()
        let window = app.windows.firstMatch.frame
        // Clear of the status bar and Dynamic Island (59 pt on these phones,
        // 24 on an iPad) and of the home indicator.
        let top: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 24 : 54
        let menu = element("nativeMap.point.menu")
        for spot: CGFloat in [0.2, 0.3, 0.6] {
            hold(0.5, spot)
            XCTAssertTrue(menu.waitForExistence(timeout: 5), "A menu for the hold at \(spot)")
            XCTAssertGreaterThanOrEqual(menu.frame.minY, top, "Under the status bar for the hold at \(spot)")
            XCTAssertLessThanOrEqual(menu.frame.maxY, window.maxY - 20, "Off the bottom for the hold at \(spot)")
            if spot == 0.2 { screenshot("point menu near the top") }
            // Put away by a tap beside it, which goes no further: the map
            // under it stays as it was, whatever live mark is there.
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.5)).tap()
            XCTAssertTrue(menu.waitForNonExistence(timeout: 5))
            XCTAssertFalse(element("nativeMap.3d").exists, "The tap that put the menu away opened nothing")
            XCTAssertFalse(element("nativeMap.storm.details").exists)
        }
    }

    func testShowForMyLocationAfterInspectingAPoint() {
        app.launchEnvironment["MC_USER_LOCATION"] = "48.14,11.58"
        launch(link: "?latLonZ=48.14,11.58,8")
        waitForSeries()
        hold(0.5, 0.3)
        element("nativeMap.point.radar").tap()
        XCTAssertTrue(element("nativeMap.point.ring").waitForExistence(timeout: 5))
        // The bars are for the point now; one tap gives them back to the reader.
        let mine = element("nativeMap.showForMyLocation")
        XCTAssertTrue(mine.waitForExistence(timeout: 5))
        screenshot("bars for a point")
        mine.tap()
        XCTAssertTrue(element("nativeMap.point.ring").waitForNonExistence(timeout: 5))
        XCTAssertFalse(mine.exists)
    }

    func testForecastOpensTheModelComparison() {
        launch(link: "?latLonZ=48.14,11.58,8")
        waitForSeries()
        hold(0.5, 0.4)
        element("nativeMap.point.forecast").tap()
        XCTAssertTrue(element("nativeMap.compare").waitForExistence(timeout: 10))
        // The models answer, or say they could not (Open-Meteo is a
        // service of its own, and slow or limited now and then).
        let days = app.staticTexts["Next 7 Days"].firstMatch, failed = element("nativeMap.compare.error")
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, !days.exists, !failed.exists { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
        XCTAssertTrue(days.exists || failed.exists, "The models answered or said they could not")
        if days.exists {
            element("nativeMap.compare.range").buttons["7 days"].tap()
            // The spread, of temperature instead of rainfall.
            let variable = element("nativeMap.compare.variable")
            for _ in 0 ..< 4 where !variable.isHittable { element("nativeMap.compare").swipeUp() }
            variable.buttons["Temperature"].tap()
            XCTAssertTrue(variable.buttons["Temperature"].isSelected)
            screenshot("model comparison, temperature")
            variable.buttons["Rainfall"].tap()
            XCTAssertTrue(variable.buttons["Rainfall"].isSelected)
        }
        screenshot("model comparison")
        element("nativeMap.compare.close").tap()
        XCTAssertTrue(element("nativeMap.compare").waitForNonExistence(timeout: 5))
    }

    /// A German city the radar has no rain for over the last two hours,
    /// asked of the deployment the app opens on.
    private func dryCity() -> (lat: Double, lon: Double)? {
        // German cities: their readings are DWD's alone, as the app's are
        // there; elsewhere a network's nowcast joins them.
        let cities = [(52.52, 13.40), (48.14, 11.58), (50.94, 6.96), (51.34, 12.37), (49.45, 11.08), (53.55, 9.99), (50.11, 8.68),
                      (51.05, 13.74), (52.37, 9.73), (48.78, 9.18), (53.08, 8.80), (54.32, 10.14), (54.09, 12.10), (47.99, 7.85),
                      (49.24, 6.99), (50.98, 11.03), (52.13, 11.63), (49.01, 12.10), (51.31, 9.48), (51.96, 7.63), (48.57, 13.43)]
        return cities.first { city in
            guard let url = URL(string: "https://api-next.meteocool.com/v3/radar/timeseries?lat=\(city.0)&lon=\(city.1)"),
                  let data = try? Data(contentsOf: url),
                  let series = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let frames = series["frames"] as? [String: Any] else { return false }
            let readings = frames.values.compactMap { ($0 as? [String: Any])?["dbz"] as? Double }
            return !readings.isEmpty && readings.allSatisfy { $0 <= 0 }
        }
    }

    func testDryOutlookOpensTheModelComparison() throws {
        guard let city = dryCity() else { throw XCTSkip("Rain over every city asked") }
        app.launchEnvironment["MC_USER_LOCATION"] = "\(city.lat),\(city.lon)"
        launch(link: "?latLonZ=\(city.lat),\(city.lon),8")
        waitForSeries()
        // Dry here: the outlook of the days to come, and the way to every model.
        XCTAssertTrue(element("nativeMap.outlook").waitForExistence(timeout: 40), "The dry outlook")
        let all = element("nativeMap.outlook.all")
        XCTAssertTrue(all.waitForExistence(timeout: 20))
        screenshot("dry outlook")
        all.tap()
        XCTAssertTrue(element("nativeMap.compare").waitForExistence(timeout: 10))
        element("nativeMap.compare.close").tap()
        XCTAssertTrue(element("nativeMap.compare").waitForNonExistence(timeout: 5))
    }

    // MARK: - Storms

    /// Where the demo's newest storm is now: its replay moves on.
    private func demoStorm() -> (lat: Double, lon: Double)? {
        let since = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3 * 3600))
        guard let answer = demoJSON("storms?bbox=-10,35,30,60&since=\(since)") as? [String: Any],
              let storms = answer["features"] as? [[String: Any]] else { return nil }
        let newest = storms.max { a, b in
            ((a["properties"] as? [String: Any])?["last_seen"] as? String ?? "") < ((b["properties"] as? [String: Any])?["last_seen"] as? String ?? "")
        }
        guard let point = (newest?["geometry"] as? [String: Any])?["coordinates"] as? [Double], point.count >= 2 else { return nil }
        return (point[1], point[0])
    }

    func testStormTapShowsTheHintThenTheDetails() throws {
        let storm = try XCTUnwrap(demoStorm(), "The demo lists storms")
        launch(link: "?latLonZ=\(storm.lat),\(storm.lon),8", demo: true)
        waitForSeries()
        let storms = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'nativeMap.storm.01'"))
        XCTAssertTrue(storms.firstMatch.waitForExistence(timeout: 30), "The demo replays a storm")
        // One on screen, clear of the controls (MapKit lists marks off the
        // edge too), of the "3D" tags, which stand over the discs, and of the
        // other storms: from one snapshot, as a live list reorders under
        // queries made one by one.
        let screen = app.windows.firstMatch.frame
        let marks = markFrames()
        let onScreen = marks.storms.first { frame in
            frame.midX > screen.width * 0.08 && frame.midX < screen.width * 0.8
                && frame.midY > screen.height * 0.17 && frame.midY < screen.height * 0.65
                && !marks.tags.contains { $0.insetBy(dx: -6, dy: -6).intersects(frame) }
                && !marks.storms.contains { $0 != frame && $0.insetBy(dx: -4, dy: -4).intersects(frame) }
        }
        let target = try XCTUnwrap(onScreen, "A storm in view")
        app.windows.firstMatch.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: target.midX, dy: target.midY)).tap()
        if UIDevice.current.userInterfaceIdiom == .pad {
            // A wide screen opens the panel at once, beside the map.
            XCTAssertTrue(element("nativeMap.storm.details").waitForExistence(timeout: 10))
            XCTAssertTrue(element("nativeMap.storm.title").exists)
            screenshot("storm panel")
            element("nativeMap.storm.close").tap()
            XCTAssertTrue(element("nativeMap.storm.details").waitForNonExistence(timeout: 5))
            return
        }
        let hint = element("nativeMap.storm.hint")
        XCTAssertTrue(hint.waitForExistence(timeout: 10))
        element("nativeMap.storm.hint.details").tap()
        XCTAssertTrue(element("nativeMap.storm.details").waitForExistence(timeout: 10))
        XCTAssertTrue(element("nativeMap.storm.title").exists)
        screenshot("storm details")
        element("nativeMap.storm.close").tap()
        // Back to the marks and the hint, on a phone.
        XCTAssertTrue(hint.waitForExistence(timeout: 5))
        element("nativeMap.storm.hint.clear").tap()
        XCTAssertTrue(hint.waitForNonExistence(timeout: 5))
    }

    // MARK: - Storm cores

    /// The demo deployment's answer at `path`, as JSON.
    private func demoJSON(_ path: String) -> Any? {
        guard let url = URL(string: "https://data-demo.meteocool.com/" + path), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private struct Core {
        let path: String
        let lat: Double
        let lon: Double
        let feature: String?
        /// The `cloud` link's spelling: `<scan>/<name>`.
        var link: String { path.split(separator: "/").suffix(2).joined(separator: "/").replacingOccurrences(of: ".mcvx", with: "") }
    }

    /// The openable storm cores the demo lists now, strongest first.
    private func demoCores() -> [Core] {
        guard let answer = demoJSON("cells/volumes") as? [String: Any], let volumes = answer["volumes"] as? [[String: Any]] else { return [] }
        return volumes
            .filter { ($0["tier"] as? Int ?? 2) >= 2 && ($0["coarse"] as? Bool) != true }
            .sorted { ($0["peak_dbz"] as? Double ?? 0) > ($1["peak_dbz"] as? Double ?? 0) }
            .compactMap { volume in
                guard let path = volume["path"] as? String, let lat = volume["lat"] as? Double, let lon = volume["lon"] as? Double else { return nil }
                return Core(path: path, lat: lat, lon: lon, feature: volume["feature"] as? String)
            }
    }

    func testCloudLinkOpensItsCoreOnTheThreeDMap() throws {
        let core = try XCTUnwrap(demoCores().first, "The demo lists storm cores")
        launch(link: "?latLonZ=\(core.lat),\(core.lon),8&layer=cells3d&cloud=\(core.link)", demo: true)
        XCTAssertTrue(element("nativeMap.3d").waitForExistence(timeout: 20))
        XCTAssertTrue(element("nativeMap.storm.details").waitForExistence(timeout: 30))
        // Its slice at a height, and the radars that saw it.
        XCTAssertTrue(element("nativeMap.storm.cappi").waitForExistence(timeout: 30))
        XCTAssertTrue(element("nativeMap.storm.radars").waitForExistence(timeout: 10))
        screenshot("storm core on the 3D map")
        // The map draws it cut; the dial turns the cut, which swings on its
        // own until taken hold of.
        let dial = element("nativeMap.storm.dial")
        XCTAssertTrue(dial.waitForExistence(timeout: 10), "The slice dial")
        // The map draws the core cut open where it stands.
        let canvas = element("nativeMap.3d.canvas")
        XCTAssertTrue(waitForValue(canvas, timeout: 40) { $0.hasSuffix(",cut") }, "Cut open: \(canvas.value ?? "")")
        let first = dial.value as? String ?? ""
        // Once the map has found the core among its storms.
        XCTAssertTrue(waitForValue(dial, timeout: 40) { $0 != first }, "The slice swings")
        dial.swipeLeft()
        // Back to north–south, from wherever the flick left it.
        let reset = element("nativeMap.storm.dial.reset")
        if reset.waitForExistence(timeout: 3) { reset.tap() }
        XCTAssertTrue(waitForValue(dial) { $0 == "cut north to south" || $0 == "cut along the storm's track" },
                      "Reset: \(dial.value as? String ?? "")")
        screenshot("storm core cut north to south")
        // The layer switcher drops the core, its panel first.
        openLayers()
        XCTAssertTrue(element("nativeMap.storm.details").waitForNonExistence(timeout: 5))
    }

    func testThreeDTagOpensTheCoreOnTheThreeDMap() throws {
        let core = try XCTUnwrap(demoCores().first, "The demo lists storm cores")
        launch(link: "?latLonZ=\(core.lat),\(core.lon),8", demo: true)
        waitForSeries()
        let tags = app.descendants(matching: .any).matching(identifier: "nativeMap.cloudHint")
        XCTAssertTrue(tags.firstMatch.waitForExistence(timeout: 30), "A tag beside the strongest core")
        // The tags as one snapshot, once the map has come to rest and the
        // list stops changing: queried one by one, a live list reorders
        // under the query, and a tag still sliding is elsewhere by the tap.
        var marks = markFrames()
        for _ in 0 ..< 20 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            let now = markFrames()
            if now.tags == marks.tags, !now.tags.isEmpty { marks = now; break }
            marks = now
        }
        // One in the open middle of the screen, clear of the controls and a
        // wide screen's panel, tapped where no storm's disc covers it: a tag
        // stands beside its disc and the two can touch.
        let screen = app.windows.firstMatch.frame
        func spot(on frame: CGRect) -> CGPoint? {
            [0.5, 0.8, 0.2].flatMap { x in [0.5, 0.25, 0.75].map { y in
                CGPoint(x: frame.minX + frame.width * x, y: frame.minY + frame.height * y)
            } }.first { point in !marks.storms.contains { $0.insetBy(dx: -3, dy: -3).contains(point) } }
        }
        let target = try XCTUnwrap(marks.tags.lazy.filter { frame in
            frame.midX > screen.width * 0.08 && frame.midX < screen.width * 0.75
                && frame.midY > screen.height * 0.17 && frame.midY < screen.height * 0.65
        }.compactMap(spot).first, "A tag in view, clear of the storms")
        screenshot("3D tags")
        let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: target.x, dy: target.y)).tap()
        XCTAssertTrue(element("nativeMap.3d").waitForExistence(timeout: 10))
        XCTAssertTrue(element("nativeMap.storm.details").waitForExistence(timeout: 20))
        XCTAssertTrue(element("nativeMap.storm.cappi").waitForExistence(timeout: 30))
        screenshot("core opened from its tag")
        // A detour: closing the core goes back to the flat map.
        element("nativeMap.storm.close").tap()
        XCTAssertTrue(element("nativeMap.3d").waitForNonExistence(timeout: 10))
        XCTAssertTrue(playButton.waitForExistence(timeout: 5))
    }

    func testThreeDLabelOpensTheStormOnTheFlatMap() throws {
        let core = try XCTUnwrap(demoCores().first, "The demo lists storm cores")
        launch(link: "?latLonZ=\(core.lat),\(core.lon),7&layer=cells3d", demo: true)
        XCTAssertTrue(element("nativeMap.3d").waitForExistence(timeout: 20))
        // A storm's label, in the open part of the screen.
        let labels = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'ar.storm.'"))
        XCTAssertTrue(labels.firstMatch.waitForExistence(timeout: 30), "Labelled storms")
        let screen = app.windows.firstMatch.frame
        let label = try XCTUnwrap((0 ..< labels.count).map { labels.element(boundBy: $0) }.first { label in
            label.isHittable && label.frame.midY > screen.height * 0.2 && label.frame.midY < screen.height * 0.7
        }, "A label in view")
        label.tap()
        let open = app.buttons["ar.openOnMap"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        // The flat map, the storm open on it.
        XCTAssertTrue(element("nativeMap.3d").waitForNonExistence(timeout: 10))
        XCTAssertTrue(element("nativeMap.storm.details").waitForExistence(timeout: 20))
        screenshot("storm opened on the flat map")
    }

    func testStormPanelCutsItOpenAndOpensItInThreeD() throws {
        // A cell of the test's own whose volume is a core the demo lists:
        // the demo's storms and its cores do not always meet in one scan.
        let core = try XCTUnwrap(demoCores().first, "The demo lists storm cores")
        let code = "2026102012009999999998"
        app.launchEnvironment["MC_CELL_FIXTURE"] = Self.cellFixture(code: code, lat: core.lat, lon: core.lon, volume: core.path)
        // Cut across, as the link says.
        launch(link: "?latLonZ=\(core.lat),\(core.lon),8&cell=\(code)&cut=90", demo: true)
        XCTAssertTrue(element("nativeMap.storm.details").waitForExistence(timeout: 30))
        let cutaway = element("nativeMap.storm.cutaway")
        for _ in 0 ..< 4 where !cutaway.exists { element("nativeMap.storm.details").swipeUp() }
        XCTAssertTrue(cutaway.waitForExistence(timeout: 30), "The panel cuts the storm open")
        XCTAssertTrue(waitForValue(cutaway) { $0 == "cut across the storm's track" }, "The link's cut: \(cutaway.value as? String ?? "")")
        XCTAssertTrue(element("nativeMap.storm.cut.caption").exists)
        screenshot("storm cut open")
        // The snaps: back along its track.
        let along = element("nativeMap.storm.cut.along")
        for _ in 0 ..< 3 where !along.isHittable { element("nativeMap.storm.details").swipeUp() }
        along.tap()
        XCTAssertTrue(waitForValue(cutaway) { $0 == "cut along the storm's track" })
        let open3d = element("nativeMap.storm.open3d")
        for _ in 0 ..< 3 where !open3d.isHittable { element("nativeMap.storm.details").swipeUp() }
        XCTAssertTrue(open3d.waitForExistence(timeout: 5))
        open3d.tap()
        XCTAssertTrue(element("nativeMap.3d").waitForExistence(timeout: 10))
        // Cut on the map where it stands, the dial in the panel to turn it.
        let dial = element("nativeMap.storm.dial")
        XCTAssertTrue(dial.waitForExistence(timeout: 30), "The slice dial")
        XCTAssertTrue(element("nativeMap.storm.cappi").waitForExistence(timeout: 30))
        screenshot("storm cut on the 3D map")
    }

    /// A KONRAD3D cell measured in three layers, as `/cells/tracks/{code}`
    /// sends it, seen a minute ago.
    private static func cellFixture(code: String, lat: Double = 48.14, lon: Double = 11.56, volume: String? = nil) -> String {
        let iso = ISO8601DateFormatter()
        let seen = iso.string(from: Date().addingTimeInterval(-60))
        let born = iso.string(from: Date().addingTimeInterval(-40 * 60))
        let volumePart = volume.map { " \"volume\": {\"path\": \"\($0)\", \"coverage\": 0.9, \"sites\": [\"isn\"], \"tier\": 2}," } ?? ""
        return """
        {"type": "Feature", "properties": {"code": "\(code)", "first_seen": "\(born)", "last_seen": "\(seen)",
         "n_steps": 9, "active": true, "max_severity": 2, "max_dbz": 58, "echo_top_max_m": 11000, "echo_bottom_m": 1200,
         "polygon": [[\(lon - 0.06), \(lat - 0.04)], [\(lon + 0.06), \(lat - 0.04)], [\(lon + 0.06), \(lat + 0.04)], [\(lon - 0.06), \(lat + 0.04)]],
         "series": [{"t": "\(seen)", "lon": \(lon), "lat": \(lat), "severity": 2, "max_dbz": 58, "echo_top_m": 11000, "area_km2": 95, "heading_deg": 60}],\(volumePart)
         "structure": [{"dbz": 30, "area_km2": 95, "top_m": 9200, "volume_km3": 400},
                       {"dbz": 45, "area_km2": 30, "top_m": 7600, "volume_km3": 100},
                       {"dbz": 55, "area_km2": 4, "top_m": 6100, "volume_km3": 12}]}}
        """
    }

    func testStormPanelOpensARWhereThereIsAR() {
        let code = "2026102012009999999999"
        app.launchEnvironment["MC_CELL_FIXTURE"] = Self.cellFixture(code: code)
        launch(link: "?latLonZ=48.14,11.56,9&cell=\(code)")
        let details = element("nativeMap.storm.details")
        XCTAssertTrue(details.waitForExistence(timeout: 30))
        let ar = element("nativeMap.storm.ar")
        // A hidden feature: not offered until unlocked.
        for _ in 0 ..< 3 { details.swipeUp() }
        XCTAssertFalse(ar.exists, "AR stays hidden until unlocked")
        // Unlocked from the start this time.
        app.terminate()
        launch(link: "?latLonZ=48.14,11.56,9&cell=\(code)", hiddenFeatures: true)
        XCTAssertTrue(details.waitForExistence(timeout: 30))
        for _ in 0 ..< 4 where !ar.isHittable { details.swipeUp() }
        XCTAssertTrue(ar.waitForExistence(timeout: 5), "AR offered once unlocked")
        // The camera and the position, asked the first time.
        addUIInterruptionMonitor(withDescription: "AR permissions") { alert in
            for label in ["Allow While Using App", "OK", "Allow"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        ar.tap()
        // The camera's view on a phone, a still sky on the simulator, with the
        // storm the panel was for among the storms drawn.
        let view = element("ar.view")
        for _ in 0 ..< 10 where !view.exists {
            app.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        XCTAssertTrue(view.waitForExistence(timeout: 15), "The AR view, at the storm")
        XCTAssertTrue(element("ar.close").waitForExistence(timeout: 5))
        screenshot("AR from the storm panel")
        element("ar.close").tap()
        XCTAssertTrue(view.waitForNonExistence(timeout: 10))
        // Back on the map it was opened from.
        XCTAssertTrue(element("nativeMap.view").waitForExistence(timeout: 5))
    }

    func testCellPanelShowsItsMeasuredStructure() {
        let code = "2026102012009999999999"
        app.launchEnvironment["MC_CELL_FIXTURE"] = Self.cellFixture(code: code)
        launch(link: "?latLonZ=48.14,11.56,9&cell=\(code)")
        XCTAssertTrue(element("nativeMap.storm.details").waitForExistence(timeout: 30))
        let model = element("nativeMap.storm.structure")
        // Below the readings: scrolled to where it is drawn.
        for _ in 0 ..< 4 where !model.exists { element("nativeMap.storm.details").swipeUp() }
        XCTAssertTrue(model.waitForExistence(timeout: 10), "The cell's measured model")
        screenshot("cell structure")
    }

    // MARK: - Layers and the other maps

    private func openLayers() {
        app.buttons["map.layers"].tap()
        XCTAssertTrue(element("nativeMap.layers").waitForExistence(timeout: 5))
    }

    func testLoopFromTwoHoursBackIsKept() {
        launch()
        waitForSeries()
        openLayers()
        let loop = app.switches["nativeMap.layers.fromStart"].firstMatch
        XCTAssertTrue(loop.waitForExistence(timeout: 5))
        for _ in 0 ..< 4 where !loop.isHittable { element("nativeMap.layers").swipeUp() }
        let before = loop.value as? String
        loop.switches.firstMatch.tap()
        XCTAssertTrue(waitForValue(loop) { $0 != before }, "Switched")
        let after = loop.value as? String
        // Put away and opened again: as left.
        element("nativeMap.layers.close").tap()
        openLayers()
        let again = app.switches["nativeMap.layers.fromStart"].firstMatch
        XCTAssertTrue(again.waitForExistence(timeout: 5))
        XCTAssertEqual(again.value as? String, after)
        for _ in 0 ..< 4 where !again.isHittable { element("nativeMap.layers").swipeUp() }
        again.switches.firstMatch.tap()
        XCTAssertTrue(waitForValue(again) { $0 == before }, "Back as it was")
    }

    func testLayerSwitcherTurnsLightningOff() {
        launch()
        waitForSeries()
        openLayers()
        let lightning = app.switches["nativeMap.layers.lightning"].firstMatch
        XCTAssertTrue(lightning.waitForExistence(timeout: 5))
        XCTAssertEqual(lightning.value as? String, "1")
        lightning.switches.firstMatch.tap()
        XCTAssertEqual(lightning.value as? String, "0")
        element("nativeMap.layers.close").tap()
        openLayers()
        XCTAssertEqual(app.switches["nativeMap.layers.lightning"].firstMatch.value as? String, "0")
    }

    func testLightningMapShowsItsHistogram() {
        launch(link: "?latLonZ=44,3.5,6", demo: true)
        waitForSeries()
        openLayers()
        element("nativeMap.layers.map.lightning").tap()
        XCTAssertTrue(element("nativeMap.otherTray").waitForExistence(timeout: 10))
        XCTAssertTrue(element("nativeMap.lightningChart").waitForExistence(timeout: 10))
        XCTAssertFalse(playButton.isHittable)
        screenshot("lightning map")
    }

    func testPrecipitationTypesMapSaysHowOld() {
        launch()
        waitForSeries()
        openLayers()
        element("nativeMap.layers.map.precipitation_types").tap()
        XCTAssertTrue(element("nativeMap.otherTray").waitForExistence(timeout: 10))
        XCTAssertTrue(element("nativeMap.lastUpdated").waitForExistence(timeout: 20))
        screenshot("precipitation types")
    }

    func testThreeDMapAndItsModes() {
        launch(link: "?latLonZ=44,3.5,7", demo: true)
        waitForSeries()
        openLayers()
        element("nativeMap.layers.map.cells3d").tap()
        XCTAssertTrue(element("nativeMap.3d").waitForExistence(timeout: 10))
        let shells = element("nativeMap.3d.mode.shells")
        XCTAssertTrue(shells.waitForExistence(timeout: 5))
        shells.tap()
        XCTAssertTrue(shells.isSelected)
        element("nativeMap.3d.mode.peel").tap()
        XCTAssertTrue(element("nativeMap.3d.slider").waitForExistence(timeout: 5))
        sleep(5)
        screenshot("3D map")
        // Back to the flat map.
        openLayers()
        element("nativeMap.layers.map.radar").tap()
        XCTAssertTrue(element("nativeMap.3d").waitForNonExistence(timeout: 10))
        XCTAssertTrue(playButton.waitForExistence(timeout: 5))
    }

    func testThreeDEveryModeItsSliderNorthAndDetails() throws {
        let core = try XCTUnwrap(demoCores().first, "The demo lists storm cores")
        launch(link: "?latLonZ=\(core.lat),\(core.lon),7&layer=cells3d", demo: true)
        XCTAssertTrue(element("nativeMap.3d").waitForExistence(timeout: 20))
        // Every way to look into the storms, in the tray's order; the ones
        // with a slider show it and move with it.
        let slid: Set<String> = ["peel", "slice", "turn", "floor"]
        for mode in ["live", "peel", "shells", "slice", "turn", "shaft", "tops", "floor"] {
            let button = app.buttons["nativeMap.3d.mode.\(mode)"].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 5), mode)
            for _ in 0 ..< 3 where !button.isHittable { app.scrollViews.containing(.button, identifier: "nativeMap.3d.mode.live").firstMatch.swipeLeft() }
            button.tap()
            XCTAssertTrue(button.isSelected, mode)
            let slider = app.sliders["nativeMap.3d.slider"].firstMatch
            if slid.contains(mode) {
                XCTAssertTrue(slider.waitForExistence(timeout: 5), mode)
                let before = slider.value as? String
                slider.adjust(toNormalizedSliderPosition: 0.9)
                XCTAssertNotEqual(slider.value as? String, before, "\(mode) slider moves")
            } else {
                XCTAssertFalse(slider.exists, mode)
            }
        }
        screenshot("3D floor")
        app.scrollViews.containing(.button, identifier: "nativeMap.3d.mode.live").firstMatch.swipeRight()
        // North up, then a storm picked by its label and its details opened.
        element("nativeMap.3d.north").tap()
        let labels = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'ar.storm.'"))
        XCTAssertTrue(labels.firstMatch.waitForExistence(timeout: 30), "Labelled storms")
        let screen = app.windows.firstMatch.frame
        let label = try XCTUnwrap((0 ..< labels.count).map { labels.element(boundBy: $0) }.first { label in
            label.isHittable && label.frame.midY > screen.height * 0.2 && label.frame.midY < screen.height * 0.7
        }, "A label in view")
        label.tap()
        let details = element("nativeMap.3d.details")
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        details.tap()
        XCTAssertTrue(element("nativeMap.storm.details").waitForExistence(timeout: 20))
        element("nativeMap.storm.close").tap()
        // Closed: the storm is let go of on the map too.
        XCTAssertTrue(details.waitForNonExistence(timeout: 5))
    }

    func testEveryLayerSwitchTurnsOffAndOn() {
        launch(link: "?latLonZ=44,3.5,7", demo: true)
        waitForSeries()
        openLayers()
        for layer in ["lightning", "mesocyclones", "storms", "fromStart", "cells3d", "terrain3d"] {
            let toggle = app.switches["nativeMap.layers.\(layer)"].firstMatch
            for _ in 0 ..< 4 where !toggle.isHittable { element("nativeMap.layers").swipeUp() }
            XCTAssertTrue(toggle.waitForExistence(timeout: 5), layer)
            let before = toggle.value as? String
            toggle.switches.firstMatch.tap()
            XCTAssertNotEqual(toggle.value as? String, before, "\(layer) switches")
            toggle.switches.firstMatch.tap()
            XCTAssertEqual(toggle.value as? String, before, "\(layer) switches back")
        }
        element("nativeMap.layers.close").tap()
        XCTAssertTrue(element("nativeMap.layers").waitForNonExistence(timeout: 5))
        XCTAssertTrue(map.exists)
    }

    func testRadarColorMapRepaintsBothMaps() {
        launch(link: "?latLonZ=44,3.5,7&layer=cells3d", demo: true)
        XCTAssertTrue(element("nativeMap.3d").waitForExistence(timeout: 20))
        app.buttons["map.settings"].tap()
        let row = app.staticTexts["Radar Color Map"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let homeyer = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Homeyer'")).firstMatch
        XCTAssertTrue(homeyer.waitForExistence(timeout: 5))
        homeyer.tap()
        // Confirmed, and settings closed: the 3D map and the flat one still up.
        app.navigationBars.buttons.element(boundBy: app.navigationBars.buttons.count - 1).tap()
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(element("nativeMap.3d").waitForExistence(timeout: 10))
        sleep(3)
        screenshot("3D in Homeyer")
        openLayers()
        element("nativeMap.layers.map.radar").tap()
        XCTAssertTrue(element("nativeMap.3d").waitForNonExistence(timeout: 10))
        XCTAssertTrue(playButton.waitForExistence(timeout: 5))
    }

    func testThreeDScanPickerAndGuide() {
        launch(link: "?latLonZ=44,3.5,7&layer=cells3d", demo: true)
        XCTAssertTrue(element("nativeMap.3d").waitForExistence(timeout: 20))
        // The guide: what the marks mean, how to move.
        element("nativeMap.3d.guideButton").tap()
        XCTAssertTrue(element("nativeMap.3d.guide").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Storm clouds"].exists)
        element("nativeMap.3d.guide.close").tap()
        XCTAssertTrue(element("nativeMap.3d.guide").waitForNonExistence(timeout: 5))
        // An earlier scan: shown with its time, or a note that it has nothing.
        let picker = element("nativeMap.3d.scan")
        XCTAssertTrue(picker.waitForExistence(timeout: 30))
        XCTAssertEqual(picker.label, "Storms: latest scan")
        picker.tap()
        let earlier = app.buttons.matching(NSPredicate(format: "label MATCHES '^[0-9]{2}:[0-9]{2}$'")).element(boundBy: 2)
        XCTAssertTrue(earlier.waitForExistence(timeout: 5))
        earlier.tap()
        let note = element("nativeMap.3d.scanNote")
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            picker.label.hasSuffix("not live") || note.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 60), .completed)
        screenshot("3D earlier scan")
        // Back to the newest.
        picker.tap()
        app.buttons["Latest"].firstMatch.tap()
        expectation(for: NSPredicate(format: "label == 'Storms: latest scan'"), evaluatedWith: picker)
        waitForExpectations(timeout: 10)
    }

    func testThreeDLinkOpensTheThreeDMap() {
        launch(link: "?latLonZ=44,3.5,7&layer=cells3d&pitch=30&bearing=-135", demo: true)
        XCTAssertTrue(element("nativeMap.3d").waitForExistence(timeout: 20))
        XCTAssertTrue(element("nativeMap.3d.north").exists)
        // Tilted and turned as the link says.
        let canvas = element("nativeMap.3d.canvas")
        XCTAssertTrue(waitForValue(canvas) { $0.hasPrefix("30,-135") }, "The link's camera: \(canvas.value as? String ?? "")")
    }

    func testStormAndPointShareTheirLinks() {
        // A storm's share disc in its panel.
        let code = "2026102012009999999999"
        app.launchEnvironment["MC_CELL_FIXTURE"] = Self.cellFixture(code: code)
        launch(link: "?latLonZ=48.14,11.56,9&cell=\(code)")
        XCTAssertTrue(element("nativeMap.storm.details").waitForExistence(timeout: 30))
        element("nativeMap.storm.share").tap()
        let sheet = app.otherElements.matching(NSPredicate(format: "identifier IN %@", ["map.share", "ActivityListView"])).firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "The storm's share sheet")
        screenshot("storm share")
        // Put away as a sheet is, by pulling it down.
        let top = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        top.press(forDuration: 0.05, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.0)))
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        element("nativeMap.storm.close").tap()
        // A place's, from the hold menu, once the storm's panel has gone.
        XCTAssertTrue(element("nativeMap.storm.details").waitForNonExistence(timeout: 5))
        hold(0.5, 0.3)
        let share = element("nativeMap.point.share")
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        share.tap()
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "The place's share sheet")
        screenshot("point share")
    }

    func testLocateButtonCentresOnTheUser() {
        // Berlin, held whatever the simulator's own position is.
        app.resetAuthorizationStatus(for: .location)
        app.launchEnvironment["MC_USER_LOCATION"] = "52.520,13.405"
        // And the simulator's own, so Core Location has a fix to deliver; a
        // phone has a real one, and the held position stands in for it.
        #if targetEnvironment(simulator)
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(latitude: 52.520, longitude: 13.405))
        #endif
        // The system's question, answered when it comes up.
        addUIInterruptionMonitor(withDescription: "Location") { alert in
            for label in ["Allow While Using App", "Allow Once", "Allow"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        launch(link: "?latLonZ=48.14,11.58,8")
        waitForSeries()
        let view = element("nativeMap.view")
        XCTAssertTrue(view.waitForExistence(timeout: 10))
        app.buttons["map.location"].tap()
        // The monitor runs on the next interaction with the app.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 5) { allow.tap() } else { app.tap() }
        let deadline = Date().addingTimeInterval(20)
        func centre() -> (Double, Double)? {
            let parts = (view.value as? String)?.split(separator: ",").compactMap { Double($0) } ?? []
            return parts.count >= 2 ? (parts[0], parts[1]) : nil
        }
        while Date() < deadline, !(centre().map { abs($0.0 - 52.52) < 0.3 && abs($0.1 - 13.405) < 0.3 } ?? false) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        let at = centre()
        XCTAssertNotNil(at)
        XCTAssertEqual(at?.0 ?? 0, 52.52, accuracy: 0.3, "Centred on the user, not still on Munich")
        XCTAssertEqual(at?.1 ?? 0, 13.405, accuracy: 0.3)
        screenshot("located")
        // Leaves no permission behind: the tests after it see no position.
        app.resetAuthorizationStatus(for: .location)
    }

    // MARK: - The app around it

    func testLocateButtonFliesTheThreeDMapToTheUser() {
        // Berlin, held, while the 3D map looks at the south of France.
        app.resetAuthorizationStatus(for: .location)
        app.launchEnvironment["MC_USER_LOCATION"] = "52.520,13.405"
        #if targetEnvironment(simulator)
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(latitude: 52.520, longitude: 13.405))
        #endif
        addUIInterruptionMonitor(withDescription: "Location") { alert in
            for label in ["Allow While Using App", "Allow Once", "Allow"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        launch(link: "?latLonZ=44,3.5,7&layer=cells3d&pitch=40")
        let canvas = element("nativeMap.3d.canvas")
        XCTAssertTrue(canvas.waitForExistence(timeout: 20))
        XCTAssertTrue(waitForValue(canvas) { $0.hasPrefix("40,") }, "The link's tilt: \(canvas.value ?? "")")
        app.buttons["map.location"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 5) { allow.tap() } else { app.tap() }
        // Over the reader, still tilted as it was; their dot on the ground.
        func camera() -> [Double] { (canvas.value as? String)?.split(separator: ",").compactMap { Double($0) } ?? [] }
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, !(camera().count >= 4 && abs(camera()[2] - 52.52) < 0.3 && abs(camera()[3] - 13.405) < 0.3) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        let at = camera()
        XCTAssertGreaterThanOrEqual(at.count, 4, "\(canvas.value ?? "")")
        XCTAssertEqual(at.count >= 4 ? at[2] : 0, 52.52, accuracy: 0.3, "Over the user, not still over France")
        XCTAssertEqual(at.count >= 4 ? at[3] : 0, 13.405, accuracy: 0.3)
        XCTAssertEqual(at.first ?? 0, 40, accuracy: 1, "As tilted as before")
        XCTAssertTrue(element("nativeMap.3d.location").waitForExistence(timeout: 10), "The reader's dot")
        screenshot("3D map located")
        app.resetAuthorizationStatus(for: .location)
    }

    func testShareSendsALinkToTheView() {
        launch()
        waitForSeries()
        app.buttons["map.share.button"].tap()
        // The app names its sheet; newer systems show their own list in its place.
        let sheet = app.otherElements.matching(NSPredicate(format: "identifier IN %@", ["map.share", "ActivityListView"])).firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        screenshot("share sheet")
    }

    func testSettingsSwitchBringsTheWebMapBack() {
        launch()
        waitForSeries()
        app.buttons["map.settings"].tap()
        let toggle = app.switches["Native Map (Beta)"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "0")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(map.exists)
    }

    // MARK: - Site mode

    /// Turns the radars' marks on, as the layers panel does; they are off
    /// until then (`layerSites`).
    private func turnOnRadarSites() {
        openLayers()
        let sites = app.switches["nativeMap.layers.sites"].firstMatch
        XCTAssertTrue(sites.waitForExistence(timeout: 5))
        for _ in 0 ..< 4 where !sites.isHittable { element("nativeMap.layers").swipeUp() }
        XCTAssertEqual(sites.value as? String, "0", "Off until turned on")
        sites.switches.firstMatch.tap()
        XCTAssertTrue(waitForValue(sites) { $0 == "1" }, "Switched on")
        element("nativeMap.layers.close").tap()
    }

    /// Opens a radar from its mark, and waits for its sweep to be drawn.
    @discardableResult
    private func openSite(_ code: String, name: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let mark = element("nativeMap.site.\(code)")
        XCTAssertTrue(mark.waitForExistence(timeout: 20), "\(name)'s mark", file: file, line: line)
        mark.tap()
        let tray = element("nativeMap.site")
        if !tray.waitForExistence(timeout: 5) { screenshot("\(code) did not open") }
        XCTAssertTrue(tray.waitForExistence(timeout: 5), "The radar's tray", file: file, line: line)
        XCTAssertEqual(tray.label, "\(name) radar", file: file, line: line)
        let status = element("nativeMap.site.status")
        XCTAssertTrue(status.waitForExistence(timeout: 20), file: file, line: line)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, !status.label.hasPrefix("Scanned") { RunLoop.current.run(until: Date().addingTimeInterval(0.3)) }
        XCTAssertTrue(status.label.range(of: #"^Scanned \d\d?:\d\d:\d\d"#, options: .regularExpression) != nil,
                      "Says when it was scanned: \(status.label)", file: file, line: line)
        return tray
    }

    func testRadarMarksAreOffUntilTurnedOn() {
        launch(link: "?latLonZ=50.2,9.2,7.4")
        waitForSeries()
        XCTAssertFalse(element("nativeMap.site.deoft").waitForExistence(timeout: 6))
    }

    func testRadarMarkOpensItsSweepWithItsTiltsAndClosesBackToTheTimeline() {
        launch(link: "?latLonZ=50.2,9.2,7.4")
        waitForSeries()
        turnOnRadarSites()
        let tray = openSite("deoft", name: "Offenthal")
        // The timeline gives way to the radar: nothing to play, nothing to go back to.
        XCTAssertTrue(timeline.waitForNonExistence(timeout: 5))
        XCTAssertFalse(playButton.exists)
        XCTAssertFalse(element("nativeMap.backToNow").exists)
        XCTAssertTrue(element("nativeMap.site.deoft").isSelected, "The open radar's mark")
        // Its tilts, each with how high its beam is 100 km out.
        let tilt = element("nativeMap.site.tilt")
        XCTAssertTrue(tilt.waitForExistence(timeout: 5))
        XCTAssertTrue((tilt.value as? String ?? "").hasPrefix("0.5° · "), "The lowest tilt: \(tilt.value ?? "")")
        screenshot("site reflectivity")

        // Velocity is offered, the site publishing it, with its own legend.
        let velocity = tray.buttons["Velocity"].firstMatch
        XCTAssertTrue(velocity.waitForExistence(timeout: 5))
        velocity.tap()
        XCTAssertTrue(velocity.isSelected)
        XCTAssertTrue(element("nativeMap.site.legend").waitForExistence(timeout: 10))
        XCTAssertFalse(element("nativeMap.legend").exists)
        // DWD's velocity is not dealiased by the server: the tray says so.
        let note = element("nativeMap.site.note")
        XCTAssertTrue(note.waitForExistence(timeout: 15))
        screenshot("site velocity")
        // Another tilt, kept across the change of quantity.
        tilt.tap()
        let tilts = app.buttons.matching(NSPredicate(format: "label MATCHES %@", #"^\d+\.\d° · \d+\.\d km$"#))
        XCTAssertTrue(tilts.firstMatch.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(tilts.count, 5, "DWD scans a volume of tilts")
        tilts.element(boundBy: 1).tap()
        XCTAssertTrue(waitForValue(tilt) { !$0.hasPrefix("0.5° ") }, "Another tilt")
        // Storm-relative needs a storm to take the motion of.
        tray.buttons["Storm-relative"].firstMatch.tap()
        XCTAssertTrue(waitForLabel(note) { $0.hasPrefix("Select a storm") })

        element("nativeMap.site.close").tap()
        XCTAssertTrue(tray.waitForNonExistence(timeout: 5))
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
        XCTAssertTrue(element("nativeMap.legend").exists)
    }

    func testHoldInsideAnOpenRadarReadsItsBin() {
        launch(link: "?latLonZ=50.0,8.71,8.6")
        waitForSeries()
        turnOnRadarSites()
        openSite("deoft", name: "Offenthal")
        hold(0.72, 0.42)
        XCTAssertTrue(element("nativeMap.point.menu").waitForExistence(timeout: 5))
        let reading = element("nativeMap.point.siteReading")
        XCTAssertTrue(reading.waitForExistence(timeout: 5), "The menu reads the bin")
        XCTAssertTrue(reading.label.range(of: #"° · \d+\.\d km · beam \d+\.\d km$"#, options: .regularExpression) != nil,
                      "Where the bin is: \(reading.label)")
        screenshot("site reading")
    }

    /// Borkum's sweep reaches 180 km; out at sea 400 km north of it there is
    /// no other radar and seldom a storm.
    func testTapPastAnOpenRadarsReachClosesIt() {
        launch(link: "?latLonZ=53.56413,6.74832,6.4")
        waitForSeries()
        turnOnRadarSites()
        let tray = openSite("deasb", name: "Borkum")
        // In points from the radar's mark, the same distances on every
        // screen: at zoom 6.4 about 0.9 pt a kilometre.
        let mark = element("nativeMap.site.deasb")
        let radar = mark.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        // Inside its reach, some 65 km east: still open, even where the tap
        // lands on a live storm and its panel puts the tray away.
        radar.withOffset(CGVector(dx: 60, dy: 0)).tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertTrue(mark.isSelected, "Still open")
        let closeStorm = app.buttons["nativeMap.storm.close"].firstMatch
        if !tray.exists, closeStorm.exists { closeStorm.tap() }
        // Some 330 km north, at sea.
        radar.withOffset(CGVector(dx: -60, dy: -300)).tap()
        XCTAssertTrue(tray.waitForNonExistence(timeout: 5))
        XCTAssertFalse(mark.isSelected)
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
    }

    func testTurningRadarSitesOffClosesTheOpenRadar() {
        launch(link: "?latLonZ=50.2,9.2,7.4")
        waitForSeries()
        turnOnRadarSites()
        let tray = openSite("deoft", name: "Offenthal")
        openLayers()
        let sites = app.switches["nativeMap.layers.sites"].firstMatch
        for _ in 0 ..< 4 where !sites.isHittable { element("nativeMap.layers").swipeUp() }
        sites.switches.firstMatch.tap()
        XCTAssertTrue(waitForValue(sites) { $0 == "0" })
        element("nativeMap.layers.close").tap()
        XCTAssertTrue(tray.waitForNonExistence(timeout: 5))
        XCTAssertFalse(element("nativeMap.site.deoft").exists)
    }

    private func waitForLabel(_ element: XCUIElement, timeout: TimeInterval = 10, _ matches: (String) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, matches(element.label) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return false
    }
}
