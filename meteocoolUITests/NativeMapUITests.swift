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
    private func launch(link: String? = nil, demo: Bool = false) {
        app.launchArguments = ["--ui-test-reset", "--native-map", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-environment", demo ? "demo" : "staging"]
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
    }

    /// Holds the map at a point given as fractions of its size.
    private func hold(_ dx: CGFloat, _ dy: CGFloat) {
        map.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy)).press(forDuration: 1.0)
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
        XCTAssertTrue(waitForValue(timeline) { $0 == live }, "Back to \(live), at \(timeline.value ?? "")")
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
    }

    func testStatusPillOpensConnectionDetails() {
        launch()
        waitForSeries()
        element("nativeMap.pill").tap()
        XCTAssertTrue(element("nativeMap.connectionDetails").waitForExistence(timeout: 5))
        screenshot("connection details")
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(element("nativeMap.connectionDetails").waitForNonExistence(timeout: 5))
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
        if days.exists { element("nativeMap.compare.range").buttons["7 days"].tap() }
        screenshot("model comparison")
        element("nativeMap.compare.close").tap()
        XCTAssertTrue(element("nativeMap.compare").waitForNonExistence(timeout: 5))
    }

    /// A German city the radar has no rain for over the last two hours,
    /// asked of the deployment the app opens on.
    private func dryCity() -> (lat: Double, lon: Double)? {
        let cities = [(52.52, 13.40), (48.14, 11.58), (50.94, 6.96), (51.34, 12.37), (49.45, 11.08), (53.55, 9.99), (50.11, 8.68)]
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
        // edge too) and of the "3D" tags, which stand over the discs.
        let screen = app.windows.firstMatch.frame
        let tags = app.descendants(matching: .any).matching(identifier: "nativeMap.cloudHint")
        let tagFrames = (0 ..< tags.count).map { tags.element(boundBy: $0).frame.insetBy(dx: -6, dy: -6) }
        let onScreen = (0 ..< storms.count).map { storms.element(boundBy: $0) }.first { storm in
            let frame = storm.frame
            return frame.midX > screen.width * 0.08 && frame.midX < screen.width * 0.8
                && frame.midY > screen.height * 0.17 && frame.midY < screen.height * 0.65
                && !tagFrames.contains { $0.intersects(frame) }
        }
        XCTAssertNotNil(onScreen, "A storm in view")
        onScreen?.tap()
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
        // One in the open middle of the screen, clear of the controls and a
        // wide screen's panel.
        let screen = app.windows.firstMatch.frame
        let onScreen = (0 ..< tags.count).map { tags.element(boundBy: $0) }.first { tag in
            let frame = tag.frame
            return frame.midX > screen.width * 0.08 && frame.midX < screen.width * 0.75
                && frame.midY > screen.height * 0.17 && frame.midY < screen.height * 0.65
        }
        let tag = try XCTUnwrap(onScreen, "A tag in view")
        screenshot("3D tags")
        tag.tap()
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
        // A storm whose newest step is the patch a listed core was cut from:
        // the scan the demo's cores and storms are both at now.
        var found: (id: String, core: Core)?
        let since = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3 * 3600))
        search: for core in demoCores().prefix(12) {
            guard let feature = core.feature, let stamp = feature.split(separator: "/").first(where: { $0.count == 16 && $0.hasSuffix("Z") })
            else { continue }
            let box = [core.lon - 0.4, core.lat - 0.3, core.lon + 0.4, core.lat + 0.3].map { String(format: "%.3f", $0) }.joined(separator: ",")
            guard let answer = demoJSON("storms?bbox=\(box)&since=\(since)") as? [String: Any],
                  let storms = answer["features"] as? [[String: Any]] else { continue }
            for storm in storms {
                guard let properties = storm["properties"] as? [String: Any], let id = properties["id"] as? String,
                      let seen = properties["last_seen"] as? String,
                      seen.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "") == stamp,
                      let url = URL(string: "https://data-demo.meteocool.com/storms/\(id)"),
                      let detail = try? String(contentsOf: url, encoding: .utf8), detail.contains("\"\(feature)\"") else { continue }
                found = (id, core)
                break search
            }
        }
        guard let found else { throw XCTSkip("No demo storm holds a listed core this scan") }
        launch(link: "?latLonZ=\(found.core.lat),\(found.core.lon),8&storm=\(found.id)", demo: true)
        XCTAssertTrue(element("nativeMap.storm.details").waitForExistence(timeout: 30))
        XCTAssertTrue(element("nativeMap.storm.cutaway").waitForExistence(timeout: 30), "The panel cuts the storm open")
        XCTAssertTrue(element("nativeMap.storm.radars").exists)
        screenshot("storm cut open")
        let open3d = element("nativeMap.storm.open3d")
        XCTAssertTrue(open3d.waitForExistence(timeout: 5))
        open3d.tap()
        XCTAssertTrue(element("nativeMap.3d").waitForExistence(timeout: 10))
        XCTAssertTrue(element("nativeMap.storm.cappi").waitForExistence(timeout: 30))
    }

    /// A KONRAD3D cell measured in three layers, as `/cells/tracks/{code}`
    /// sends it, seen a minute ago.
    private static func cellFixture(code: String) -> String {
        let iso = ISO8601DateFormatter()
        let seen = iso.string(from: Date().addingTimeInterval(-60))
        let born = iso.string(from: Date().addingTimeInterval(-40 * 60))
        return """
        {"type": "Feature", "properties": {"code": "\(code)", "first_seen": "\(born)", "last_seen": "\(seen)",
         "n_steps": 9, "active": true, "max_severity": 2, "max_dbz": 58, "echo_top_max_m": 11000, "echo_bottom_m": 1200,
         "polygon": [[11.50, 48.10], [11.62, 48.10], [11.62, 48.18], [11.50, 48.18]],
         "series": [{"t": "\(seen)", "lon": 11.56, "lat": 48.14, "severity": 2, "max_dbz": 58, "echo_top_m": 11000, "area_km2": 95}],
         "structure": [{"dbz": 30, "area_km2": 95, "top_m": 9200, "volume_km3": 400},
                       {"dbz": 45, "area_km2": 30, "top_m": 7600, "volume_km3": 100},
                       {"dbz": 55, "area_km2": 4, "top_m": 6100, "volume_km3": 12}]}}
        """
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
        for layer in ["lightning", "mesocyclones", "storms", "nowcast", "fromStart", "cells3d", "terrain3d"] {
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
        launch(link: "?latLonZ=44,3.5,7&layer=cells3d", demo: true)
        XCTAssertTrue(element("nativeMap.3d").waitForExistence(timeout: 20))
        XCTAssertTrue(element("nativeMap.3d.north").exists)
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
        // A place's, from the hold menu.
        hold(0.5, 0.3)
        let share = element("nativeMap.point.share")
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        share.tap()
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "The place's share sheet")
        screenshot("point share")
    }

    // MARK: - The app around it

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
}
