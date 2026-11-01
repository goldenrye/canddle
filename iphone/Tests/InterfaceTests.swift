import XCTest

final class InterfaceTests: XCTestCase {
    @MainActor private func button(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let element = app.buttons[id]
        for _ in 0..<3 {
            if element.exists && element.isHittable { return element }
            app.swipeUp()
        }
        for _ in 0..<5 {
            if element.exists && element.isHittable { return element }
            app.swipeDown()
        }
        return element
    }

    @MainActor private func settings(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["settings"].waitForExistence(timeout: 10))
        app.buttons["settings"].tap()
        XCTAssertTrue(app.buttons["pairQR"].waitForExistence(timeout: 5))
    }

    @MainActor private func forget(_ app: XCUIApplication) {
        button(app, "Reset saved settings").tap()
        button(app, "forgetRelay").tap()
    }

    @MainActor func testCompactHomeAndAdvancedSettings() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["settings"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["settings"].isHittable)
        XCTAssertFalse(app.textFields["address"].exists)
        XCTAssertFalse(app.buttons["start"].exists)
        XCTAssertFalse(app.buttons["newInvitation"].exists)
        XCTAssertFalse(app.buttons["importCA"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.lifetime = .keepAlways
        add(attachment)
        settings(app)
        XCTAssertFalse(app.buttons["importCA"].exists)
        button(app, "Certificate trust").tap()
        XCTAssertTrue(button(app, "importCA").exists)
    }

    @MainActor func testInsecureAddressShowsActionableAlert() {
        let app = XCUIApplication()
        app.launch()
        settings(app)
        forget(app)
        button(app, "Enter connection manually").tap()
        app.textFields["address"].tap()
        app.textFields["address"].typeText("ws://example.com/relay")
        app.secureTextFields["token"].tap()
        app.secureTextFields["token"].typeText(String(repeating: "a", count: 40))
        app.buttons["Done"].tap()
        app.navigationBars["Settings"].buttons["Calls"].tap()
        button(app, "lobbyAnnounce").tap()
        XCTAssertTrue(app.alerts["Call could not continue"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Use wss://")).firstMatch.exists)
        XCTAssertFalse(app.buttons["hangUp"].exists)
        app.alerts.buttons["OK"].tap()
        settings(app)
        forget(app)
    }

    @MainActor func testSavedRelaySurvivesRelaunchAndCanBeForgotten() {
        let app = XCUIApplication()
        app.launch()
        settings(app)
        forget(app)
        button(app, "Enter connection manually").tap()
        app.textFields["address"].tap()
        app.textFields["address"].typeText("wss://example.com:8443/relay")
        app.secureTextFields["token"].tap()
        app.secureTextFields["token"].typeText(String(repeating: "b", count: 40))
        app.buttons["Done"].tap()
        app.navigationBars["Settings"].buttons["Calls"].tap()
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(button(app, "lobbyAnnounce").isEnabled)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["lobbyAnnounce"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["lobbyAnnounce"].isHittable)
        XCTAssertTrue(app.buttons["lobbyConnect"].isHittable)
        XCTAssertFalse(app.textFields["address"].exists)
        settings(app)
        button(app, "Enter connection manually").tap()
        XCTAssertEqual(app.textFields["address"].value as? String, "wss://example.com:8443/relay")
        // Restored address and token expose group actions without invitations.
        // This test never connects to a server or opens the microphone.
        forget(app)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["setupConnection"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["setupConnection"].isHittable)
        XCTAssertFalse(app.buttons["lobbyAnnounce"].exists)
        settings(app)
        button(app, "Enter connection manually").tap()
        XCTAssertEqual(app.textFields["address"].value as? String, "wss://voice.example.com/relay")
        XCTAssertEqual(app.secureTextFields["token"].value as? String, "Relay access token")
    }
}
