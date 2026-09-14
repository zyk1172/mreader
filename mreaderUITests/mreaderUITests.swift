import XCTest

final class mreaderUITests: XCTestCase {
    private let timeout: TimeInterval = 12
    private let semanticFallbackTimeout: TimeInterval = 2

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

        let settings = settingsMenuItem(in: app)
        XCTAssertTrue(settings.waitForExistence(timeout: timeout), "Settings menu item must be exposed by identifier or semantic label")
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
        XCTAssertTrue(element("mreader.reader.progressOverlay", in: app).waitForExistence(timeout: timeout))
        let progressSlider = readerProgressSlider(in: app)
        let ocrAction = element("mreader.reader.ocrAction", in: app)
        let aiAction = element("mreader.reader.aiAction", in: app)
        XCTAssertTrue(progressSlider.waitForExistence(timeout: timeout), "Reader progress slider must be exposed as an XCUI slider even if SwiftUI drops its identifier")
        XCTAssertTrue(ocrAction.waitForExistence(timeout: timeout))
        XCTAssertTrue(aiAction.waitForExistence(timeout: timeout))
        XCTAssertGreaterThan(ocrAction.frame.minY, progressSlider.frame.maxY - 1, "OCR action must sit below the progress slider")
        XCTAssertGreaterThan(aiAction.frame.minY, progressSlider.frame.maxY - 1, "AI action must sit below the progress slider")
        XCTAssertFalse(app.tabBars.firstMatch.exists, "reader must hide the shelf tab bar")
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

    private func settingsMenuItem(in app: XCUIApplication) -> XCUIElement {
        let identified = app.buttons["mreader.shelf.settings"].firstMatch
        if identified.waitForExistence(timeout: semanticFallbackTimeout) {
            return identified
        }

        // SwiftUI Menu is bridged to a native menu on iOS 26. The bridge can
        // preserve the visible label while dropping a Button's identifier.
        // Keep the identifier as the primary contract, with a semantic label
        // fallback for the framework-generated menu hierarchy.
        let labels = ["Settings", "设置", "設定"]
        return app.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
    }

    private func readerProgressSlider(in app: XCUIApplication) -> XCUIElement {
        let identified = app.sliders["mreader.reader.progressSlider"].firstMatch
        if identified.waitForExistence(timeout: semanticFallbackTimeout) {
            return identified
        }

        // SwiftUI Slider can lose accessibilityIdentifier while still being
        // exposed correctly with the slider accessibility trait on iOS 26.
        // The reader progress overlay contains exactly one slider.
        return app.sliders.firstMatch
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let button = app.buttons[identifier].firstMatch
        if button.exists {
            return button
        }
        return app.descendants(matching: .any)[identifier].firstMatch
    }
}