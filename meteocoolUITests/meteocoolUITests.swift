import XCTest
import UIKit

final class meteocoolUITests: XCTestCase {
    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments = ["--ui-test-reset", "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-experimentalFeatures", "YES"]
        app.launch()
    }

    private func tap(_ title: String) {
        let button = app.buttons[title]
        XCTAssertTrue(button.waitForExistence(timeout: 15), "Missing button: \(title)")
        button.tap()
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testPickerSelectionKeepsRowGeometry() {
        verifyPickerSelectionGeometry()
    }

    func testPickerSelectionWithLargeText() {
        app.terminate()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        verifyPickerSelectionGeometry()
    }

    @MainActor
    func testSavedPickerChoicesReachWebViewAndSurviveRelaunch() async throws {
        let server = URL(string: "http://127.0.0.1:18765/")!
        do { _ = try await URLSession.shared.data(from: server.appendingPathComponent("map/recover")) }
        catch { throw XCTSkip("Start node tests/mobile-api-recorder.mjs") }
        app.terminate()
        app.launchEnvironment = ["MC_TEST_API_URL": server.absoluteString, "MC_TEST_MAP": "1"]
        app.launch()
        tap("Next")
        tap("Next")
        tap("Later")
        tap("Later")
        tap("Next")
        tap("Done")
        XCTAssertTrue(app.webViews.staticTexts["mapBaseLayer=light;radarColorMapping=classic"].waitForExistence(timeout: 15))
        tap("map.settings")
        for (title, choice) in [("Base Map Layer", "OpenStreetMap"), ("Radar Color Map", "Homeyer (Color Vision Deficiency)")] {
            app.staticTexts[title].tap()
            app.tables["settings.options"].staticTexts[choice].tap()
            tap("Save")
        }
        tap("Done")
        let expected = "mapBaseLayer=osm;radarColorMapping=homeyer"
        XCTAssertTrue(app.webViews.staticTexts[expected].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments.removeAll { $0 == "--ui-test-reset" }
        app.launch()
        XCTAssertTrue(app.webViews.staticTexts[expected].waitForExistence(timeout: 15))
        tap("map.settings")
        for (title, saved, cancelled) in [("Base Map Layer", "OpenStreetMap", "Dark"),
                                         ("Radar Color Map", "Homeyer (Color Vision Deficiency)", "Lang")] {
            app.staticTexts[title].tap()
            let table = app.tables["settings.options"]
            for cell in table.cells.allElementsBoundByIndex {
                XCTAssertEqual(try hasVisibleCheckmark(cell), cell.staticTexts[saved].exists)
            }
            table.staticTexts[cancelled].tap()
            tap("Cancel")
        }
        tap("Done")
        XCTAssertTrue(app.webViews.staticTexts[expected].waitForExistence(timeout: 5), "Cancel must not change the map's settings")
    }

    // Read rendered pixels, independently of the cell's selected accessibility trait.
    // UIKit may change accessory visibility after the data source configures the cell.
    private func hasVisibleCheckmark(_ cell: XCUIElement) throws -> Bool {
        let image = try XCTUnwrap(cell.screenshot().image.cgImage)
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var bluePixels = 0
        for y in 0..<height {
            for x in (width * 3 / 4)..<width {
                let offset = (y * width + x) * 4
                let red = Int(pixels[offset]), green = Int(pixels[offset + 1]), blue = Int(pixels[offset + 2])
                if blue > 150 && blue > red + 60 && green > red + 30 { bluePixels += 1 }
            }
        }
        return bluePixels > 5
    }

    private func verifyPickerSelectionGeometry() {
        tap("Next")
        tap("Next")
        tap("Later")
        tap("Later")
        tap("Next")
        tap("Done")
        tap("map.settings")
        for (title, options) in [
            ("Base Map Layer", ["Light", "Dark", "OpenStreetMap", "CyclOSM (Biking)"]),
            ("Radar Color Map", ["Classic", "NWS Reflectivity", "PyArt StepSeq", "Homeyer (Color Vision Deficiency)", "Lang"])
        ] {
            app.staticTexts[title].tap()
            XCTAssertTrue(app.staticTexts[options[0]].waitForExistence(timeout: 5))
            let table = app.tables["settings.options"]
            var previousIndex = 0
            for index in Array(0..<options.count) + Array((0..<options.count).reversed()) {
                let label = table.staticTexts[options[index]]
                for _ in 0..<8 {
                    if label.isHittable { break }
                    if index < previousIndex { table.swipeDown() } else { table.swipeUp() }
                }
                XCTAssertTrue(label.isHittable)
                // Tables materialize offscreen rows on demand. Measure the actual
                // visible rows immediately before each selection, not estimated offscreen frames.
                let visible = options.compactMap { option -> (String, CGFloat, CGSize)? in
                    let cell = table.cells.containing(.staticText, identifier: option).firstMatch
                    guard cell.exists else { return nil }
                    return (option, cell.frame.height, table.staticTexts[option].frame.size)
                }
                label.tap()
                XCTAssertTrue(table.cells.containing(.staticText, identifier: options[index]).firstMatch.isSelected,
                              "The tapped option must be checked")
                for (option, height, textSize) in visible {
                    let cell = table.cells.containing(.staticText, identifier: option).firstMatch
                    guard cell.exists else { continue }
                    XCTAssertEqual(cell.frame.height, height, accuracy: 0.5, "\(title): \(option) resized")
                    let size = table.staticTexts[option].frame.size
                    XCTAssertEqual(size.width, textSize.width, accuracy: 0.5, "\(option) text width changed")
                    XCTAssertEqual(size.height, textSize.height, accuracy: 0.5, "\(option) text reflowed")
                    if cell.frame.minY >= app.buttons["Save"].frame.maxY &&
                        cell.frame.maxY <= min(table.frame.maxY, app.frame.maxY) {
                        XCTAssertEqual(try? hasVisibleCheckmark(cell), option == options[index],
                                       "\(title): \(option) rendered the wrong checkmark state")
                        XCTAssertEqual(cell.isSelected, option == options[index])
                    }
                }
                previousIndex = index
            }
            screenshot("\(title) after selecting every option")
            tap("Save")
            let settings = app.tables.element(boundBy: app.tables.count - 1)
            XCTAssertTrue(settings.staticTexts[options[0]].waitForExistence(timeout: 5))
            settings.staticTexts[title].tap()
            let picker = app.tables["settings.options"]
            let lastOption = picker.staticTexts[options.last!]
            for _ in 0..<8 {
                if lastOption.isHittable { break }
                picker.swipeUp()
            }
            XCTAssertTrue(lastOption.isHittable)
            lastOption.tap()
            let firstOption = picker.staticTexts[options[0]]
            for _ in 0..<8 {
                if firstOption.isHittable { break }
                picker.swipeDown()
            }
            XCTAssertTrue(firstOption.isHittable)
            XCTAssertFalse(picker.cells.containing(.staticText, identifier: options[0]).firstMatch.isSelected,
                           "An offscreen old choice must be unchecked when it returns")
            for _ in 0..<8 {
                if lastOption.isHittable { break }
                picker.swipeUp()
            }
            XCTAssertTrue(lastOption.isHittable)
            XCTAssertTrue(picker.cells.containing(.staticText, identifier: options.last!).firstMatch.isSelected)
            tap("Cancel")
            XCTAssertTrue(settings.staticTexts[options[0]].waitForExistence(timeout: 5), "Cancel must preserve the saved choice")
        }
    }

    func testSettingsRowAlignment() {
        tap("Next")
        tap("Next")
        tap("Later")
        tap("Later")
        tap("Next")
        tap("Done")
        tap("map.settings")
        screenshot("Settings alignment")
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        let table = app.tables.firstMatch
        let label = table.staticTexts["Enable Notifications"]
        let toggle = table.switches["Enable Notifications"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let cell = table.cells.containing(.switch, identifier: "Enable Notifications").firstMatch
        XCTAssertGreaterThan(label.frame.minX, cell.frame.minX + 8)
        XCTAssertLessThanOrEqual(label.frame.maxX + 8, toggle.frame.minX)
        XCTAssertLessThan(toggle.frame.maxX, cell.frame.maxX)
        XCTAssertLessThan(cell.frame.maxX - toggle.frame.maxX, 32)
        XCTAssertEqual(label.frame.midY, toggle.frame.midY, accuracy: 2)
    }

    @MainActor
    func testLocalPlaybackLayout() async throws {
        let page = URL(string: "http://127.0.0.1:18765/ios.html")!
        guard let (data, _) = try? await URLSession.shared.data(from: page),
              String(data: data, encoding: .utf8)?.contains("/src/entrypoints/ios.ts") == true else {
            throw XCTSkip("Start core with npm run dev -- --host 127.0.0.1 --port 18765")
        }
        app.terminate()
        app.launchEnvironment = ["MC_TEST_API_URL": "http://127.0.0.1:18765/", "MC_TEST_MAP": "1"]
        app.launch()
        tap("Next")
        tap("Next")
        tap("Later")
        tap("Later")
        tap("Next")
        tap("Done")
        let expand = app.buttons["Playback Controls"]
        XCTAssertTrue(expand.waitForExistence(timeout: 45))
        screenshot("Local collapsed playback")
        let bottomGap = app.frame.maxY - expand.frame.maxY
        XCTAssertGreaterThanOrEqual(bottomGap, 12)
        XCTAssertLessThanOrEqual(bottomGap, 48, "Collapsed controls should sit close to the bottom edge")
        expand.tap()
        XCTAssertTrue(app.buttons["Collapse playback controls"].waitForExistence(timeout: 10))
        let status = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'updated'")).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 30))
        screenshot("Local expanded playback")
        XCTAssertEqual(status.frame.midX, app.webViews.firstMatch.frame.midX, accuracy: 14)
        // The app supports rotation on iPad; iPhone is portrait-only.
        if app.frame.width > 600 {
            XCUIDevice.shared.orientation = .landscapeLeft
            defer { XCUIDevice.shared.orientation = .portrait }
            let rotated = expectation(for: NSPredicate { _, _ in self.app.frame.width > self.app.frame.height }, evaluatedWith: app)
            await fulfillment(of: [rotated], timeout: 5)
            screenshot("Local expanded playback landscape")
            XCTAssertEqual(status.frame.midX, app.webViews.firstMatch.frame.midX, accuracy: 14)
        }
        tap("Collapse playback controls")
    }

    func testNotificationSliderLayout() {
        app.terminate()
        app.launchArguments += ["-pushNotification", "YES"]
        app.launchEnvironment["MC_TEST_API_URL"] = "http://127.0.0.1:18765/"
        app.launch()
        tap("Next")
        tap("Next")
        tap("Later")
        tap("Later")
        tap("Next")
        tap("Done")
        tap("map.settings")
        for title in ["Intensity Threshold", "Notification Timeframe"] {
            let slider = app.sliders[title]
            XCTAssertTrue(slider.waitForExistence(timeout: 5))
            let cell = app.tables.cells.containing(.slider, identifier: title).firstMatch
            XCTAssertGreaterThanOrEqual(slider.frame.minX, cell.frame.minX + 8)
            XCTAssertLessThanOrEqual(slider.frame.maxX, cell.frame.maxX - 8)
            XCTAssertGreaterThan(slider.frame.minY, cell.staticTexts[title].frame.maxY)
            slider.adjust(toNormalizedSliderPosition: 1)
        }
        XCTAssertEqual(app.sliders["Notification Timeframe"].value as? String, "45 min")
        screenshot("Notification slider settings")
    }

    func testOnboardingWithoutPermissionsAndSettings() {
        if app.staticTexts["Hi there!"].waitForExistence(timeout: 5) {
            screenshot("Onboarding")
            tap("Next")
            tap("Next")
            tap("Later") // notifications are optional
            tap("Later") // location is optional
            tap("Next")
            tap("Done")
        }
        XCTAssertTrue(app.buttons["map.settings"].waitForExistence(timeout: 10))
        screenshot("Map")
        let layers = app.buttons["map.layers"]
        XCTAssertTrue(layers.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: layers)
        waitForExpectations(timeout: 30)
        layers.tap()
        let radar = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Rain' AND label CONTAINS[c] 'thunder'")).firstMatch
        XCTAssertTrue(radar.waitForExistence(timeout: 10))
        screenshot("Layer switcher")
        radar.tap()
        XCTAssertTrue(app.buttons["map.settings"].waitForExistence(timeout: 10))
        tap("Playback Controls")
        XCTAssertTrue(app.buttons["Collapse playback controls"].waitForExistence(timeout: 10))
        screenshot("Web playback")
        tap("Collapse playback controls")
        tap("map.settings")
        XCTAssertTrue(app.switches["Enable Notifications"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["Enable Notifications"].value as? String, "0")
        screenshot("Settings")

        let base = app.staticTexts["Base Map Layer"]
        XCTAssertTrue(base.exists)
        base.tap()
        XCTAssertTrue(app.staticTexts["Dark"].waitForExistence(timeout: 5))
        screenshot("Basemap settings")
        app.staticTexts["Dark"].tap()
        tap("Save")
        XCTAssertTrue(base.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Dark"].exists)
        base.tap()
        app.staticTexts["Light"].tap()
        tap("Cancel")
        XCTAssertTrue(base.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Dark"].exists, "Cancel must preserve the saved basemap")
        app.staticTexts["Radar Color Map"].tap()
        screenshot("Radar color settings")
        app.staticTexts["NWS Reflectivity"].tap()
        tap("Save")
        XCTAssertTrue(app.staticTexts["NWS Reflectivity"].waitForExistence(timeout: 5))
        app.staticTexts["Radar Color Map"].tap()
        app.staticTexts["Lang"].tap()
        tap("Cancel")
        XCTAssertTrue(app.staticTexts["NWS Reflectivity"].waitForExistence(timeout: 5))
        let rotation = app.switches["Two-Finger Map Rotation"]
        rotation.tap()
        XCTAssertEqual(rotation.value as? String, "1")
        let experimental = app.switches["Experimental Features"]
        for _ in 0..<4 {
            if experimental.isHittable { break }
            app.tables.firstMatch.swipeUp()
        }
        XCTAssertTrue(experimental.isHittable, "Experimental Features must expose its own accessibility label")
        screenshot("Settings lower rows")
        tap("Done")
        screenshot("Dark basemap")
        app.terminate()
        app.launchArguments.removeAll { $0 == "--ui-test-reset" }
        app.launch()
        XCTAssertTrue(app.buttons["map.settings"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Hi there!"].exists, "Completed onboarding must not return")
    }

    func testDarkLargeTextAndRotation() {
        app.terminate()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        screenshot("Large text onboarding")
        tap("Next")
        tap("Next")
        tap("Later")
        tap("Later")
        tap("Next")
        tap("Done")
        tap("map.settings")
        screenshot("Large text settings portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 1)
        screenshot("Large text settings landscape")
        tap("Done")
        XCTAssertTrue(app.buttons["map.settings"].waitForExistence(timeout: 10))
        screenshot("Landscape map")
        XCUIDevice.shared.orientation = .portrait
    }

    func testProductionMapControls() {
        app.terminate()
        app.launchArguments.removeAll { $0 == "-experimentalFeatures" || $0 == "YES" }
        app.launch()
        testOnboardingWithoutPermissionsAndSettings()
    }

    @MainActor
    func testMapFailureAndRetry() async throws {
        let server = URL(string: "http://127.0.0.1:18765/")!
        do { _ = try await URLSession.shared.data(from: server.appendingPathComponent("map/fail")) }
        catch { throw XCTSkip("Start node tests/mobile-api-recorder.mjs") }
        app.terminate()
        app.launchEnvironment = ["MC_TEST_API_URL": server.absoluteString, "MC_TEST_MAP": "1"]
        app.launch()
        tap("Next")
        tap("Next")
        tap("Later")
        tap("Later")
        tap("Next")
        tap("Done")
        XCTAssertTrue(app.buttons["map.retry"].waitForExistence(timeout: 35))
        XCTAssertFalse(app.buttons["map.layers"].isEnabled)
        tap("map.settings")
        XCTAssertTrue(app.switches["Enable Notifications"].exists)
        tap("Done")
        screenshot("Map failed with native controls")
        _ = try await URLSession.shared.data(from: server.appendingPathComponent("map/recover"))
        tap("map.retry")
        XCTAssertTrue(app.webViews.staticTexts["Map connection restored"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["map.layers"].isEnabled)
        XCTAssertFalse(app.buttons["map.retry"].exists)
    }

    func testDeniedPermissionsRemainUsable() {
        XCTAssertTrue(app.staticTexts["Hi there!"].waitForExistence(timeout: 10), "Run this test on a fresh installation")
        addUIInterruptionMonitor(withDescription: "Deny system permission") { alert in
            let deny = alert.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Don'")).firstMatch
            guard deny.exists else { return false }
            deny.tap()
            return true
        }
        tap("Next")
        tap("Next")
        tap("Tell Me Before It Rains!")
        app.tap()
        tap("Allow Location Access")
        app.tap()
        tap("Next")
        tap("Done")
        tap("map.location")
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        screenshot("Location denied recovery")
        tap("Dismiss")
        tap("map.settings")
        let notifications = app.switches["Enable Notifications"]
        XCTAssertTrue(notifications.waitForExistence(timeout: 5))
        XCTAssertEqual(notifications.value as? String, "0")
        notifications.tap()
        XCTAssertTrue(app.alerts["Check Permissions"].waitForExistence(timeout: 5))
        screenshot("Notifications denied recovery")
        tap("Dismiss")
        XCTAssertEqual(notifications.value as? String, "0")
        tap("Done")
    }

    func testLocationRecoveryFromSystemSettings() {
        tap("Next")
        tap("Next")
        tap("Later")
        tap("Later")
        tap("Next")
        tap("Done")
        tap("map.location")
        tap("Change In Settings")
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        // A fresh simulator can open Settings at its root on the first visit.
        if !settings.staticTexts["Location"].waitForExistence(timeout: 3) {
            let apps = settings.staticTexts["Apps"]
            for _ in 0..<6 {
                if apps.isHittable { break }
                settings.swipeUp()
            }
            XCTAssertTrue(apps.exists)
            apps.tap()
            let search = settings.searchFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            search.tap()
            search.typeText("meteocool")
            let entry = settings.staticTexts["meteocool"]
            XCTAssertTrue(entry.waitForExistence(timeout: 5))
            entry.tap()
        }
        XCTAssertTrue(settings.staticTexts["Location"].waitForExistence(timeout: 10))
        settings.staticTexts["Location"].tap()
        let hierarchy = XCTAttachment(string: settings.debugDescription)
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        let grant = settings.staticTexts["While Using the App"]
        XCTAssertTrue(grant.waitForExistence(timeout: 5))
        grant.tap()
        app.activate()
        tap("map.location")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        screenshot("Location restored in system Settings")
    }


    @MainActor
    func testNotificationPreferencesReachAPI() async throws {
        let endpoint = URL(string: "http://127.0.0.1:18765/requests")!
        var reset = URLRequest(url: endpoint)
        reset.httpMethod = "DELETE"
        do { _ = try await URLSession.shared.data(for: reset) }
        catch { throw XCTSkip("Start node tests/mobile-api-recorder.mjs and use a fresh simulator for permission grants") }
        app.terminate()
        app.launchEnvironment["MC_TEST_API_URL"] = "http://127.0.0.1:18765/"
        app.launch()
        addUIInterruptionMonitor(withDescription: "Grant system permission") { alert in
            for title in ["Allow While Using App", "Change to Always Allow", "Allow"] {
                if alert.buttons[title].exists { alert.buttons[title].tap(); return true }
            }
            return false
        }
        tap("Next")
        tap("Next")
        tap("Tell Me Before It Rains!")
        app.tap()
        tap("Allow Location Access")
        app.tap()
        tap("Next")
        tap("Done")
        app.tap()
        tap("map.settings")
        let timeframe = app.sliders["Notification Timeframe"]
        XCTAssertTrue(timeframe.waitForExistence(timeout: 10))
        timeframe.adjust(toNormalizedSliderPosition: 1)
        app.sliders["Intensity Threshold"].adjust(toNormalizedSliderPosition: 1)
        app.switches["Show Meteorological Details"].tap()
        screenshot("Notification preferences")

        func state() async throws -> [String: Any] {
            let (data, _) = try await URLSession.shared.data(from: endpoint)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        var latest: [String: Any] = [:]
        for _ in 0..<40 {
            let snapshot = try await state()
            let requests = snapshot["requests"] as? [[String: Any]] ?? []
            latest = requests.last(where: { $0["path"] as? String == "/post_location" })?["body"] as? [String: Any] ?? [:]
            if latest["ahead"] as? Int == 45 && latest["intensity"] as? Int == 41 && latest["withDBZ"] as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertEqual(latest["ahead"] as? Int, 45)
        XCTAssertEqual(latest["intensity"] as? Int, 41)
        XCTAssertEqual(latest["withDBZ"] as? Bool, true)
        XCTAssertEqual(latest["lang"] as? String, "en")
        XCTAssertEqual(latest["source"] as? String, "ios")
        XCTAssertEqual(latest["token"] as? String, String(repeating: "a", count: 64))
        XCTAssertNotNil(latest["lat"] as? Double)

        app.switches["Enable Notifications"].tap()
        var removed = false
        for _ in 0..<40 {
            let snapshot = try await state()
            let requests = snapshot["requests"] as? [[String: Any]] ?? []
            removed = snapshot["registered"] as? Bool == false && requests.contains { $0["path"] as? String == "/unregister" }
            if removed { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertTrue(removed, "Opt-out must reach the server")
        tap("Done")
        XCUIDevice.shared.press(.home)
        app.activate()
        try await Task.sleep(for: .seconds(1))
        let resumed = try await state()
        XCTAssertEqual(resumed["registered"] as? Bool, false, "Foregrounding must not re-register disabled notifications")
    }

}
