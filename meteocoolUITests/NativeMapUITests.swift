import XCTest

/// The native MapKit map (`meteocool/NativeMap`), against the staging
/// backend: these need the network.
final class NativeMapUITests: XCTestCase {
    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments = ["--ui-test-reset", "--native-map", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-environment", "staging"]
        app.launch()
    }

    private var timeline: XCUIElement { app.otherElements["nativeMap.timeline"].firstMatch }
    private var timeLabel: XCUIElement { app.staticTexts["nativeMap.time"].firstMatch }
    private var playButton: XCUIElement { app.buttons["nativeMap.play"].firstMatch }

    /// The timeline once the series has loaded: its label names a step.
    private func waitForSeries(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.otherElements["nativeMap"].firstMatch.waitForExistence(timeout: 15), "No native map", file: file, line: line)
        let loaded = NSPredicate(format: "label CONTAINS 'Now' OR label CONTAINS 'm ·' OR label CONTAINS 'h ·'")
        expectation(for: loaded, evaluatedWith: timeLabel)
        waitForExpectations(timeout: 40)
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testNativeMapOpensOnTheLiveRadar() {
        waitForSeries()
        XCTAssertTrue(timeLabel.label.hasPrefix("Now"), timeLabel.label)
        XCTAssertTrue(app.buttons["map.layers"].isEnabled)
        screenshot("native map")
    }

    func testPlayingMovesThroughTheSteps() {
        waitForSeries()
        let start = timeLabel.label
        playButton.tap()
        XCTAssertEqual(playButton.label, "Pause")
        let moved = NSPredicate(format: "label != %@", start)
        expectation(for: moved, evaluatedWith: timeLabel)
        waitForExpectations(timeout: 15)
        playButton.tap()
        XCTAssertEqual(playButton.label, "Play")
    }

    func testScrubbingBackShowsAnEarlierStep() {
        waitForSeries()
        let middle = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let start = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
        middle.press(forDuration: 0.05, thenDragTo: start)
        let earlier = NSPredicate(format: "label BEGINSWITH '-'")
        expectation(for: earlier, evaluatedWith: timeLabel)
        waitForExpectations(timeout: 5)
        // The logo brings the live radar back.
        app.descendants(matching: .any)["map.logo"].firstMatch.tap()
        let live = NSPredicate(format: "label BEGINSWITH 'Now'")
        expectation(for: live, evaluatedWith: timeLabel)
        waitForExpectations(timeout: 5)
    }

    func testLayersMenuTurnsLightningOff() {
        waitForSeries()
        app.buttons["map.layers"].tap()
        let lightning = app.buttons["Lightning"].firstMatch
        XCTAssertTrue(lightning.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Mesocyclones"].exists && app.buttons["Storms"].exists)
        lightning.tap()
        app.buttons["map.layers"].tap()
        XCTAssertTrue(app.buttons["Lightning"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Lightning"].firstMatch.isSelected)
    }

    func testShareSendsALinkToTheView() {
        waitForSeries()
        app.buttons["map.share.button"].tap()
        let sheet = app.otherElements["map.share"].firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        screenshot("share sheet")
    }

    func testSettingsSwitchBringsTheWebMapBack() {
        waitForSeries()
        app.buttons["map.settings"].tap()
        let toggle = app.switches["Native Map (Beta)"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "0")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.otherElements["nativeMap"].firstMatch.exists)
    }
}
