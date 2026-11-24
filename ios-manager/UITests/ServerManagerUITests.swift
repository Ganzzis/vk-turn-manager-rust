import XCTest

final class ServerManagerUITests: XCTestCase {
    func testSavesMultipleServers() {
        let app = XCUIApplication()
        app.launch()
        let first = "Fixture " + UUID().uuidString.prefix(6)
        let second = "Fixture " + UUID().uuidString.prefix(6)
        for (name, host) in [(first, "192.0.2.10"), (second, "192.0.2.11")] {
            app.buttons["Добавить VPS"].tap()
            let nameField = app.textFields["Название"]
            XCTAssertTrue(nameField.waitForExistence(timeout: 5))
            nameField.tap()
            nameField.typeText(name)
            let hostField = app.textFields["IP-адрес или DNS-имя"]
            hostField.tap()
            hostField.typeText(host)
            let password = app.secureTextFields["Пароль SSH"]
            password.tap()
            password.typeText("synthetic-password")
            app.buttons["Сохранить"].tap()
            XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5))
        }
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts[first].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[second].exists)
    }
}
