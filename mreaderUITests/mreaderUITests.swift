import XCTest

@MainActor
final class mreaderUITests: XCTestCase {
    private let timeout: TimeInterval = 12
    private let semanticFallbackTimeout: TimeInterval = 2

    override func setUpWithError() throws {
        continueAfterFailure = false

        // Launch screenshot tests intentionally exercise multiple orientations and
        // can leave the shared simulator in landscape. Keep smoke-test geometry
        // deterministic so lazy settings rows use the expected portrait viewport.
        XCUIDevice.shared.orientation = .portrait
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

        let remoteSources = settingsRow("mreader.settings.remoteSources", in: app)
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
        let identified = app.descendants(matching: .any)["mreader.shelf.settings"].firstMatch
        let labels = ["Settings", "设置", "設定"]
        let menu = app.collectionViews.firstMatch

        // SwiftUI Menu is bridged to a native, scrollable menu on iOS 26. Its
        // lower rows are not added to the accessibility tree until the menu
        // has been scrolled into view. Keep the identifier as the primary
        // contract, with a semantic label fallback for the framework bridge.
        for _ in 0..<6 {
            if identified.waitForExistence(timeout: semanticFallbackTimeout), identified.isHittable {
                return identified
            }

            let semantic = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label IN %@", labels))
                .firstMatch
            if semantic.exists, semantic.isHittable {
                return semantic
            }

            guard menu.exists else { break }
            menu.swipeUp()
        }

        return identified
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

    private func settingsRow(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let identified = app.descendants(matching: .any)[identifier].firstMatch
        let settingsList = app.collectionViews.firstMatch
        let windowFrame = app.windows.firstMatch.frame
        let navigationBarBottom = max(
            app.navigationBars.firstMatch.frame.maxY,
            windowFrame.minY + 78
        )

        // The Settings screen is also a native, scrollable SwiftUI list. Rows
        // below the first viewport are not queryable until they are visible.
        for _ in 0..<8 {
            if identified.waitForExistence(timeout: semanticFallbackTimeout) {
                let frame = identified.frame
                let isInsideSafeViewport = frame.minY >= navigationBarBottom + 8
                    && frame.maxY <= windowFrame.maxY - 8
                if identified.isHittable && isInsideSafeViewport {
                    return identified
                }

                guard settingsList.exists else { break }
                if frame.maxY < navigationBarBottom {
                    dragSettingsList(settingsList, movingUp: false)
                } else {
                    dragSettingsList(settingsList, movingUp: true)
                }
                continue
            }

            guard settingsList.exists else { break }
            dragSettingsList(settingsList, movingUp: true)
        }

        return identified
    }

    private func dragSettingsList(_ list: XCUIElement, movingUp: Bool) {
        let startOffset = CGVector(dx: 0.5, dy: movingUp ? 0.72 : 0.28)
        let endOffset = CGVector(dx: 0.5, dy: movingUp ? 0.48 : 0.52)
        list.coordinate(withNormalizedOffset: startOffset)
            .press(
                forDuration: 0.1,
                thenDragTo: list.coordinate(withNormalizedOffset: endOffset)
            )
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let button = app.buttons[identifier].firstMatch
        if button.exists {
            return button
        }
        return app.descendants(matching: .any)[identifier].firstMatch
    }
}
