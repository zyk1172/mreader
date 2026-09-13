import XCTest

final class mreaderUITests: XCTestCase {
    private let timeout: TimeInterval = 12

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-mreader-ui-testing"]
        app.launch()
        return app
    }

    @MainActor
    func testColdStartShowsStableShelfSurface() throws {
        let app = launchApp()
        XCTAssertTrue(element("mreader.shelf.root", in: app).waitForExistence(timeout: timeout))
        XCTAssertTrue(element("mreader.shelf.menu", in: app).waitForExistence(timeout: timeout))
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: timeout))
        XCTAssertGreaterThanOrEqual(app.tabBars.buttons.count, 3)
    }

    @MainActor
    func testSettingsAndNoServerRemoteSourceEntry() throws {
        let app = launchApp()
        let menu = element("mreader.shelf.menu", in: app)
        XCTAssertTrue(menu.waitForExistence(timeout: timeout))
        menu.tap()

        let settings = element("mreader.shelf.settings", in: app)
        XCTAssertTrue(settings.waitForExistence(timeout: timeout))
        settings.tap()
        XCTAssertTrue(element("mreader.settings.root", in: app).waitForExistence(timeout: timeout))

        let remoteSources = element("mreader.settings.remoteSources", in: app)
        XCTAssertTrue(remoteSources.waitForExistence(timeout: timeout))
        remoteSources.tap()
        XCTAssertTrue(element("mreader.remote.settings", in: app).waitForExistence(timeout: timeout))
        XCTAssertTrue(element("mreader.remote.noServers", in: app).waitForExistence(timeout: timeout))
        XCTAssertTrue(element("mreader.remote.baseURL", in: app).exists)
    }

    @MainActor
    func testOCRSearchEntryAndDismiss() throws {
        let app = launchApp()
        let menu = element("mreader.shelf.menu", in: app)
        XCTAssertTrue(menu.waitForExistence(timeout: timeout))
        menu.tap()

        let search = element("mreader.shelf.ocrSearch", in: app)
        XCTAssertTrue(search.waitForExistence(timeout: timeout))
        search.tap()
        XCTAssertTrue(element("mreader.ocr.search", in: app).waitForExistence(timeout: timeout))
        let done = element("mreader.ocr.search.done", in: app)
        XCTAssertTrue(done.waitForExistence(timeout: timeout))
        done.tap()
        XCTAssertTrue(element("mreader.shelf.root", in: app).waitForExistence(timeout: timeout))
    }

    @MainActor
    func testReaderProgressModeAndOfflineTranslationEntryWhenBookIsAvailable() throws {
        let app = launchApp()
        let openReader = element("mreader.shelf.openReader", in: app)
        XCTAssertTrue(openReader.waitForExistence(timeout: timeout))
        openReader.tap()

        let reader = element("mreader.reader.root", in: app)
        XCTAssertTrue(reader.waitForExistence(timeout: timeout))
        XCTAssertTrue(element("mreader.reader.progress", in: app).waitForExistence(timeout: timeout))
        let settings = element("mreader.reader.settings", in: app)
        XCTAssertTrue(settings.waitForExistence(timeout: timeout))
        settings.tap()
        XCTAssertTrue(element("mreader.reader.settings.sheet", in: app).waitForExistence(timeout: timeout))
        let modePicker = element("mreader.reader.modePicker", in: app)
        for _ in 0..<4 {
            guard !modePicker.exists else { break }
            app.swipeUp()
        }
        XCTAssertTrue(modePicker.waitForExistence(timeout: timeout))

        let done = element("mreader.reader.settings.done", in: app)
        XCTAssertTrue(done.waitForExistence(timeout: timeout))
        done.tap()
        let offlineMenu = element("mreader.reader.offlineTranslationMenu", in: app)
        XCTAssertTrue(offlineMenu.waitForExistence(timeout: timeout))
        offlineMenu.tap()
        XCTAssertTrue(element("mreader.reader.offlineTranslationStart", in: app).waitForExistence(timeout: timeout))
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let button = app.buttons[identifier].firstMatch
        if button.exists {
            return button
        }
        return app.descendants(matching: .any)[identifier].firstMatch
    }
}
