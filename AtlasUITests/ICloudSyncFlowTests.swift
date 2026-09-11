import XCTest

nonisolated final class ICloudSyncFlowTests: XCTestCase {
    @MainActor
    func testConsentExplainsEncryptionBeforeEnablingSync() throws {
        let app = XCUIApplication()
        app.launch()
        let library = app.tabBars.buttons["Library"]
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        library.tap()
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        let sync = app.buttons["iCloud Sync"].firstMatch
        for _ in 0..<4 where !sync.isHittable { app.swipeUp() }
        XCTAssertTrue(sync.waitForExistence(timeout: 5))
        sync.tap()
        let enable = app.buttons["Enable iCloud Sync"]
        XCTAssertTrue(enable.waitForExistence(timeout: 5))
        let status = app.descendants(matching: .any)["icloud.sync.status"].firstMatch
        XCTAssertEqual(status.value as? String, "Off")
        let settingsScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        settingsScreenshot.name = "iCloud sync settings, sync off"
        settingsScreenshot.lifetime = .keepAlways
        add(settingsScreenshot)
        enable.tap()
        XCTAssertTrue(app.navigationBars["Enable iCloud Sync"].waitForExistence(timeout: 5))
        let notice = app.staticTexts.containing(
            NSPredicate(
                format: "label CONTAINS %@", "End-to-end encryption requires Advanced Data Protection"
            )
        ).firstMatch
        XCTAssertTrue(notice.exists)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "iCloud sync opt-in and encryption warning"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        // The test never consents to an upload or uses a real iCloud account.
        app.buttons["Cancel"].tap()
        XCTAssertTrue(enable.waitForExistence(timeout: 5))
        XCTAssertEqual(status.value as? String, "Off")
    }
}
