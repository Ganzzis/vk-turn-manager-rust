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
            reveal(password, in: app)
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

extension ServerManagerUITests {
    func testCaptureMainScreens() {
        continueAfterFailure = false
        for theme in ["Light", "Dark"] {
            for screen in ["empty", "servers", "dashboard", "clients", "settings", "export", "qr", "diagnostics"] {
                let app = XCUIApplication()
                app.launchArguments = ["--capture-ui", screen, "-AppleInterfaceStyle", theme]
                app.launch()
                switch screen {
                case "empty":
                    XCTAssertTrue(app.buttons["Добавить первый VPS"].waitForExistence(timeout: 8))
                case "servers":
                    XCTAssertTrue(app.descendants(matching: .any)["server-192.0.2.10"].firstMatch.waitForExistence(timeout: 8))
                case "dashboard":
                    XCTAssertTrue(app.staticTexts["Управление службами"].waitForExistence(timeout: 8))
                case "clients":
                    reveal(app.buttons["Экспорт и QR-код"], in: app)
                case "settings":
                    XCTAssertTrue(app.textFields["IP-адрес или DNS-имя"].waitForExistence(timeout: 8))
                case "export":
                    XCTAssertTrue(app.secureTextFields["Приглашение VK Calls"].waitForExistence(timeout: 8))
                case "qr":
                    XCTAssertTrue(app.images["QR-код для импорта VPN-профиля"].waitForExistence(timeout: 8))
                case "diagnostics":
                    let diagnostics = app.buttons["Диагностика SSH"]
                    reveal(diagnostics, in: app)
                    diagnostics.tap()
                    XCTAssertTrue(app.navigationBars["Диагностика SSH"].waitForExistence(timeout: 8))
                default: XCTFail("Unexpected screen")
                }
                attach(screen, theme: theme)
                if screen == "settings" {
                    reveal(app.staticTexts["Отпечаток SSH"], in: app)
                    attach("settings-ssh", theme: theme)
                }
                app.terminate()
            }
        }
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 {
            if element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }

    private func attach(_ screen: String, theme: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(theme.lowercased())-\(screen)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
