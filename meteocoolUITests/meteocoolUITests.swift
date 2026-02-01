import XCTest

class meteocoolUITests: XCTestCase {
    let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
        SpringboardHelper.deleteMyApp()

        setupSnapshot(app)
        app.launch()

        addUIInterruptionMonitor(withDescription: "Alert") {
            (alert) -> Bool in
            let okButton = alert.buttons["OK"]
            if okButton.exists {
                okButton.tap()
            }
            let allowButton = alert.buttons["Allow"]
            if allowButton.exists {
                allowButton.tap()
            }
            let alwaysAllowButton = alert.buttons["Always Allow"]
            if alwaysAllowButton.exists {
                alwaysAllowButton.tap()
            }
            return true
        }
    }

    override func tearDown() {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testOnboarding() {
        let continueButton = app.buttons["Continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 5))
        snapshot("1-Onboarding")
        continueButton.tap()
        snapshot("0-Launch1")
    }

    func testDisplayStylePersistsAfterRelaunch() {
        let app = XCUIApplication()
        app.launch()

        if app.buttons["Continue"].exists {
            app.buttons["Continue"].tap()
        }

        let settingsButton = app.buttons["OpenSettings"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.tap()

        // SwiftUI Form Picker renders as a menu/popup button
        let displayStyleButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Display Style' OR label CONTAINS[c] 'Dark' OR label CONTAINS[c] 'Light' OR label CONTAINS[c] 'System'")).firstMatch
        XCTAssertTrue(displayStyleButton.waitForExistence(timeout: 5))
        displayStyleButton.tap()

        // Select "Dark" from the picker menu
        let darkOption = app.buttons["Dark"]
        if darkOption.waitForExistence(timeout: 2) {
            darkOption.tap()
        }

        // Close settings
        let closeButton = app.buttons["Close"]
        if closeButton.exists {
            closeButton.tap()
        }

        app.terminate()
        app.launch()

        if app.buttons["Continue"].exists {
            app.buttons["Continue"].tap()
        }

        app.buttons["OpenSettings"].tap()

        // Verify the display style is still Dark
        let displayStyleAfter = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Dark'")).firstMatch
        XCTAssertTrue(displayStyleAfter.waitForExistence(timeout: 5), "Display style should persist as Dark after relaunch")
    }
}
