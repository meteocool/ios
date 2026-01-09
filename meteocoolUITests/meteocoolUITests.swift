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

        let displayPicker = app.pickers["Display Style"]
        XCTAssertTrue(displayPicker.waitForExistence(timeout: 5))
        displayPicker.buttons["Dark"].tap()

        app.buttons["Close"].tap()

        app.terminate()
        app.launch()

        if app.buttons["Continue"].exists {
            app.buttons["Continue"].tap()
        }

        app.buttons["OpenSettings"].tap()
        let displayPickerAfter = app.pickers["Display Style"]
        XCTAssertTrue(displayPickerAfter.waitForExistence(timeout: 5))
        XCTAssertEqual(displayPickerAfter.value as? String, "Dark")
    }
}
