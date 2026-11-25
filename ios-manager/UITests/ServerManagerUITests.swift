import XCTest

final class ServerManagerUITests: XCTestCase {
    func testSavesMultipleServers() {
        let app = XCUIApplication()
        app.launch()
        continueAfterFailure = false
        func row(_ host: String) -> XCUIElement {
            app.descendants(matching: .any)["server-" + host].firstMatch
        }
        let first = "Fixture " + UUID().uuidString.prefix(6)
        let second = "Fixture " + UUID().uuidString.prefix(6)
        for (name, host) in [(first, "192.0.2.10"), (second, "192.0.2.11")] {
            app.buttons["Добавить VPS"].tap()
            let nameField = app.textFields["Название"]
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: nameField)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 12), .completed)
            nameField.tap()
            nameField.typeText(name)
            let hostField = app.textFields["IP-адрес или DNS-имя"]
            hostField.tap()
            hostField.typeText(host)
            let password = app.secureTextFields["Пароль SSH"]
            if !password.isHittable { app.swipeUp() }
            password.tap()
            password.typeText("synthetic-password")
            app.buttons["Сохранить"].tap()
            let error = app.staticTexts["save-error"]
            XCTAssertTrue(row(host).waitForExistence(timeout: 8),
                          error.exists ? error.label : "The server row did not appear after saving.")
            app.terminate()
            app.launch()
            XCTAssertTrue(row(host).waitForExistence(timeout: 8))
        }
        XCTAssertTrue(row("192.0.2.10").waitForExistence(timeout: 8))
        XCTAssertTrue(row("192.0.2.11").exists)
    }
}
