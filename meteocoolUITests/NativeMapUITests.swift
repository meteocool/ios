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
        // The models answer, or say they could not.
        let answered = NSPredicate(format: "exists == true")
        expectation(for: answered, evaluatedWith: app.staticTexts["Next 7 Days"].firstMatch)
        waitForExpectations(timeout: 40)
        element("nativeMap.compare.range").buttons["7 days"].tap()
        screenshot("model comparison")
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

    func testCellPanelShowsItsMeasuredStructure() throws {
        // A KONRAD3D cell the demo measured in layers, opened by its link:
        // from the tracks, which keep a cell for a while after the newest
        // run's list has moved on.
        let answer = demoJSON("cells/tracks?bbox=-10,35,30,60") as? [String: Any]
        let cells = (answer?["features"] as? [[String: Any]] ?? []).compactMap { track -> (String, Double, Double)? in
            guard let p = track["properties"] as? [String: Any], let structure = p["structure"] as? [Any], !structure.isEmpty,
                  let code = p["code"] as? String, let at = (p["series"] as? [[String: Any]])?.last,
                  let lat = at["lat"] as? Double, let lon = at["lon"] as? Double else { return nil }
            return (code, lat, lon)
        }
        // One whose own track is served: a run's tracks can lag its list.
        let served = cells.first { (demoJSON("cells/tracks/\($0.0)") as? [String: Any])?["properties"] != nil }
        guard let (code, lat, lon) = served else { throw XCTSkip("No KONRAD3D cell with a structure in the last runs") }
        launch(link: "?latLonZ=\(lat),\(lon),8&cell=\(code)", demo: true)
        XCTAssertTrue(element("nativeMap.storm.details").waitForExistence(timeout: 30))
        let model = element("nativeMap.storm.structure")
        XCTAssertTrue(model.waitForExistence(timeout: 20), "The cell's measured model")
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
