//
//  mreaderTests.swift
//  mreaderTests
//
//  Created by 郑云凯 on 2026/6/17.
//

import Testing
import Foundation
import CoreGraphics
import UIKit
import ZIPFoundation
@testable import mreader

struct mreaderTests {

    @Test @MainActor func backgroundTaskCenterTracksAndFinishesTasks() {
        let center = BackgroundTaskCenter()
        let id = center.begin(title: "解析 PDF", detail: "large.pdf", progress: 0.2)

        #expect(center.isActive)
        #expect(center.tasks.count == 1)
        #expect(center.tasks[0].progress == 0.2)

        center.update(id, detail: "第 5 页", progress: 0.5)
        #expect(center.tasks[0].detail == "第 5 页")
        #expect(center.tasks[0].progress == 0.5)

        center.finish(id)
        #expect(!center.isActive)
    }

    @Test func opdsOneAtomCatalogParsesAcquisitionAndCover() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <entry>
            <id>book-1</id>
            <title>第一册</title>
            <link rel="http://opds-spec.org/acquisition" href="books/one.epub" type="application/epub+zip"/>
            <link rel="http://opds-spec.org/image/thumbnail" href="covers/one.jpg" type="image/jpeg"/>
          </entry>
        </feed>
        """

        let publications = try OPDSProvider.parseCatalogForDiagnostics(
            data: Data(xml.utf8),
            baseURL: URL(string: "https://example.com/opds/root.xml")!,
            contentType: "application/atom+xml;profile=opds-catalog"
        )

        #expect(publications.count == 1)
        #expect(publications[0].title == "第一册")
        #expect(publications[0].acquisitionURL.absoluteString == "https://example.com/opds/books/one.epub")
        #expect(publications[0].coverURL?.absoluteString == "https://example.com/opds/covers/one.jpg")
    }

    @Test func opdsTwoJSONCatalogParsesPublication() throws {
        let json = """
        {
          "metadata": { "title": "漫画库" },
          "publications": [{
            "metadata": { "identifier": "book-2", "title": "第二册" },
            "links": [
              { "rel": "http://opds-spec.org/acquisition", "href": "/files/two.cbz", "type": "application/vnd.comicbook+zip" },
              { "rel": "http://opds-spec.org/image", "href": "/covers/two.jpg", "type": "image/jpeg" }
            ]
          }]
        }
        """

        let publications = try OPDSProvider.parseCatalogForDiagnostics(
            data: Data(json.utf8),
            baseURL: URL(string: "https://example.com/opds/v2")!,
            contentType: "application/opds+json"
        )

        #expect(publications.count == 1)
        #expect(publications[0].id == "book-2")
        #expect(publications[0].acquisitionURL.absoluteString == "https://example.com/files/two.cbz")
    }

    @Test func visiblePageUsesLargestVisibleArea() {
        let frames = [
            0: CGRect(x: 0, y: -700, width: 390, height: 800),
            1: CGRect(x: 0, y: 100, width: 390, height: 800),
            2: CGRect(x: 0, y: 900, width: 390, height: 800)
        ]

        let result = ReaderVisiblePageDetector.visiblePageIndex(
            frames: frames,
            viewport: CGRect(x: 0, y: 0, width: 390, height: 844)
        )

        #expect(result == 1)
    }

    @Test func visiblePageUsesCenterDistanceAsTieBreaker() {
        let frames = [
            4: CGRect(x: 0, y: -200, width: 390, height: 600),
            5: CGRect(x: 0, y: 300, width: 390, height: 400)
        ]

        let result = ReaderVisiblePageDetector.visiblePageIndex(
            frames: frames,
            viewport: CGRect(x: 0, y: 0, width: 390, height: 700)
        )

        #expect(result == 5)
    }

    @Test func progressDoesNotResetWhenReaderPagesAreReleasedDuringDismiss() {
        let result = ReaderProgressPolicy.clampedPageIndex(
            7,
            loadedPageCount: 0,
            declaredPageCount: 102
        )

        #expect(result == 7)
    }

    @Test func modelPoolNormalizesInput() {
        let models = AIModelPoolManager.normalizedModels(from: """
        gpt-4.1-mini
        gemini-2.5-flash, gpt-4.1-mini

        claude-3.5-haiku
        """)

        #expect(models == ["gpt-4.1-mini", "gemini-2.5-flash", "claude-3.5-haiku"])
    }

    @Test func modelPoolRecognizesRateLimitsOnly() {
        #expect(AIModelPoolManager.isRateLimit(statusCode: 429, message: nil))
        #expect(AIModelPoolManager.isRateLimit(statusCode: 400, message: "insufficient_quota"))
        #expect(!AIModelPoolManager.isRateLimit(statusCode: 500, message: "internal server error"))
        #expect(!AIModelPoolManager.isRateLimit(statusCode: nil, message: "network connection lost"))
    }

    @Test func modelPoolRoundRobinAndRateLimitReset() async throws {
        let suiteName = "mreaderTests.modelPool.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let calendar = Calendar(identifier: .gregorian)
        let dayOne = Date(timeIntervalSince1970: 1_782_345_600)
        let manager = AIModelPoolManager(defaults: defaults, calendar: calendar)

        let first = await manager.modelsForAttempt(
            defaultModel: "default",
            poolText: "one\ntwo\nthree",
            now: dayOne
        )
        let second = await manager.modelsForAttempt(
            defaultModel: "default",
            poolText: "one\ntwo\nthree",
            now: dayOne
        )
        #expect(first == ["one", "two", "three", "default"])
        #expect(second == ["two", "three", "one", "default"])

        await manager.markRateLimited(model: "two", message: "HTTP 429", now: dayOne)
        let afterLimit = await manager.modelsForAttempt(
            defaultModel: "default",
            poolText: "one\ntwo\nthree",
            now: dayOne
        )
        #expect(!afterLimit.contains("two"))

        let nextDay = calendar.date(byAdding: .day, value: 1, to: dayOne)!
        let afterReset = await manager.modelsForAttempt(
            defaultModel: "default",
            poolText: "one\ntwo\nthree",
            now: nextDay
        )
        #expect(afterReset.contains("two"))
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func disabledModelPoolUsesOnlyDefaultModel() async throws {
        let suiteName = "mreaderTests.modelPool.disabled.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let manager = AIModelPoolManager(defaults: defaults)

        let models = await manager.modelsForAttempt(
            defaultModel: "default-model",
            poolText: "one\ntwo",
            isPoolEnabled: false
        )

        #expect(models == ["default-model"])
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func manuallySelectedPoolModelIsUsedNext() async throws {
        let suiteName = "mreaderTests.modelPool.manual.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let manager = AIModelPoolManager(defaults: defaults)

        await manager.selectModel("three", poolText: "one\ntwo\nthree")
        let models = await manager.modelsForAttempt(
            defaultModel: "default-model",
            poolText: "one\ntwo\nthree",
            isPoolEnabled: true
        )

        #expect(models.first == "three")
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func komgaBookDecodesEmbeddedReadProgress() throws {
        let json = """
        {
          "id": "book-1",
          "seriesId": "series-1",
          "libraryId": "library-1",
          "name": "Chapter 1",
          "readProgress": {
            "page": 12,
            "completed": false,
            "readDate": "2026-06-24T00:00:00Z",
            "created": "2026-06-24T00:00:00Z",
            "lastModified": "2026-06-24T00:00:00Z",
            "deviceId": "",
            "deviceName": ""
          },
          "media": { "pagesCount": 30 }
        }
        """

        let book = try JSONDecoder().decode(KomgaBookDTO.self, from: Data(json.utf8))

        #expect(book.readProgress?.resolvedPageIndex == 11)
        #expect(book.pageCount == 30)
    }

    @Test func komgaProgressPayloadConvertsZeroBasedIndexToOneBasedPage() throws {
        let payload = KomgaReadProgressUpdateDTO(pageIndex: 12, completed: false)
        let data = try JSONEncoder().encode(payload)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["page"] as? Int == 13)
        #expect(object["completed"] as? Bool == false)
        #expect(object["pageIndex"] == nil)
    }

    @Test func komgaUsesOfficialProgressAndDeleteEndpoints() {
        #expect(KomgaAPIEndpoint.readProgress(bookID: "abc") == "/api/v1/books/abc/read-progress")
        #expect(KomgaAPIEndpoint.deleteBookFile(bookID: "abc") == "/api/v1/books/abc/file")
    }

    @Test func unreadComicHasZeroDisplayedProgress() {
        let comic = ComicBook(
            title: "Unread",
            bookmarkData: Data(),
            totalPages: 100,
            currentPageIndex: 0,
            hasBeenOpened: false
        )

        #expect(ComicReadingProgress.completedPages(for: comic) == 0)
        #expect(ComicReadingProgress.fraction(for: comic) == 0)
    }

    @Test func finishedComicUsesGrassGreenProgressTint() {
        let comic = ComicBook(
            title: "Finished",
            bookmarkData: Data(),
            totalPages: 10,
            currentPageIndex: 9,
            hasBeenOpened: true
        )

        #expect(ComicReadingProgress.isFinished(comic))
    }

    @Test func readingActivityClampsInactiveTimeAndCountsForwardPages() {
        let start = Date(timeIntervalSince1970: 1_782_345_600)
        let update = ReadingActivityAccumulator.increment(
            previousDate: start,
            now: start.addingTimeInterval(3_600),
            previousPageIndex: 4,
            currentPageIndex: 9
        )

        #expect(update.seconds == 60)
        #expect(update.pages == 5)
    }

    @Test func ocrFragmentsMergeOnlyWhenFontScaleIsCompatible() {
        let first = TextBlock(
            text: "这是",
            boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.15, height: 0.04),
            confidence: 0.9,
            estimatedFontScale: 0.04,
            textColorHex: "#111111"
        )
        let continuation = TextBlock(
            text: "一句话",
            boundingBox: CGRect(x: 0.255, y: 0.1, width: 0.18, height: 0.041),
            confidence: 0.9,
            estimatedFontScale: 0.041,
            textColorHex: "#111111"
        )
        let differentStyle = TextBlock(
            text: "广告",
            boundingBox: CGRect(x: 0.44, y: 0.1, width: 0.12, height: 0.07),
            confidence: 0.9,
            estimatedFontScale: 0.07,
            textColorHex: "#FF0000"
        )

        let grouped = AITranslator.groupedMangaTextBlocks(
            [first, continuation, differentStyle],
            isRightToLeft: false
        )

        #expect(grouped.count == 2)
        #expect(grouped[0].text == "这是一句话")
        #expect(grouped[1].text == "广告")
    }

    @Test func visionImageResizePreservesAspectRatioAndFits2048() {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 4_096, height: 1_024),
            format: format
        ).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4_096, height: 1_024))
        }

        let size = AITranslator.preparedVisionImagePixelSize(image)

        #expect(size.width == 2_048)
        #expect(size.height == 512)
        #expect(abs((size.width / size.height) - 4) < 0.001)
    }

    @Test func normalizedVisionCoordinatesDoNotChangeAfterImageCompression() {
        let rect = CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.4)

        let normalized = AITranslator.normalizedVisionRectForDiagnostics(
            rect,
            inputPixelSize: CGSize(width: 2_048, height: 512)
        )

        #expect(normalized == rect)
    }

    @Test func visionPixelCoordinatesMapFromCompressedInputPixels() {
        let rect = CGRect(x: 512, y: 128, width: 1_024, height: 256)

        let normalized = AITranslator.normalizedVisionRectForDiagnostics(
            rect,
            inputPixelSize: CGSize(width: 2_048, height: 512)
        )

        #expect(abs(normalized.minX - 0.25) < 0.000_1)
        #expect(abs(normalized.minY - 0.25) < 0.000_1)
        #expect(abs(normalized.width - 0.5) < 0.000_1)
        #expect(abs(normalized.height - 0.5) < 0.000_1)
    }

    @Test func openAICompatibleContentArrayIsAccepted() throws {
        let response: [String: Any] = [
            "choices": [[
                "message": [
                    "content": [
                        ["type": "output_text", "text": "第一行"],
                        ["type": "output_text", "text": "第二行"]
                    ]
                ]
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: response)

        #expect(AITranslator.assistantContentForDiagnostics(from: data) == "第一行\n第二行")
    }

    @Test func translationSanitizerRejectsReasoningLeak() {
        let leaked = """
        analysis: 根据用户提示词先分析人物关系
        _output = "こんにちは"
        """

        #expect(
            AITranslator.sanitizedTranslationTextForDiagnostics(
                leaked,
                sourceText: "你好"
            ) == nil
        )
        #expect(
            AITranslator.sanitizedTranslationTextForDiagnostics(
                "译文：こんにちは",
                sourceText: "你好"
            ) == "こんにちは"
        )
    }

    @Test func fuzzyOCRDuplicatesAreCollapsed() {
        let original = TextBlock(
            text: "没想到你还到了",
            boundingBox: CGRect(x: 0.62, y: 0.18, width: 0.23, height: 0.08),
            confidence: 0.63,
            ocrSource: "original"
        )
        let enhanced = TextBlock(
            text: "没想到你迟到了",
            boundingBox: CGRect(x: 0.615, y: 0.182, width: 0.235, height: 0.081),
            confidence: 0.76,
            ocrSource: "enhanced"
        )

        let result = AITranslator.deduplicatedMangaTextBlocks(
            [original, enhanced],
            isRightToLeft: false
        )

        #expect(result.count == 1)
        #expect(result[0].ocrSource == "enhanced")
    }

    @Test func visionJSONRepairsRawNewlinesAndMapsCompressedPixels() throws {
        let response = """
        ```json
        {
          "items": [{
            "text": "原文",
            "translation": "第一行
        第二行",
            "bubbleBox": {"x": 512, "y": 128, "width": 1024, "height": 256}
          }]
        }
        ```
        """

        let blocks = try AITranslator.parseVisionTranslationBlocksForDiagnostics(
            from: response,
            inputPixelSize: CGSize(width: 2_048, height: 512)
        )

        #expect(blocks.count == 1)
        #expect(blocks[0].translation == "第一行\n第二行")
        #expect(abs(blocks[0].boundingBox.minX - 0.25) < 0.000_1)
        #expect(abs(blocks[0].boundingBox.minY - 0.25) < 0.000_1)
        #expect(abs(blocks[0].boundingBox.width - 0.5) < 0.000_1)
        #expect(abs(blocks[0].boundingBox.height - 0.5) < 0.000_1)
    }

    @Test func burnInProtectionUsesFourHourTimeout() {
        #expect(BurnInProtectionPolicy.timeout == 14_400)
    }

    @Test func versionFourSettingsBackupRemainsDecodable() throws {
        let json = """
        {
          "version": 4,
          "openAIAPIKey": "test-key",
          "openAIBaseURL": "https://example.com/v1",
          "openAIModel": "model",
          "translationTargetLanguage": "中文",
          "isHapticFeedbackEnabled": true
        }
        """

        let backup = try JSONDecoder().decode(MReaderSettingsBackup.self, from: Data(json.utf8))

        #expect(backup.version == 4)
        #expect(backup.translationColorStyle == nil)
        #expect(backup.readingDailyPageGoal == nil)
    }

    @Test func imageOnlyEPUBUsesSpineXHTMLImagesAsPages() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceRoot = temporaryRoot.appendingPathComponent("source", isDirectory: true)
        let epubURL = temporaryRoot.appendingPathComponent("fixture.epub")
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        try fileManager.createDirectory(at: sourceRoot.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sourceRoot.appendingPathComponent("OEBPS/Text"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sourceRoot.appendingPathComponent("OEBPS/Images"), withIntermediateDirectories: true)
        try Data("application/epub+zip".utf8).write(to: sourceRoot.appendingPathComponent("mimetype"))
        try Data("""
        <?xml version="1.0"?>
        <container>
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """.utf8).write(to: sourceRoot.appendingPathComponent("META-INF/container.xml"))
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <package version="3.0">
          <manifest>
            <item id="p1" href="Text/001.xhtml" media-type="application/xhtml+xml"/>
            <item id="p2" href="Text/002.xhtml" media-type="application/xhtml+xml"/>
            <item id="p3" href="Text/003.xhtml" media-type="application/xhtml+xml"/>
            <item id="i1" href="Images/001.jpg" media-type="image/jpeg"/>
            <item id="i2" href="Images/002.jpg" media-type="image/jpeg"/>
            <item id="i3" href="Images/003.jpg" media-type="image/jpeg"/>
          </manifest>
          <spine>
            <itemref idref="p1"/>
            <itemref idref="p2"/>
            <itemref idref="p3"/>
          </spine>
        </package>
        """.utf8).write(to: sourceRoot.appendingPathComponent("OEBPS/content.opf"))

        for index in 1...3 {
            let name = String(format: "%03d", index)
            try Data("<html><body><img src=\"../Images/\(name).jpg\"/></body></html>".utf8)
                .write(to: sourceRoot.appendingPathComponent("OEBPS/Text/\(name).xhtml"))
            try Data([0xFF, 0xD8, 0xFF, 0xD9])
                .write(to: sourceRoot.appendingPathComponent("OEBPS/Images/\(name).jpg"))
        }

        try fileManager.zipItem(at: sourceRoot, to: epubURL, shouldKeepParent: false)

        #expect(try ComicManager.archivePageCountForDiagnostics(at: epubURL) == 3)
    }

    @Test func providedRedChamberEPUBParsesAllImagePagesWhenInstalled() throws {
        let epubURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreader-real-epub-diagnostic.epub")
        guard FileManager.default.fileExists(atPath: epubURL.path) else { return }

        #expect(try ComicManager.archivePageCountForDiagnostics(at: epubURL) == 174)
    }

    @Test func providedBaoYuEPUBFirstPageDecodesWhenInstalled() throws {
        let epubURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreader-baoyu-epub-diagnostic.epub")
        guard FileManager.default.fileExists(atPath: epubURL.path) else { return }

        #expect(try ComicManager.archivePageCountForDiagnostics(at: epubURL) == 126)
        let data = try ComicManager.archiveFirstPageDataForDiagnostics(at: epubURL)
        let source = CGImageSourceCreateWithData(data as CFData, nil)
        #expect(source != nil)
        #expect(CGImageSourceGetCount(source!) == 1)
        #expect(CGImageSourceCreateThumbnailAtIndex(
            source!,
            0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 2_048
            ] as CFDictionary
        ) != nil)

        let pageURL = try ComicManager.archiveFirstPageURLForDiagnostics(at: epubURL)
        #expect(ComicManager.isArchivePageURL(pageURL))
        let pageData = try #require(ComicManager.imageData(forArchivePageURL: pageURL))
        #expect(pageData == data)

        let secondPageData = try ComicManager.archivePageDataForDiagnostics(at: epubURL, index: 1)
        let secondPageSource = try #require(CGImageSourceCreateWithData(secondPageData as CFData, nil))
        #expect(CGImageSourceCreateThumbnailAtIndex(
            secondPageSource,
            0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 2_048
            ] as CFDictionary
        ) != nil)
    }

}
