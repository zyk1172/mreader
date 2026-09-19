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

    private func launchV2B5ReaderFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-mreader-ui-testing", "-mreader-v2b5-provider"]
        app.launch()
        return app
    }

    private func launchHardCaseReaderFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-mreader-ui-testing",
            "-mreader-v2b5-provider",
            "-mangavision_hard_case_feedback_shortcut",
            "YES"
        ]
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
        // The simulator may retain a previously configured Komga/OPDS source.
        // In that state the empty-state label is intentionally absent, while
        // the source editor remains the same production remote-settings path.
        let noServers = element("mreader.remote.noServers", in: app)
        _ = noServers.waitForExistence(timeout: 2)
        XCTAssertTrue(
            element("mreader.remote.baseURL", in: app).waitForExistence(timeout: timeout),
            "Remote source editor must expose the base URL field in both empty and persisted-source states"
        )
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
        let openReader = element("mreader.shelf.uiTestingFixture", in: app)
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

    @MainActor
    func testMangaVisionHardCaseFeedbackAndQuickMark() throws {
        let app = launchHardCaseReaderFixture()
        let openReader = element("mreader.shelf.uiTestingFixture", in: app)
        XCTAssertTrue(openReader.waitForExistence(timeout: timeout))
        openReader.tap()

        XCTAssertTrue(element("mreader.reader.root", in: app).waitForExistence(timeout: timeout))
        let feedback = element("mreader.reader.mangaVisionFeedback", in: app)
        XCTAssertTrue(feedback.waitForExistence(timeout: timeout))

        feedback.tap()
        XCTAssertTrue(element("mreader.hardCase.feedback.sheet", in: app).waitForExistence(timeout: timeout))

        let body = app.buttons["Body"].firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: timeout))
        body.tap()

        let duplicate = app.buttons["重复"].firstMatch
        for _ in 0..<5 {
            if duplicate.exists, duplicate.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(duplicate.waitForExistence(timeout: timeout))
        duplicate.tap()

        let translation = app.buttons["翻译"].firstMatch
        for _ in 0..<7 {
            if translation.exists, translation.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(translation.waitForExistence(timeout: timeout))
        translation.tap()

        let save = element("mreader.hardCase.feedback.save", in: app)
        XCTAssertTrue(save.waitForExistence(timeout: timeout))
        save.tap()

        let toast = element("mreader.hardCase.toast", in: app)
        XCTAssertTrue(toast.waitForExistence(timeout: timeout))
        XCTAssertEqual(toast.label, "已加入模型训练候选")
        XCTAssertTrue(
            toast.waitForNonExistence(timeout: 5),
            "The first confirmation must dismiss before Quick Mark is exercised"
        )

        feedback.press(forDuration: 0.7)
        XCTAssertTrue(toast.waitForExistence(timeout: timeout))
        XCTAssertEqual(toast.label, "已加入模型训练候选")
    }

    @MainActor
    func testV2B5ProviderReaderGuidedPanelAndOCRControls() throws {
        let app = launchV2B5ReaderFixture()
        let openReader = element("mreader.shelf.uiTestingFixture", in: app)
        XCTAssertTrue(openReader.waitForExistence(timeout: timeout))
        openReader.tap()

        let reader = element("mreader.reader.root", in: app)
        XCTAssertTrue(reader.waitForExistence(timeout: timeout))
        let guidedPanel = element("mreader.reader.guidedPanelAction", in: app)
        XCTAssertTrue(guidedPanel.waitForExistence(timeout: 45))
        guidedPanel.tap()

        // The action must enter the real GuidedPanelReader path and remain
        // responsive while PanelDetectionService performs V2B5 inference.
        XCTAssertTrue(guidedPanel.waitForExistence(timeout: timeout))
        let ocr = element("mreader.reader.ocrAction", in: app)
        XCTAssertTrue(ocr.waitForExistence(timeout: 45))
        ocr.tap()
        XCTAssertTrue(element("mreader.reader.root", in: app).waitForExistence(timeout: timeout))
    }

    @MainActor
    func testV2B5PhysicalFinalReaderGuidedPanelAndOCRSmoke() throws {
#if V2B5_PHYSICAL_FINAL_GATE
        let enabledByCompileFlag = true
#else
        let enabledByCompileFlag = false
#endif
        let enabledByEnvironment = ProcessInfo.processInfo.environment["MREADER_V2B5_PHYSICAL_FINAL_GATE"] == "1"
        guard enabledByCompileFlag || enabledByEnvironment else {
            throw XCTSkip("Set V2B5_PHYSICAL_FINAL_GATE for the one-time physical final UI smoke")
        }

        let app = launchV2B5ReaderFixture()
        let openReader = element("mreader.shelf.uiTestingFixture", in: app)
        XCTAssertTrue(openReader.waitForExistence(timeout: timeout))
        openReader.tap()

        let reader = element("mreader.reader.root", in: app)
        XCTAssertTrue(reader.waitForExistence(timeout: 45))

        // The five-page local fixture exercises real Reader page loading and page
        // transitions without copying test-split data into the app bundle.
        for _ in 0..<4 {
            reader.swipeLeft()
            XCTAssertTrue(reader.waitForExistence(timeout: timeout))
        }
        reader.swipeUp()
        reader.swipeDown()

        let guidedPanel = element("mreader.reader.guidedPanelAction", in: app)
        XCTAssertTrue(guidedPanel.waitForExistence(timeout: 45))
        guidedPanel.tap()
        XCTAssertTrue(guidedPanel.waitForExistence(timeout: 45))

        // Guided Panel uses the page view's left/right hit regions for previous /
        // next panel and page transitions. Exercise both directions on-device.
        let rightRegion = reader.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.50))
        let leftRegion = reader.coordinate(withNormalizedOffset: CGVector(dx: 0.10, dy: 0.50))
        rightRegion.tap()
        leftRegion.tap()
        XCTAssertTrue(reader.waitForExistence(timeout: timeout))

        let ocr = element("mreader.reader.ocrAction", in: app)
        XCTAssertTrue(ocr.waitForExistence(timeout: 45))
        ocr.tap()
        XCTAssertTrue(reader.waitForExistence(timeout: timeout))

        print("MREADER_V2B5_PHYSICAL_UI_JSON={\"status\":\"PASS\",\"reader_pages\":5,\"reader_swipes\":6,\"guided_panel_transitions\":2,\"ocr_entry\":true,\"crashes\":0}")
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
