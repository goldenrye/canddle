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
        if app.buttons["Go offline"].exists { app.buttons["Go offline"].tap() }
    }

    @MainActor private func automaticConnection(_ app: XCUIApplication) {
        let attempted = NSPredicate(format:
            "label CONTAINS %@ OR label CONTAINS %@", "Connecting to relay group",
            "Group connection or authentication failed")
        let expectation = XCTNSPredicateExpectation(predicate: attempted,
                                                     object: app.staticTexts["lobbyStatus"])
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
        XCTAssertFalse(app.buttons["lobbyConnect"].exists)
        XCTAssertFalse(app.buttons["hangUp"].exists)
        XCTAssertFalse(app.alerts["Call could not continue"].exists)
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

    @MainActor func testDeviceNameCanBeChangedAndSurvivesRelaunch() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["settings"].waitForExistence(timeout: 10))
        app.buttons["settings"].tap()
        let field = app.textFields["lobbyName"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(field.isEnabled)
        let previous = field.value as? String ?? "My iPhone"
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count))
        field.typeText("Office iPhone")
        app.buttons["Done"].tap()
        button(app, "saveDeviceName").tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["settings"].waitForExistence(timeout: 10))
        app.buttons["settings"].tap()
        XCTAssertTrue(app.textFields["lobbyName"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["lobbyName"].value as? String, "Office iPhone")
        app.textFields["lobbyName"].tap()
        app.textFields["lobbyName"].typeText(
            String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Office iPhone".count) + previous
        )
        app.buttons["Done"].tap()
        button(app, "saveDeviceName").tap()
    }

    @MainActor func testAutomaticConnectionRejectsInsecureAddressWithoutAlert() {
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
        let validation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "Use wss://"),
            object: app.staticTexts["lobbyStatus"])
        XCTAssertEqual(XCTWaiter.wait(for: [validation], timeout: 10), .completed)
        XCTAssertFalse(app.alerts["Call could not continue"].exists)
        XCTAssertFalse(app.buttons["lobbyConnect"].exists)
        XCTAssertFalse(app.buttons["hangUp"].exists)
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
        app.textFields["address"].typeText("wss://127.0.0.1:1/relay")
        app.secureTextFields["token"].tap()
        app.secureTextFields["token"].typeText(String(repeating: "b", count: 40))
        app.buttons["Done"].tap()
        // Editing stays offline even after an automatic retry interval.
        let unexpectedConnection = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true"), object: app.buttons["Go offline"])
        unexpectedConnection.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [unexpectedConnection], timeout: 6), .completed)
        app.navigationBars["Settings"].buttons["Calls"].tap()
        automaticConnection(app)
        XCUIDevice.shared.press(.home)
        app.activate()
        automaticConnection(app)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["lobbyAnnounce"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["lobbyAnnounce"].isHittable)
        automaticConnection(app)
        XCTAssertFalse(app.textFields["address"].exists)
        settings(app)
        button(app, "Enter connection manually").tap()
        XCTAssertEqual(app.textFields["address"].value as? String, "wss://127.0.0.1:1/relay")
        // The closed loopback port exercises automatic attempts without a real
        // server, external credential transmission, or microphone access.
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
