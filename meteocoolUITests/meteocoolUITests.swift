import XCTest
import UIKit

final class meteocoolUITests: XCTestCase {
    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments = ["--ui-test-reset", "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-environment", "staging"]
        app.launch()
    }

    private func tap(_ title: String) {
        let button = app.buttons[title]
        XCTAssertTrue(button.waitForExistence(timeout: 15), "Missing button: \(title)")
        button.tap()
    }

    private func completeOnboardingWithoutPermissions() {
        tap("Continue")
        tap("Not Now") // location is optional
        tap("Not Now") // notifications are optional
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
        completeOnboardingWithoutPermissions()
        XCTAssertTrue(app.webViews.staticTexts["mapBaseLayer=system;radarColorMapping=classic"].waitForExistence(timeout: 15))
        tap("map.settings")
        for (title, choice) in [("Base Map Layer", "OpenStreetMap"), ("Radar Color Map", "Homeyer (Color Vision Deficiency)")] {
            app.staticTexts[title].tap()
            if title == "Base Map Layer" { setMatchSystem(false) }
            app.tables["settings.options"].staticTexts[choice].tap()
            tap("picker.save")
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

    // Detects the checkmark from rendered pixels, not from the cell's selected trait.
    // UIKit can change accessory visibility after the data source configures the cell.
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

    /// Match System is a switch above the basemaps; they can be picked only
    /// while it is off.
    private func setMatchSystem(_ on: Bool) {
        let toggle = app.switches["Match System"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        if (toggle.value as? String == "1") != on { toggle.tap() }
        XCTAssertEqual(toggle.value as? String, on ? "1" : "0")
    }

    /// While Match System is on, the basemaps are greyed out and a tap on one
    /// changes nothing; turning it off brings back the last one picked.
    func testMatchSystemDisablesBasemaps() {
        completeOnboardingWithoutPermissions()
        tap("map.settings")
        app.staticTexts["Base Map Layer"].tap()
        setMatchSystem(true)
        let table = app.tables["settings.options"]
        let dark = table.cells.containing(.staticText, identifier: "Dark").firstMatch
        XCTAssertFalse(dark.isEnabled, "Basemaps are disabled while Match System is on")
        dark.tap()
        XCTAssertFalse(dark.isSelected)
        XCTAssertEqual(app.switches["Match System"].value as? String, "1")
        setMatchSystem(false)
        XCTAssertTrue(dark.isEnabled)
        dark.tap()
        XCTAssertTrue(dark.isSelected)
        tap("picker.save")
        XCTAssertTrue(app.staticTexts["Dark"].waitForExistence(timeout: 5))
        app.staticTexts["Base Map Layer"].tap()
        setMatchSystem(true)
        tap("picker.save")
        XCTAssertTrue(app.staticTexts["Match System"].waitForExistence(timeout: 5))
    }

    private func verifyPickerSelectionGeometry() {
        completeOnboardingWithoutPermissions()
        tap("map.settings")
        for (title, options) in [
            ("Base Map Layer", ["Light", "Dark", "OpenStreetMap", "CyclOSM (Biking)"]),
            ("Radar Color Map", ["Classic", "NWS Reflectivity", "PyArt StepSeq", "Homeyer (Color Vision Deficiency)", "Lang"])
        ] {
            app.staticTexts[title].tap()
            XCTAssertTrue(app.staticTexts[options[0]].waitForExistence(timeout: 5))
            if title == "Base Map Layer" { setMatchSystem(false) }
            let table = app.tables["settings.options"]
            var previousIndex = 0
            for index in Array(0..<options.count) + Array((0..<options.count).reversed()) {
                let label = table.staticTexts[options[index]]
                for _ in 0..<8 {
                    if label.isHittable { break }
                    if index < previousIndex { table.swipeDown() } else { table.swipeUp() }
                }
                XCTAssertTrue(label.isHittable)
                // Measures only the rows visible right before each selection.
                // Tables create offscreen rows on demand, so offscreen frames are estimates.
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
                    if cell.frame.minY >= app.buttons["picker.save"].frame.maxY &&
                        cell.frame.maxY <= min(table.frame.maxY, app.frame.maxY) {
                        XCTAssertEqual(try? hasVisibleCheckmark(cell), option == options[index],
                                       "\(title): \(option) rendered the wrong checkmark state")
                        XCTAssertEqual(cell.isSelected, option == options[index])
                    }
                }
                previousIndex = index
            }
            screenshot("\(title) after selecting every option")
            tap("picker.save")
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
        completeOnboardingWithoutPermissions()
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
        completeOnboardingWithoutPermissions()
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

    /// The open-source licences sit below the data sources, and each opens
    /// its full text: the notices MIT and BSD ask to reproduce.
    func testLicencesShowTheirText() {
        completeOnboardingWithoutPermissions()
        tap("map.settings")
        let table = app.tables.firstMatch
        let row = table.staticTexts["SwiftFSM"]
        for _ in 0..<15 where !row.isHittable { table.swipeUp() }
        XCTAssertTrue(row.isHittable, "SwiftFSM is listed under Open-Source Software")
        XCTAssertTrue(table.staticTexts["Web Map Libraries"].exists)
        row.tap()
        let text = app.textViews["licence.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        XCTAssertTrue((text.value as? String ?? "").contains("Copyright (c) 2016 Vishal V. Shekkar"))
    }

    private func openNotificationSliderSettings() {
        app.terminate()
        app.launchArguments += ["-pushNotification", "YES"]
        app.launchEnvironment["MC_TEST_API_URL"] = "http://127.0.0.1:18765/"
        app.launchEnvironment["MC_TEST_MAP"] = "1"
        app.launch()
        completeOnboardingWithoutPermissions()
        tap("map.settings")
    }

    func testNotificationSliderTrackTaps() {
        openNotificationSliderSettings()
        for (title, values) in [("Intensity Threshold", ["Drizzle", "Rain", "Hail"]),
                                ("Notification Timeframe", ["5 min", "25 min", "45 min"])] {
            let slider = app.sliders[title]
            XCTAssertTrue(slider.waitForExistence(timeout: 5))
            let cell = app.tables.cells.containing(.slider, identifier: title).firstMatch
            // Alternate ends so every tap starts away from the thumb.
            for (position, expected) in [(0.95, values[2]), (0.05, values[0]), (0.5, values[1])] {
                slider.coordinate(withNormalizedOffset: CGVector(dx: position, dy: 0.5)).tap()
                XCTAssertEqual(slider.value as? String, expected)
                XCTAssertTrue(cell.staticTexts[expected].exists)
            }
        }
        app.terminate()
        app.launchArguments.removeAll { $0 == "--ui-test-reset" }
        app.launch()
        tap("map.settings")
        XCTAssertEqual(app.sliders["Intensity Threshold"].value as? String, "Rain")
        XCTAssertEqual(app.sliders["Notification Timeframe"].value as? String, "25 min")
        screenshot("Notification slider track taps persisted")
    }

    @MainActor
    func testNotificationSliderLabelsUpdateDuringDrag() async throws {
        let server = URL(string: "http://127.0.0.1:18765/")!
        do { _ = try await URLSession.shared.data(from: server.appendingPathComponent("requests")) }
        catch { throw XCTSkip("Start node tests/mobile-api-recorder.mjs for screenshots during a held drag") }
        func simulatorScreenshot() async throws -> UIImage {
            let (data, _) = try await URLSession.shared.data(from: server.appendingPathComponent("slider-screenshot"))
            return try XCTUnwrap(UIImage(data: data))
        }
        openNotificationSliderSettings()
        for (title, initial, final) in [("Intensity Threshold", "Light rain", "Hail"),
                                        ("Notification Timeframe", "15 min", "45 min")] {
            let slider = app.sliders[title]
            XCTAssertTrue(slider.waitForExistence(timeout: 5))
            let cell = app.tables.cells.containing(.slider, identifier: title).firstMatch
            let frame = cell.staticTexts[initial].frame
            let screenWidth = app.frame.width
            func labelPixels(_ screenshot: UIImage) throws -> [UInt8] {
                let image = try XCTUnwrap(screenshot.cgImage)
                let scale = CGFloat(image.width) / screenWidth
                let rect = CGRect(x: frame.minX * scale, y: frame.minY * scale,
                                  width: frame.width * scale, height: frame.height * scale).integral
                let crop = try XCTUnwrap(image.cropping(to: rect))
                var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
                try pixels.withUnsafeMutableBytes { buffer in
                    let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: crop.width, height: crop.height,
                        bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
                }
                // Compare text silhouettes, independent of PNG encoding and color profiles.
                return stride(from: 0, to: pixels.count, by: 4).map { pixels[$0] < 180 ? 1 : 0 }
            }
            func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
                Double(zip(a, b).filter { $0 != $1 }.count) / Double(a.count)
            }
            // Use the same capture path for all three images to avoid
            // XCTest/simctl rendering and color-profile differences.
            let before = try labelPixels(await simulatorScreenshot())
            // Capture while the synthesized finger is held down at the destination.
            let capture = Task.detached {
                let (data, _) = try await URLSession.shared.data(from: server.appendingPathComponent("slider-drag-screenshot"))
                return (data, Date())
            }
            let start = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
            let end = slider.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            start.press(forDuration: 0.5, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 5)
            let released = Date()
            let (data, capturedAt) = try await capture.value
            let during = try XCTUnwrap(UIImage(data: data))
            let attachment = XCTAttachment(image: during)
            attachment.name = "\(title) before finger release"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertLessThan(capturedAt, released.addingTimeInterval(-1), "Capture must finish before finger release")
            let duringPixels = try labelPixels(during)
            let after = try labelPixels(await simulatorScreenshot())
            XCTAssertGreaterThan(difference(duringPixels, before), 0.02, "\(title) label did not update during the drag")
            XCTAssertLessThan(difference(duringPixels, after), 0.01, "\(title) label waited for release")
            XCTAssertEqual(slider.value as? String, final)
        }
    }

    func testNotificationSliderLayout() {
        openNotificationSliderSettings()
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
        if app.staticTexts["Welcome to meteocool"].waitForExistence(timeout: 5) {
            screenshot("Onboarding")
            completeOnboardingWithoutPermissions()
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
        setMatchSystem(false)
        app.staticTexts["Dark"].tap()
        tap("picker.save")
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
        tap("picker.save")
        XCTAssertTrue(app.staticTexts["NWS Reflectivity"].waitForExistence(timeout: 5))
        app.staticTexts["Radar Color Map"].tap()
        app.staticTexts["Lang"].tap()
        tap("Cancel")
        XCTAssertTrue(app.staticTexts["NWS Reflectivity"].waitForExistence(timeout: 5))
        let rotation = app.switches["Two-Finger Map Rotation"]
        rotation.tap()
        XCTAssertEqual(rotation.value as? String, "1")
        let mode = app.staticTexts["Mode"]
        for _ in 0..<4 {
            if mode.isHittable { break }
            app.tables.firstMatch.swipeUp()
        }
        XCTAssertTrue(mode.isHittable, "Mode must be reachable in Settings")
        let selected = app.launchArguments.contains("staging") ? "Experimental Features" : "Production"
        XCTAssertTrue(app.staticTexts[selected].exists, "Mode must name the selected deployment")
        screenshot("Settings lower rows")
        tap("Done")
        screenshot("Dark basemap")
        app.terminate()
        app.launchArguments.removeAll { $0 == "--ui-test-reset" }
        app.launch()
        XCTAssertTrue(app.buttons["map.settings"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Welcome to meteocool"].exists, "Completed onboarding must not return")
    }

    func testDarkLargeTextAndRotation() {
        app.terminate()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        screenshot("Large text onboarding")
        completeOnboardingWithoutPermissions()
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
        app.launchArguments.removeAll { $0 == "-environment" || $0 == "staging" }
        app.launch()
        testOnboardingWithoutPermissionsAndSettings()
    }

    @MainActor
    func testMapRecoversWithoutUserAction() async throws {
        let server = URL(string: "http://127.0.0.1:18765/")!
        do { _ = try await URLSession.shared.data(from: server.appendingPathComponent("map/fail")) }
        catch { throw XCTSkip("Start node tests/mobile-api-recorder.mjs") }
        app.terminate()
        app.launchEnvironment = ["MC_TEST_API_URL": server.absoluteString, "MC_TEST_MAP": "1"]
        app.launch()
        completeOnboardingWithoutPermissions()
        let status = app.staticTexts["map.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 15), "A map that keeps failing says it is trying again")
        XCTAssertFalse(app.buttons["map.retry"].exists, "Nothing asks the user to retry")
        XCTAssertFalse(app.buttons["map.layers"].isEnabled)
        tap("map.settings")
        XCTAssertTrue(app.switches["Enable Notifications"].exists)
        tap("Done")
        screenshot("Map failed with native controls")
        _ = try await URLSession.shared.data(from: server.appendingPathComponent("map/recover"))
        // The backoff tops out at 15 seconds between attempts.
        XCTAssertTrue(app.webViews.staticTexts["Map connection restored"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["map.layers"].isEnabled)
        XCTAssertFalse(status.exists)
    }

    @MainActor
    func testLogoAndModeSwitchWithoutRestart() async throws {
        let server = URL(string: "http://127.0.0.1:18765/")!
        func mapLoads() async throws -> Int {
            let (data, _) = try await URLSession.shared.data(from: server.appendingPathComponent("requests"))
            let state = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            return try XCTUnwrap(state["mapLoads"] as? Int)
        }
        do { _ = try await URLSession.shared.data(from: server.appendingPathComponent("map/recover")) }
        catch { throw XCTSkip("Start node tests/mobile-api-recorder.mjs") }
        app.terminate()
        app.launchArguments.removeAll { $0 == "-environment" || $0 == "staging" }
        app.launchEnvironment = ["MC_TEST_API_URL": server.absoluteString, "MC_TEST_MAP": "1"]
        app.launch()
        completeOnboardingWithoutPermissions()
        XCTAssertTrue(app.webViews.staticTexts["map=satellite"].waitForExistence(timeout: 15))
        tap("map.logo")
        XCTAssertTrue(app.webViews.staticTexts["map=radar"].waitForExistence(timeout: 5), "The logo returns to the radar")

        let loads = try await mapLoads()
        tap("map.settings")
        let mode = app.staticTexts["Mode"]
        for _ in 0..<4 {
            if mode.isHittable { break }
            app.tables.firstMatch.swipeUp()
        }
        XCTAssertTrue(app.staticTexts["Production"].exists)
        mode.tap()
        let options = app.tables["settings.options"]
        XCTAssertTrue(options.staticTexts["Experimental Features"].waitForExistence(timeout: 5))
        screenshot("Mode picker")
        options.staticTexts["Demo"].tap()
        tap("Cancel")
        XCTAssertTrue(app.staticTexts["Production"].waitForExistence(timeout: 5), "Cancel keeps the mode")
        mode.tap()
        options.staticTexts["Demo"].tap()
        tap("picker.save")
        XCTAssertTrue(app.staticTexts["Demo"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts.firstMatch.exists, "Switching needs no restart notice")
        tap("Done")
        XCTAssertTrue(app.webViews.staticTexts["Map connection restored"].waitForExistence(timeout: 15))
        let reloaded = try await mapLoads()
        XCTAssertGreaterThan(reloaded, loads, "Switching the mode reloads the map")

        app.terminate()
        app.launchArguments.removeAll { $0 == "--ui-test-reset" }
        app.launch()
        let disable = app.alerts.buttons["Disable Demo Mode"]
        XCTAssertTrue(disable.waitForExistence(timeout: 10), "Demo mode still warns at launch")
        disable.tap()
        tap("map.settings")
        for _ in 0..<4 {
            if mode.isHittable { break }
            app.tables.firstMatch.swipeUp()
        }
        XCTAssertTrue(app.staticTexts["Production"].exists, "Disabling demo mode returns to production")
    }

    func testDeniedPermissionsRemainUsable() {
        XCTAssertTrue(app.staticTexts["Welcome to meteocool"].waitForExistence(timeout: 10), "Run this test on a fresh installation")
        addUIInterruptionMonitor(withDescription: "Deny system permission") { alert in
            let deny = alert.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Don'")).firstMatch
            guard deny.exists else { return false }
            deny.tap()
            return true
        }
        tap("Continue")
        tap("Allow Location Access")
        app.tap()
        tap("Tell Me Before It Rains!")
        app.tap()
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
        completeOnboardingWithoutPermissions()
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
        tap("Continue")
        tap("Allow Location Access")
        app.tap()
        tap("Tell Me Before It Rains!")
        app.tap()
        app.tap()
        tap("map.settings")
        let timeframe = app.sliders["Notification Timeframe"]
        XCTAssertTrue(timeframe.waitForExistence(timeout: 10))
        _ = try await URLSession.shared.data(for: reset)
        let duringDrag = Task.detached {
            try await Task.sleep(for: .seconds(3))
            return try await URLSession.shared.data(from: endpoint).0
        }
        timeframe.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
            .press(forDuration: 0.5, thenDragTo: timeframe.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)),
                   withVelocity: .slow, thenHoldForDuration: 5)
        let heldData = try await duringDrag.value
        let heldState = try XCTUnwrap(JSONSerialization.jsonObject(with: heldData) as? [String: Any])
        let heldRequests = heldState["requests"] as? [[String: Any]] ?? []
        XCTAssertFalse(heldRequests.contains { ($0["body"] as? [String: Any])?["ahead"] as? Int == 45 },
                       "Dragging must not submit a setting before finger release")
        var timeframePosts: [[String: Any]] = []
        for _ in 0..<20 {
            let (data, _) = try await URLSession.shared.data(from: endpoint)
            let state = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            timeframePosts = (state["requests"] as? [[String: Any]] ?? []).filter {
                $0["path"] as? String == "/post_location" && ($0["body"] as? [String: Any])?["ahead"] as? Int == 45
            }
            if !timeframePosts.isEmpty { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertEqual(timeframePosts.count, 1, "Finger release must submit the selected timeframe once")
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

    /// The Live Activity switch reaches the backend: turning it off withdraws
    /// the push-to-start token (`enabled: false`), turning it back on offers it
    /// again. Run `node tests/mobile-api-recorder.mjs` first.
    @MainActor
    func testLiveActivitySettingReachesAPI() async throws {
        let endpoint = URL(string: "http://127.0.0.1:18765/requests")!
        var reset = URLRequest(url: endpoint)
        reset.httpMethod = "DELETE"
        do { _ = try await URLSession.shared.data(for: reset) }
        catch { throw XCTSkip("Start node tests/mobile-api-recorder.mjs") }
        func lastLiveActivity() async throws -> [String: Any]? {
            let (data, _) = try await URLSession.shared.data(from: endpoint)
            let state = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            return (state["requests"] as? [[String: Any]] ?? [])
                .last { $0["path"] as? String == "/v3/mobile/live_activity" }?["body"] as? [String: Any]
        }
        func waitForLiveActivity(enabled: Bool) async throws -> [String: Any]? {
            for _ in 0..<40 {
                if let body = try await lastLiveActivity(), body["enabled"] as? Bool == enabled { return body }
                try await Task.sleep(for: .milliseconds(250))
            }
            return nil
        }
        openNotificationSliderSettings()
        let toggle = app.switches["Live Activity During Rain"]
        scrollIntoView(toggle)
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "1", "Live Activities are on by default")
        toggle.tap()
        let off = try await waitForLiveActivity(enabled: false)
        XCTAssertNotNil(off, "Turning the Live Activity off must reach the server")
        XCTAssertEqual(off?["token"] as? String, String(repeating: "a", count: 64))
        XCTAssertTrue(off?["startToken"] is NSNull, "A disabled device must not offer a push-to-start token")
        toggle.tap()
        let on = try await waitForLiveActivity(enabled: true)
        XCTAssertNotNil(on, "Turning the Live Activity back on must reach the server")
    }

    /// The AR storm view's preview, against the recorder's synthetic storm,
    /// boxed as two map tiles: the storm is found and tagged once, every mode
    /// can be chosen, and Open on Map hands the storm's link to the map. Run
    /// `node tests/mobile-api-recorder.mjs` first.
    @MainActor
    func testARPreviewFindsStormAndOpensItOnTheMap() async throws {
        let server = URL(string: "http://127.0.0.1:18765/")!
        do { _ = try await URLSession.shared.data(from: server.appendingPathComponent("map/recover")) }
        catch { throw XCTSkip("Start node tests/mobile-api-recorder.mjs") }
        app.terminate()
        app.launchEnvironment = ["MC_TEST_API_URL": server.absoluteString, "MC_TEST_MAP": "1"]
        app.launch()
        completeOnboardingWithoutPermissions()
        XCTAssertTrue(app.webViews.staticTexts["Map connection restored"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["map.ar"].exists, "AR stays hidden until the logo is tapped five times")
        app.buttons["map.logo"].tap(withNumberOfTaps: 5, numberOfTouches: 1)
        tap("map.ar")
        // Closing works, and leaves the map as it was.
        tap("ar.close")
        XCTAssertTrue(app.buttons["map.settings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["ar.close"].exists)
        tap("map.ar")

        // The recorder boxes the storm as two map tiles, as the data service does: one tag,
        // named by the tile holding the peak, none for the other tile.
        let tags = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'ar.storm.'"))
        let storm = tags.firstMatch
        XCTAssertTrue(storm.waitForExistence(timeout: 20), "The storm's tag never appeared")
        XCTAssertTrue(storm.identifier.hasPrefix("ar.storm.T10"), storm.identifier)
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(tags.count, 1, "One storm, one tag, however many tiles")
        XCTAssertTrue(storm.label.contains("Holzkirchen"), storm.label)
        XCTAssertTrue(storm.label.contains("52 dBZ"), storm.label)
        let status = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Storms nearby: 1'")).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        screenshot("AR preview live")

        for mode in ["peel", "slice", "turn", "track", "floor", "shells", "shaft", "tops", "live"] {
            let button = app.buttons["ar.mode.\(mode)"]
            XCTAssertTrue(button.waitForExistence(timeout: 5), mode)
            scrollIntoView(button)
            XCTAssertTrue(button.isEnabled, "\(mode) is disabled")
            button.tap()
            let needsSlider = ["peel", "slice", "turn", "track", "floor"].contains(mode)
            XCTAssertEqual(app.sliders["ar.slider"].waitForExistence(timeout: needsSlider ? 3 : 0.5), needsSlider, mode)
            screenshot("AR preview \(mode)")
        }

        // The AR view turns to landscape; the map it returns to does not.
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitUntil { self.app.windows.firstMatch.frame.width > self.app.windows.firstMatch.frame.height },
                      "The AR view did not turn to landscape")
        screenshot("AR preview landscape")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(waitUntil { self.app.windows.firstMatch.frame.width < self.app.windows.firstMatch.frame.height })

        storm.tap()
        let open = app.buttons["ar.openOnMap"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        screenshot("AR preview selected")
        open.tap()
        // The tracked cell wins over its box, as core's deep links settle it.
        let link = app.webViews.staticTexts["link=?layer=cells3d&cell=2026100402050000012345"]
        XCTAssertTrue(link.waitForExistence(timeout: 10), "The map never received the storm's link")
        XCTAssertFalse(app.buttons["ar.close"].exists)
    }

    /// The page's share buttons reach the system share sheet, with a link
    /// back to the map's own host and nothing else.
    @MainActor
    func testPageShareOpensShareSheet() async throws {
        let server = URL(string: "http://127.0.0.1:18765/")!
        do { _ = try await URLSession.shared.data(from: server.appendingPathComponent("map/recover")) }
        catch { throw XCTSkip("Start node tests/mobile-api-recorder.mjs") }
        app.terminate()
        app.launchEnvironment = ["MC_TEST_API_URL": server.absoluteString, "MC_TEST_MAP": "1"]
        app.launch()
        completeOnboardingWithoutPermissions()
        XCTAssertTrue(app.webViews.staticTexts["share=true"].waitForExistence(timeout: 15),
                      "The page learns before it loads that the app can share")

        // The system's share sheet, as XCTest sees it on iOS 27.
        let sheet = app.otherElements["ActivityListView"]
        app.webViews.buttons["Share elsewhere"].tap()
        XCTAssertFalse(sheet.waitForExistence(timeout: 3), "A link to another host is not shared")

        app.webViews.buttons["Share view"].tap()
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "The share sheet never appeared")
        XCTAssertTrue(sheet.cells["Copy"].waitForExistence(timeout: 5), "The link can be copied")
        let header = sheet.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Fixture view · meteocool"))
        XCTAssertTrue(header.firstMatch.waitForExistence(timeout: 5), "The sheet's header names what is shared")
        screenshot("Share sheet")
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }

    /// Drags the mode picker until a button in it is wholly on screen.
    /// By frame: `isHittable` throws for a button scrolled right out of view.
    private func scrollIntoView(_ element: XCUIElement) {
        let picker = app.scrollViews.containing(.button, identifier: "ar.mode.live").firstMatch
        let screen = app.windows.firstMatch.frame
        for _ in 0 ..< 10 {
            let frame = element.frame
            if frame.minX >= screen.minX + 4 && frame.maxX <= screen.maxX - 4 { return }
            let start = picker.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let end = start.withOffset(CGVector(dx: frame.midX > screen.midX ? -150 : 150, dy: 0))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
    }
}
