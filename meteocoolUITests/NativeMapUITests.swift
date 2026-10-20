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
        let loaded = NSPredicate(format: "value CONTAINS 'Now' OR value CONTAINS 'min' OR value CONTAINS 'h'")
        expectation(for: loaded, evaluatedWith: timeline)
        waitForExpectations(timeout: 60)
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
        launch()
        waitForSeries()
        let start = timeline.value as? String ?? ""
        playButton.tap()
        XCTAssertEqual(playButton.value as? String, "playing")
        expectation(for: NSPredicate(format: "value != %@", start), evaluatedWith: timeline)
        waitForExpectations(timeout: 20)
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
        expectation(for: NSPredicate(format: "value BEGINSWITH '-'"), evaluatedWith: timeline)
        waitForExpectations(timeout: 5)
        let back = element("nativeMap.backToNow")
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        expectation(for: NSPredicate(format: "value == %@", live), evaluatedWith: timeline)
        waitForExpectations(timeout: 5)
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

    func testStormTapShowsTheHintThenTheDetails() {
        launch(link: "?latLonZ=44,3.5,7", demo: true)
        waitForSeries()
        let storms = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'nativeMap.storm.01'"))
        XCTAssertTrue(storms.firstMatch.waitForExistence(timeout: 30), "The demo replays a storm")
        storms.element(boundBy: min(2, storms.count - 1)).tap()
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
        let sheet = app.otherElements["map.share"].firstMatch
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
