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

    @MainActor func testInvitationAndInsecureAddress() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.textFields["address"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["pairQR"].exists)
        app.buttons["forgetRelay"].tap()
        XCTAssertFalse(button(app, "start").isEnabled)
        button(app, "newInvitation").tap()
        _ = button(app, "start")
        XCTAssertTrue(app.staticTexts["status"].label.contains("Invitation ready"))
        button(app, "forgetRelay").swipeDown()
        app.textFields["address"].tap()
        app.textFields["address"].typeText("ws://example.com/relay")
        app.secureTextFields["token"].tap()
        app.secureTextFields["token"].typeText(String(repeating: "a", count: 40))
        app.buttons["Done"].tap()
        button(app, "start").tap()
        XCTAssertTrue(app.staticTexts["status"].label.contains("Use wss://"))
        XCTAssertFalse(app.buttons["hangUp"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.lifetime = .keepAlways
        add(attachment)
        button(app, "forgetRelay").tap()
    }

    @MainActor func testSavedRelaySurvivesRelaunchAndCanBeForgotten() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["forgetRelay"].waitForExistence(timeout: 10))
        app.buttons["forgetRelay"].tap()
        app.textFields["address"].tap()
        app.textFields["address"].typeText("wss://example.com:8443/relay")
        app.secureTextFields["token"].tap()
        app.secureTextFields["token"].typeText(String(repeating: "b", count: 40))
        app.buttons["Done"].tap()
        app.buttons["newInvitation"].tap()
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(button(app, "start").isEnabled)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.textFields["address"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["address"].value as? String, "wss://example.com:8443/relay")
        // Invitations must not persist, while a restored token enables starting
        // once a fresh invitation is generated. No microphone or network is used.
        XCTAssertFalse(button(app, "start").isEnabled)
        button(app, "newInvitation").tap()
        XCTAssertTrue(button(app, "start").isEnabled)
        button(app, "forgetRelay").tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(app.textFields["address"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["address"].value as? String, "wss://voice.example.com/relay")
        XCTAssertEqual(app.secureTextFields["token"].value as? String, "Relay access token")
        app.buttons["newInvitation"].tap()
        XCTAssertFalse(button(app, "start").isEnabled)
    }
}
