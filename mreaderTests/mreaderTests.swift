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

    @Test func translationTargetsMigrateLegacyChineseWithoutDuplicateOption() {
        #expect(TranslationTargetLanguage.migrateLegacyValue("中文") == .simplifiedChinese)
        #expect(TranslationTargetLanguage.migrateLegacyValue("简体中文") == .simplifiedChinese)
        #expect(TranslationTargetLanguage.migrateLegacyValue("繁体中文") == .traditionalChinese)
        #expect(TranslationTargetLanguage.migrateLegacyValue("英文") == .english)
        #expect(TranslationTargetLanguage.migrateLegacyValue("日文") == .japanese)
        #expect(TranslationTargetLanguage.migrateLegacyValue("韩文") == .korean)
    }

    @Test func translationTargetsHaveStableUniqueIdentifiers() {
        let targets = TranslationTargetLanguage.allCases

        #expect(targets.count == 15)
        #expect(Set(targets.map(\.rawValue)).count == targets.count)
        #expect(targets.allSatisfy { $0.modelInstruction.contains($0.rawValue) })
    }

    @Test func pageTranslationParserRestoresRequestOrderAndKeepsPartialResults() throws {
        let expected = [
            AIPageTranslationItem(id: "bubble-a", sourceText: "遅かったね", order: 0),
            AIPageTranslationItem(id: "bubble-b", sourceText: "ごめん", order: 1),
            AIPageTranslationItem(id: "bubble-c", sourceText: "行こう", order: 2)
        ]
        let response = """
        ```json
        {"items":[
          {"id":"bubble-b","translation":"对不起"},
          {"id":"unknown","translation":"不能出现"},
          {"id":"bubble-a","translation":"你来晚了"},
          {"id":"bubble-a","translation":"重复结果"}
        ]}
        ```
        """

        let result = try AIPageTranslationParser.parse(
            response,
            expectedItems: expected,
            target: .simplifiedChinese
        )

        #expect(result.items.map(\.id) == ["bubble-a", "bubble-b"])
        #expect(result.items.map(\.translation) == ["你来晚了", "对不起"])
        #expect(result.missingIDs == ["bubble-c"])
    }

    @Test func pageTranslationValidatorRejectsClearlyWrongScript() {
        #expect(TranslationOutputValidator.isCompatible("This is correct.", target: .english))
        #expect(!TranslationOutputValidator.isCompatible("これは英語ではありません", target: .english))
        #expect(TranslationOutputValidator.isCompatible("这是正确的译文", target: .simplifiedChinese))
        #expect(!TranslationOutputValidator.isCompatible("이것은 중국어가 아닙니다", target: .simplifiedChinese))
    }

    @Test func pageTranslationPromptContainsStableIDsAndExplicitTarget() throws {
        let prompt = try AIPageTranslationPromptBuilder.prompt(
            items: [
                AIPageTranslationItem(id: "b0", sourceText: "遅い", order: 0),
                AIPageTranslationItem(id: "b1", sourceText: "ごめん", order: 1)
            ],
            sourceLanguage: .japanese,
            target: .simplifiedChinese,
            styleInstructions: "保持自然口语"
        )

        #expect(prompt.contains("zh-Hans"))
        #expect(prompt.contains("ja"))
        #expect(prompt.contains("\"id\" : \"b0\""))
        #expect(prompt.contains("\"id\" : \"b1\""))
        #expect(prompt.contains("禁止修改、合并、拆分"))
    }

    @Test func visionRecognitionFiltersNonContentAndFallsBackToTextGeometry() throws {
        let response = """
        {"coordinateSpace":"normalized","items":[
          {
            "id":"dialogue-1",
            "text":"こんにちは",
            "classification":"dialogue",
            "textBox":{"x":0.2,"y":0.3,"width":0.2,"height":0.08},
            "bubbleBox":{"x":0.2,"y":0.3,"width":0.2,"height":0.08},
            "confidence":0.92
          },
          {
            "id":"url-1",
            "text":"https://example.com",
            "classification":"url",
            "textBox":{"x":0.1,"y":0.9,"width":0.4,"height":0.03},
            "confidence":0.99
          }
        ]}
        """

        let blocks = try AITranslator.parseVisionRecognitionBlocksForDiagnostics(
            from: response,
            inputPixelSize: CGSize(width: 1_000, height: 2_000)
        )

        #expect(blocks.count == 1)
        #expect(blocks[0].text == "こんにちは")
        #expect(abs(blocks[0].boundingBox.minX - 0.2) < 0.000_1)
        #expect(abs(blocks[0].boundingBox.width - 0.2) < 0.000_1)
        #expect(blocks[0].translation == nil)
    }

    @Test func visionRecognitionPromptDoesNotAskModelToTranslate() {
        let prompt = AITranslator.visionRecognitionPromptForDiagnostics(
            isRightToLeft: true,
            additionalInstructions: "优先保留竖排文字方向"
        )

        #expect(prompt.contains("只识别原文"))
        #expect(prompt.contains("从右到左"))
        #expect(prompt.contains("不要翻译"))
        #expect(prompt.contains("优先保留竖排文字方向"))
        #expect(prompt.lowercased().contains("coordinatespace"))
    }

    @Test func iPhoneShelfUsesTwoFullWidthColumns() {
        let result = ShelfCardMetrics.gridLayout(for: 393, idiom: .phone)

        #expect(result.columns.count == 2)
        #expect(result.cardWidth == 170)
    }

    @Test func iPadShelfUsesAdditionalColumns() {
        let result = ShelfCardMetrics.gridLayout(for: 744, idiom: .pad)

        #expect(result.columns.count >= 3)
        #expect(result.cardWidth >= 160)
    }

    @Test func ocrCoordinateMapperUsesVisibleAspectFitRect() {
        let transform = OCRCoordinateMapper.displayTransform(
            sourcePixelSize: CGSize(width: 1_000, height: 2_000),
            containerSize: CGSize(width: 1_000, height: 1_000),
            fitMode: .fitScreen
        )

        #expect(transform.imageRect == CGRect(x: 250, y: 0, width: 500, height: 1_000))
        #expect(
            OCRCoordinateMapper.displayRect(
                forNormalizedPageRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1),
                using: transform
            ) == CGRect(x: 300, y: 200, width: 150, height: 100)
        )
    }

    @Test func ocrCoordinateMapperRestoresSliceCoordinates() {
        let mapped = OCRCoordinateMapper.normalizedPageRect(
            forSliceRect: CGRect(x: 0.2, y: 0.5, width: 0.4, height: 0.2),
            sourceRect: CGRect(x: 0, y: 0.4, width: 1, height: 0.3)
        )

        #expect(abs(mapped.minX - 0.2) < 0.000_1)
        #expect(abs(mapped.minY - 0.55) < 0.000_1)
        #expect(abs(mapped.width - 0.4) < 0.000_1)
        #expect(abs(mapped.height - 0.06) < 0.000_1)
    }

    @Test func ocrCoordinateMapperAppliesZoomAndPanToImageAndBoxes() {
        let transform = OCRCoordinateMapper.displayTransform(
            sourcePixelSize: CGSize(width: 100, height: 100),
            containerSize: CGSize(width: 200, height: 200),
            fitMode: .fitScreen,
            zoomScale: 2,
            panOffset: CGSize(width: 10, height: -20)
        )

        #expect(transform.imageRect == CGRect(x: -90, y: -120, width: 400, height: 400))
        #expect(
            OCRCoordinateMapper.displayRect(
                forNormalizedPageRect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
                using: transform
            ) == CGRect(x: 10, y: -20, width: 200, height: 200)
        )
    }

    @Test func ocrCandidateResolverPrefersVariantConsensus() {
        let box = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.05)
        let result = OCRCandidateResolver.resolve([
            TextBlock(text: "你回来了", boundingBox: box, confidence: 0.82, ocrSource: "original"),
            TextBlock(text: "你回来了", boundingBox: box.offsetBy(dx: 0.002, dy: 0), confidence: 0.78, ocrSource: "enhanced"),
            TextBlock(text: "你问来了", boundingBox: box, confidence: 0.86, ocrSource: "inverted")
        ], isRightToLeft: false)

        #expect(result.resolvedBlocks.count == 1)
        #expect(result.resolvedBlocks[0].text == "你回来了")
        #expect(result.rejectedBlocks.count == 2)
    }

    @Test func ocrCandidateResolverKeepsNearbyDistinctText() {
        let result = OCRCandidateResolver.resolve([
            TextBlock(text: "等等", boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.10, height: 0.04), confidence: 0.9),
            TextBlock(text: "快走", boundingBox: CGRect(x: 0.205, y: 0.1, width: 0.10, height: 0.04), confidence: 0.9)
        ], isRightToLeft: false)

        #expect(result.resolvedBlocks.map(\.text).sorted() == ["快走", "等等"])
    }

    @Test func mangaSegmenterDoesNotTransitivelyMergeThreeBubbles() {
        let blocks = [
            TextBlock(text: "第一句", boundingBox: CGRect(x: 0.05, y: 0.10, width: 0.20, height: 0.04), estimatedFontScale: 0.04),
            TextBlock(text: "第二句", boundingBox: CGRect(x: 0.27, y: 0.10, width: 0.20, height: 0.04), estimatedFontScale: 0.04),
            TextBlock(text: "第三句", boundingBox: CGRect(x: 0.49, y: 0.10, width: 0.20, height: 0.04), estimatedFontScale: 0.04)
        ]

        let result = MangaTextSegmenter.segment(blocks, isRightToLeft: false)

        #expect(result.bubbles.count == 3)
    }

    @Test func mangaSegmenterMergesCloseSameStyleFragments() {
        let result = MangaTextSegmenter.segment([
            TextBlock(
                text: "这是",
                boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.15, height: 0.04),
                estimatedFontScale: 0.04,
                textColorHex: "#181818"
            ),
            TextBlock(
                text: "一句话",
                boundingBox: CGRect(x: 0.255, y: 0.1, width: 0.18, height: 0.041),
                estimatedFontScale: 0.041,
                textColorHex: "#202020"
            )
        ], isRightToLeft: false)

        #expect(result.bubbles.count == 1)
        #expect(result.bubbles[0].text == "这是一句话")
    }

    @Test func mangaSegmenterSeparatesDifferentFontOrColor() {
        let result = MangaTextSegmenter.segment([
            TextBlock(
                text: "对白",
                boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.12, height: 0.04),
                estimatedFontScale: 0.04,
                textColorHex: "#111111"
            ),
            TextBlock(
                text: "标注",
                boundingBox: CGRect(x: 0.225, y: 0.1, width: 0.12, height: 0.06),
                estimatedFontScale: 0.06,
                textColorHex: "#F02020"
            )
        ], isRightToLeft: false)

        #expect(result.bubbles.count == 2)
    }

    @Test func ocrLanguagePassesSeparateJapaneseFromChineseKorean() {
        let passes = OCRPreprocessor.languagePassesForDiagnostics()

        #expect(passes.contains(["zh-Hans", "zh-Hant", "ko-KR", "en-US"]))
        #expect(passes.contains(["ja-JP", "en-US"]))
        #expect(!passes.contains(["zh-Hans", "zh-Hant", "ja-JP", "ko-KR", "en-US"]))
    }

    @Test func ocrAdaptiveLanguagePlanPrioritizesDetectedScript() {
        let japanese = OCRPreprocessor.preferredLanguagePassesForDiagnostics(
            detectedTexts: ["こんにちは、先生"]
        )
        let chinese = OCRPreprocessor.preferredLanguagePassesForDiagnostics(
            detectedTexts: ["今天一起看漫画"]
        )
        let korean = OCRPreprocessor.preferredLanguagePassesForDiagnostics(
            detectedTexts: ["안녕하세요"]
        )
        let english = OCRPreprocessor.preferredLanguagePassesForDiagnostics(
            detectedTexts: ["Hello world"]
        )

        #expect(japanese.first == ["ja-JP", "en-US"])
        #expect(chinese.first == ["zh-Hans", "zh-Hant", "en-US"])
        #expect(korean.first == ["ko-KR", "en-US"])
        #expect(english.first == ["en-US"])
    }

    @Test func localOCRCacheKeyTracksRecognitionSettings() {
        let pageURL = URL(fileURLWithPath: "/tmp/mreader-ocr-cache-test.jpg")
        let image = UIImage()
        let base = OCRRecognitionCacheRequest(
            pageURL: pageURL,
            fallbackImage: image,
            options: OCRPreprocessor.Options(isRightToLeft: false, minimumTextHeight: 0.006)
        )
        let changedDirection = OCRRecognitionCacheRequest(
            pageURL: pageURL,
            fallbackImage: image,
            options: OCRPreprocessor.Options(isRightToLeft: true, minimumTextHeight: 0.006)
        )
        let changedThreshold = OCRRecognitionCacheRequest(
            pageURL: pageURL,
            fallbackImage: image,
            options: OCRPreprocessor.Options(isRightToLeft: false, minimumTextHeight: 0.01)
        )
        let changedMode = OCRRecognitionCacheRequest(
            pageURL: pageURL,
            fallbackImage: image,
            options: OCRPreprocessor.Options(
                isRightToLeft: false,
                minimumTextHeight: 0.006,
                recognitionMode: .maximumAccuracy
            )
        )

        #expect(base.cacheKey != changedDirection.cacheKey)
        #expect(base.cacheKey != changedThreshold.cacheKey)
        #expect(base.cacheKey != changedMode.cacheKey)
    }

    @Test func mangaOCRPipelineKeepsEveryDiagnosticStage() {
        let raw = [
            TextBlock(text: "你", boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.04, height: 0.04), confidence: 0.8, ocrSource: "original:zh-ko"),
            TextBlock(text: "你", boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.04, height: 0.04), confidence: 0.76, ocrSource: "enhanced:zh-ko"),
            TextBlock(text: "好", boundingBox: CGRect(x: 0.145, y: 0.1, width: 0.04, height: 0.04), confidence: 0.9, ocrSource: "original:zh-ko")
        ]

        let result = MangaOCRPipeline.resolveForDiagnostics(raw, isRightToLeft: false)

        #expect(result.rawBlocks.count == 3)
        #expect(result.resolvedBlocks.count == 2)
        #expect(result.lineBlocks.count == 1)
        #expect(result.bubbleBlocks.map(\.text) == ["你好"])
        #expect(result.rejectedBlocks.count == 1)
    }

    @Test func ocrBubbleLayoutStaysInsideVisibleImageBounds() {
        let bounds = CGRect(x: 100, y: 0, width: 200, height: 400)
        let rect = OCRBubbleLayoutEngine.clamped(
            CGRect(x: 40, y: -20, width: 120, height: 80),
            to: bounds,
            margin: 8
        )

        #expect(rect.minX >= bounds.minX + 8)
        #expect(rect.minY >= bounds.minY + 8)
        #expect(rect.maxX <= bounds.maxX - 8)
        #expect(rect.maxY <= bounds.maxY - 8)
    }

    @Test func ocrBubbleLayoutAvoidsExistingBubbleNearAnchor() {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        let original = CGRect(x: 130, y: 200, width: 130, height: 70)
        let occupied = [original.insetBy(dx: -4, dy: -4)]
        let placed = OCRBubbleLayoutEngine.nonOverlappingRect(
            original,
            anchor: CGPoint(x: 195, y: 235),
            occupiedRects: occupied,
            bounds: bounds
        )

        #expect(!placed.intersects(occupied[0]))
        #expect(bounds.contains(placed))
        #expect(hypot(placed.midX - 195, placed.midY - 235) < 220)
    }

    @Test @MainActor func translationBubbleMeasurementFitsDenseTextInsideImage() {
        let bounds = CGRect(x: 40, y: 0, width: 310, height: 780)
        let source = CGRect(x: 250, y: 680, width: 70, height: 40)
        let rect = OCRBubbleLayoutEngine.measuredBubbleRect(
            text: "这是一段需要自然换行且不能跑出屏幕边缘的漫画翻译对白。",
            fontSize: 17,
            sourceRect: source,
            bounds: bounds,
            maximumWidth: 220,
            lineSpacing: 2
        )

        #expect(bounds.insetBy(dx: 12, dy: 12).contains(rect))
        #expect(rect.height > source.height)
        #expect(rect.width <= 220)
    }

    @Test func translatedFontIsOnlySlightlyLargerThanSourceFont() {
        #expect(abs(OCRBubbleLayoutEngine.preferredTranslationFontSize(sourceFontSize: 16) - 17.6) < 0.01)
        #expect(OCRBubbleLayoutEngine.preferredTranslationFontSize(sourceFontSize: 30) == 22)
        #expect(OCRBubbleLayoutEngine.preferredTranslationFontSize(sourceFontSize: 6) == 9)
    }

    @Test func ocrTranslationUsesBoundedTimeoutAndFastFallbackPolicy() {
        #expect(AITranslationRequestPolicy.pageModelAttempts == 1)
        #expect(AITranslationRequestPolicy.pageRequestTimeout == 25)
        #expect(AITranslationRequestPolicy.fallbackModelAttempts == 1)
        #expect(AITranslationRequestPolicy.fallbackRequestTimeout == 30)
        #expect(!AITranslationRequestPolicy.shouldUsePageTranslation(blockCount: 1))
        #expect(AITranslationRequestPolicy.shouldUsePageTranslation(blockCount: 2))
        #expect(AITranslationRequestPolicy.maximumOCRWaitBeforeResult <= 85)
    }

    @Test func visualOCRVerificationSelectsOnlyUncertainBlocks() {
        let blocks = [
            TextBlock(text: "清楚", boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05), confidence: 0.91),
            TextBlock(text: "�??", boundingBox: CGRect(x: 0.5, y: 0.2, width: 0.2, height: 0.05), confidence: 0.41)
        ]

        let regions = AITranslator.visualVerificationRegionsForDiagnostics(blocks)

        #expect(regions.count == 1)
        #expect(regions[0].blockID == blocks[1].id)
        #expect(regions[0].sourceRect.minX < blocks[1].boundingBox.minX)
        #expect(regions[0].sourceRect.maxX > blocks[1].boundingBox.maxX)
    }

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

    @Test func aiProviderKeepsIndependentTextAndVisionModels() {
        let profile = AIProviderProfile.normalized(
            name: " 中转服务 ",
            baseURL: " https://example.com/v1/ ",
            modelsText: "gpt-4.1-mini\n qwen-vl ,gpt-4.1-mini",
            selectedTextModel: "gpt-4.1-mini",
            selectedVisionModel: "qwen-vl"
        )

        #expect(profile.name == "中转服务")
        #expect(profile.baseURL == "https://example.com/v1")
        #expect(profile.models == ["gpt-4.1-mini", "qwen-vl"])
        #expect(profile.selectedTextModel == "gpt-4.1-mini")
        #expect(profile.selectedVisionModel == "qwen-vl")
    }

    @Test func legacyAISettingsMigrateIntoOneParentWithChildModels() {
        let profile = AIProviderProfile.fromLegacySettings(
            apiDisplayName: "默认接口",
            baseURL: "https://example.com/v1",
            defaultModel: "primary-model",
            poolText: "secondary-model\nprimary-model"
        )

        #expect(profile.models == ["primary-model", "secondary-model"])
        #expect(profile.selectedTextModel == "primary-model")
        #expect(profile.selectedVisionModel == "primary-model")
    }

    @Test @MainActor func aiProviderStoreResolvesOnlySelectedParentAndChild() throws {
        let suiteName = "AIProviderStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let credentials = InMemoryAICredentialStore()
        let store = AIProviderStore(defaults: defaults, credentials: credentials)
        let first = AIProviderProfile.normalized(
            name: "接口 A",
            baseURL: "https://a.example/v1",
            modelsText: "text-a\nvision-a",
            selectedTextModel: "text-a",
            selectedVisionModel: "vision-a"
        )
        let second = AIProviderProfile.normalized(
            name: "接口 B",
            baseURL: "https://b.example/v1",
            modelsText: "model-b",
            selectedTextModel: "model-b",
            selectedVisionModel: "model-b"
        )
        try store.save(profile: first, apiKey: "key-a")
        try store.save(profile: second, apiKey: "key-b")
        store.setActiveProfile(id: first.id)

        let active = try #require(store.activeConfiguration())
        #expect(active.profileID == first.id)
        #expect(active.textModel == "text-a")
        #expect(active.visionModel == "vision-a")
        #expect(active.apiKey == "key-a")
    }

    @Test @MainActor func aiProviderStoreSwitchesSelectedChildModelAndActivatesProfile() throws {
        let suiteName = "AIProviderSwitchTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let credentials = InMemoryAICredentialStore()
        let store = AIProviderStore(defaults: defaults, credentials: credentials)
        let first = AIProviderProfile.normalized(
            name: "接口 A",
            baseURL: "https://a.example/v1",
            modelsText: "ocr-a\nvision-a",
            selectedTextModel: "ocr-a",
            selectedVisionModel: "vision-a"
        )
        let second = AIProviderProfile.normalized(
            name: "接口 B",
            baseURL: "https://b.example/v1",
            modelsText: "ocr-b\nvision-b",
            selectedTextModel: "ocr-b",
            selectedVisionModel: "vision-b"
        )
        try store.save(profile: first, apiKey: "key-a")
        try store.save(profile: second, apiKey: "key-b")
        store.setActiveProfile(id: first.id)

        try store.setSelectedModel("vision-b", for: second.id, activate: true)

        let active = try #require(store.activeConfiguration())
        #expect(active.profileID == second.id)
        #expect(active.textModel == "vision-b")
        #expect(active.visionModel == "vision-b")
        #expect(active.apiKey == "key-b")
    }

    @Test func settingsBackupPreservesAIProvidersAndSharedSelectedModel() throws {
        let profile = AIProviderProfile.normalized(
            name: "中转接口",
            baseURL: "https://relay.example/v1",
            modelsText: "ocr-model\nvision-model\nshared-model",
            selectedTextModel: "ocr-model",
            selectedVisionModel: "vision-model"
        )
        let backup = MReaderSettingsBackup(
            openAIAPIKey: "legacy-key",
            openAIBaseURL: "https://legacy.example/v1",
            openAIModel: "legacy-model",
            aiModelPool: nil,
            isAIModelPoolEnabled: false,
            translationTargetLanguage: "简体中文",
            translationPromptTemplate: nil,
            visionTranslationPromptTemplate: nil,
            isHapticFeedbackEnabled: true,
            mediaSources: nil,
            translationColorStyle: nil,
            isAITranslationBorderProgressEnabled: true,
            isOCRDebugBoxesEnabled: false,
            isOCRVisualVerificationEnabled: true,
            ocrLocalRecognitionMode: OCRRecognitionMode.maximumAccuracy.rawValue,
            readingDailyPageGoal: 100,
            isBurnInProtectionEnabled: true,
            isICloudMetadataSyncEnabled: true,
            aiProviders: [AIProviderBackup(profile: profile, apiKey: "provider-key")],
            activeAIProviderID: profile.id
        )

        let decoded = try JSONDecoder().decode(
            MReaderSettingsBackup.self,
            from: JSONEncoder().encode(backup)
        )
        let provider = try #require(decoded.aiProviders?.first)

        #expect(decoded.version == 9)
        #expect(decoded.isOCRVisualVerificationEnabled == true)
        #expect(decoded.ocrLocalRecognitionMode == OCRRecognitionMode.maximumAccuracy.rawValue)
        #expect(decoded.isICloudMetadataSyncEnabled == true)
        #expect(decoded.activeAIProviderID == profile.id)
        #expect(provider.profile.id == profile.id)
        #expect(provider.profile.models == ["ocr-model", "vision-model", "shared-model"])
        #expect(provider.profile.selectedTextModel == "ocr-model")
        #expect(provider.profile.selectedVisionModel == "vision-model")
        #expect(provider.apiKey == "provider-key")
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

    @Test func verticalMangaColumnsMergeIntoSingleDialogue() {
        // 竖排日文：同一气泡里两列长度不同（顶端对齐），列宽≈字号
        let rightColumn = TextBlock(
            text: "きみのことが",
            boundingBox: CGRect(x: 0.60, y: 0.10, width: 0.035, height: 0.20),
            confidence: 0.9
        )
        let leftColumn = TextBlock(
            text: "すきだ",
            boundingBox: CGRect(x: 0.555, y: 0.10, width: 0.035, height: 0.11),
            confidence: 0.9
        )

        let grouped = AITranslator.groupedMangaTextBlocks(
            [rightColumn, leftColumn],
            isRightToLeft: true
        )

        #expect(grouped.count == 1)
        #expect(grouped[0].text == "きみのことがすきだ")
    }

    @Test func webtoonRowsSortByReadingOrderDespiteTinyNormalizedHeights() {
        // 长条漫画：整页归一化后行高极小，纵向相邻的行必须按从上到下排序
        let line1 = TextBlock(text: "第一行", boundingBox: CGRect(x: 0.30, y: 0.100, width: 0.4, height: 0.004))
        let line2 = TextBlock(text: "第二行", boundingBox: CGRect(x: 0.10, y: 0.108, width: 0.4, height: 0.004))
        let line3 = TextBlock(text: "第三行", boundingBox: CGRect(x: 0.50, y: 0.116, width: 0.4, height: 0.004))

        let sorted = AITranslator.sortedTextBlocks([line3, line1, line2], isRightToLeft: false)

        #expect(sorted.map(\.text) == ["第一行", "第二行", "第三行"])
    }

    @Test func pageContextIsRenderedIntoTranslationPrompt() {
        let blocks = [
            TextBlock(text: "第一句", boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.05)),
            TextBlock(text: "第二句", boundingBox: CGRect(x: 0.1, y: 0.3, width: 0.3, height: 0.05))
        ]

        let context = AITranslator.pageContextDescription(blocks: blocks, currentIndex: 1)
        #expect(context == "1. 第一句\n2. 第二句（当前要翻译的句子）")

        let prompt = AITranslator.renderPromptForDiagnostics(
            template: AITranslator.defaultTranslationPromptTemplate,
            text: "第二句",
            targetLanguage: "中文",
            ocrMetadata: "",
            pageContext: context
        )
        #expect(prompt.contains("1. 第一句"))
        #expect(!prompt.contains("{pageContext}"))
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

    @Test func visionSmallPixelCoordinatesWithoutMarkerAreRejected() throws {
        // 报告中的场景：2048×2048 输入上模型返回 x=20,y=25,width=40,height=30（全部小于 100 的像素）。
        // 新协议不再猜测“是百分比/是像素”，缺少显式 normalized 标记即整条拒绝，避免被放大几十倍。
        let response = """
        {"items": [{"text": "原文", "translation": "译文", "bubbleBox": {"x": 20, "y": 25, "width": 40, "height": 30}}]}
        """

        do {
            _ = try AITranslator.parseVisionTranslationBlocksForDiagnostics(
                from: response,
                inputPixelSize: CGSize(width: 2_048, height: 2_048)
            )
            Issue.record("缺少 normalized 标记的像素坐标应被拒绝")
        } catch {
            // 期望：抛出坐标协议错误
        }
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
          "coordinateSpace": "normalized",
          "items": [{
            "text": "原文",
            "translation": "第一行
        第二行",
            "bubbleBox": {"x": 0.25, "y": 0.25, "width": 0.5, "height": 0.5}
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

    @Test func visionThousandScaleCoordinatesWithoutMarkerAreRejected() throws {
        // 0~1000 归一化不再被自动猜测；没有显式 normalized 标记的 100/700 等坐标（值 > 1）应被拒绝
        let response = """
        {"items": [{"text": "原文", "translation": "译文", "bubbleBox": {"x": 100, "y": 700, "width": 800, "height": 250}}]}
        """

        do {
            _ = try AITranslator.parseVisionTranslationBlocksForDiagnostics(
                from: response,
                inputPixelSize: CGSize(width: 900, height: 600)
            )
            Issue.record("0~1000 坐标缺少 normalized 标记应被拒绝")
        } catch {
            // 期望：抛出坐标协议错误
        }
    }

    @Test func visionAllItemsShareExplicitNormalizedSpace() throws {
        // 同一响应内所有坐标都在显式 normalized 空间内，统一按 0...1 解析
        let response = """
        {"coordinateSpace": "normalized", "items": [
          {"text": "杂点", "translation": "杂点译文", "bubbleBox": {"x": 0.01, "y": 0.01, "width": 0.05, "height": 0.05}},
          {"text": "对白", "translation": "对白译文", "bubbleBox": {"x": 0.25, "y": 0.25, "width": 0.5, "height": 0.5}}
        ]}
        """

        let blocks = try AITranslator.parseVisionTranslationBlocksForDiagnostics(
            from: response,
            inputPixelSize: CGSize(width: 2_048, height: 512)
        )

        #expect(blocks.count == 2)
        #expect(blocks[1].translation == "对白译文")
        #expect(abs(blocks[1].boundingBox.minX - 0.25) < 0.000_1)
    }

    @Test func translationSanitizerStripsAnnouncementPrefixInsteadOfRejecting() {
        #expect(
            AITranslator.sanitizedTranslationTextForDiagnostics(
                "以下是翻译：你来晚了",
                sourceText: "遅かったな"
            ) == "你来晚了"
        )
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

    @Test func remotePageCacheRetainsOnlyTheActiveWindow() async {
        let cache = RemotePageCache.shared
        await cache.clearMemoryCache()
        let sourceID = UUID()
        let oldPage = PageCacheKey(sourceID: sourceID, bookID: "book", pageIndex: 1)
        let currentPage = PageCacheKey(sourceID: sourceID, bookID: "book", pageIndex: 2)
        let prefetchedPage = PageCacheKey(sourceID: sourceID, bookID: "book", pageIndex: 3)

        await cache.storeForDiagnostics(Data([1]), for: oldPage)
        await cache.storeForDiagnostics(Data([2]), for: currentPage)
        await cache.storeForDiagnostics(Data([3]), for: prefetchedPage)
        await cache.retainMemoryPages([currentPage, prefetchedPage])

        let hasOldPage = await cache.containsInMemoryForDiagnostics(oldPage)
        let hasCurrentPage = await cache.containsInMemoryForDiagnostics(currentPage)
        let hasPrefetchedPage = await cache.containsInMemoryForDiagnostics(prefetchedPage)
        #expect(!hasOldPage)
        #expect(hasCurrentPage)
        #expect(hasPrefetchedPage)
        await cache.clearMemoryCache()
    }

    @Test func librarySyncCoordinatorCoalescesConcurrentRefreshes() async {
        let coordinator = LibrarySyncCoordinator()
        let probe = LibrarySyncProbe()

        let firstRefresh = Task {
            await coordinator.perform(scope: .local) { scope in
                await probe.record(scope)
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
        while await probe.invocationCount == 0 {
            await Task.yield()
        }

        await withTaskGroup(of: Void.self) { group in
            for scope in [LibrarySyncScope.komga, .opds, .komga] {
                group.addTask {
                    await coordinator.perform(scope: scope) { requestedScope in
                        await probe.record(requestedScope)
                    }
                }
            }
        }
        await firstRefresh.value

        let scopes = await probe.invocationScopes
        #expect(scopes.count == 2)
        #expect(scopes.first == .local)
        #expect(scopes.last?.contains(.komga) == true)
        #expect(scopes.last?.contains(.opds) == true)
        #expect(!(await coordinator.isRefreshingForDiagnostics()))
    }

    @Test func encryptedSettingsBackupHidesCredentialsAndRoundTrips() throws {
        let secret = "integration-secret-value"
        let profile = AIProviderProfile.normalized(
            name: "Test",
            baseURL: "https://example.com/v1",
            modelsText: "model-a",
            selectedTextModel: "model-a",
            selectedVisionModel: "model-a"
        )
        let backup = MReaderSettingsBackup(
            openAIAPIKey: secret,
            openAIBaseURL: profile.baseURL,
            openAIModel: profile.selectedTextModel,
            aiModelPool: nil,
            isAIModelPoolEnabled: false,
            translationTargetLanguage: "简体中文",
            translationPromptTemplate: nil,
            visionTranslationPromptTemplate: nil,
            isHapticFeedbackEnabled: true,
            mediaSources: nil,
            translationColorStyle: nil,
            isAITranslationBorderProgressEnabled: true,
            isOCRDebugBoxesEnabled: false,
            readingDailyPageGoal: 40,
            isBurnInProtectionEnabled: true,
            aiProviders: [AIProviderBackup(profile: profile, apiKey: secret)],
            activeAIProviderID: profile.id,
            containsCredentials: true
        )

        let encrypted = try SettingsBackupCodec.encodeEncrypted(backup, password: "valid-password")
        #expect(SettingsBackupCodec.isEncrypted(encrypted))
        #expect(!(String(data: encrypted, encoding: .utf8) ?? "").contains(secret))

        let restored = try SettingsBackupCodec.decode(encrypted, password: "valid-password")
        #expect(restored.openAIAPIKey == secret)
        #expect(restored.aiProviders?.first?.apiKey == secret)
        #expect(throws: (any Error).self) {
            _ = try SettingsBackupCodec.decode(encrypted, password: "wrong-password")
        }
    }

    @Test func plainSettingsBackupRejectsCredentials() throws {
        let secret = "must-not-be-plain-text"
        var backup = MReaderSettingsBackup(
            openAIAPIKey: secret,
            openAIBaseURL: "https://example.com/v1",
            openAIModel: "model-a",
            aiModelPool: nil,
            isAIModelPoolEnabled: false,
            translationTargetLanguage: "简体中文",
            translationPromptTemplate: nil,
            visionTranslationPromptTemplate: nil,
            isHapticFeedbackEnabled: true,
            mediaSources: nil,
            translationColorStyle: nil,
            isAITranslationBorderProgressEnabled: true,
            isOCRDebugBoxesEnabled: false,
            readingDailyPageGoal: 40,
            isBurnInProtectionEnabled: true,
            aiProviders: nil,
            activeAIProviderID: nil,
            containsCredentials: true
        )

        #expect(throws: SettingsBackupCodecError.self) {
            _ = try SettingsBackupCodec.encodePlain(backup)
        }

        backup.openAIAPIKey = nil
        backup.containsCredentials = false
        let plainData = try SettingsBackupCodec.encodePlain(backup)
        #expect(!SettingsBackupCodec.isEncrypted(plainData))
        #expect(!(String(data: plainData, encoding: .utf8) ?? "").contains(secret))
    }

    @Test func remoteProgressKeepsLatestLocationAndHighestCompletion() {
        let now = Date()
        let existing = ComicBook(
            title: "Remote",
            bookmarkData: Data(),
            totalPages: 100,
            currentPageIndex: 40,
            furthestPageIndex: 70,
            progressUpdatedAt: now
        )
        let olderRemote = ComicBook(
            title: "Remote",
            bookmarkData: Data(),
            totalPages: 100,
            currentPageIndex: 60,
            furthestPageIndex: 60,
            progressUpdatedAt: now.addingTimeInterval(-60)
        )
        let resolution = ReadingProgressMergePolicy.resolve(
            existing: existing,
            incoming: olderRemote,
            totalPages: 100
        )

        #expect(resolution.currentPageIndex == 40)
        #expect(resolution.furthestPageIndex == 70)
        #expect(!resolution.usesIncomingLocation)
        #expect(ReadingProgressMergePolicy.serverPageIndex(for: existing) == 70)
    }

    @Test @MainActor func legacyComicProgressMigratesFurthestPageFromCurrentLocation() throws {
        let legacy = """
        {
          "id":"\(UUID().uuidString)",
          "title":"Legacy",
          "bookmarkData":"",
          "totalPages":50,
          "sourceTypeRaw":"local",
          "currentPageIndex":12
        }
        """
        let comic = try JSONDecoder().decode(ComicBook.self, from: Data(legacy.utf8))

        #expect(comic.currentPageIndex == 12)
        #expect(comic.furthestPageIndex == 12)
        #expect(comic.progressUpdatedAt == .distantPast)
    }

    @Test func translationPrefetchRequiresAutoTranslationAndStaysAhead() {
        #expect(AITranslationPrefetchPolicy.pageIndices(
            currentPageIndex: 3,
            pageCount: 10,
            isAutoTranslationEnabled: false
        ).isEmpty)
        #expect(AITranslationPrefetchPolicy.pageIndices(
            currentPageIndex: 3,
            pageCount: 10,
            isAutoTranslationEnabled: true
        ) == [4, 5])
        #expect(AITranslationPrefetchPolicy.pageIndices(
            currentPageIndex: 8,
            pageCount: 10,
            isAutoTranslationEnabled: true
        ) == [9])
        #expect(AITranslationPrefetchPolicy.pageIndices(
            currentPageIndex: 9,
            pageCount: 10,
            isAutoTranslationEnabled: true
        ).isEmpty)
    }

    @Test func guidedPanelOrderingFollowsReadingDirection() {
        let left = CGRect(x: 0.05, y: 0.05, width: 0.4, height: 0.35)
        let right = CGRect(x: 0.55, y: 0.05, width: 0.4, height: 0.35)
        let bottom = CGRect(x: 0.1, y: 0.55, width: 0.8, height: 0.35)

        #expect(PanelDetectionService.sortedPanelsForDiagnostics([bottom, right, left], isRightToLeft: false) == [left, right, bottom])
        #expect(PanelDetectionService.sortedPanelsForDiagnostics([bottom, left, right], isRightToLeft: true) == [right, left, bottom])
    }

    @Test @MainActor func comicSyncIdentityIsStableAcrossComicIDs() {
        let first = ComicBook(
            title: "Chapter 1",
            bookmarkData: Data(),
            totalPages: 20,
            libraryPath: "/private/device-a/MReader/Series/Chapter 1.cbz"
        )
        var second = first
        second.id = UUID()
        second.libraryPath = "/private/device-b/MReader/Series/Chapter 1.cbz"

        #expect(ComicSyncIdentity.value(for: first) == ComicSyncIdentity.value(for: second))
    }

    @Test func offlineComicRecordRoundTrips() throws {
        let record = OfflineComicRecord(
            comicID: UUID(),
            sourceID: UUID(),
            sourceTypeRaw: ComicSourceType.komga.rawValue,
            remoteID: "book-42",
            pageCount: 128,
            fileName: nil,
            completedAt: Date(timeIntervalSince1970: 1234)
        )
        let decoded = try JSONDecoder().decode(OfflineComicRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded.comicID == record.comicID)
        #expect(decoded.remoteID == "book-42")
        #expect(decoded.pageCount == 128)
    }

    @Test func continuousPrefetchFollowsScrollDirectionWithinBounds() {
        let down = ReaderPrefetchPolicy.pageIndices(
            currentPageIndex: 5,
            pageCount: 20,
            readingDirection: .rightToLeft,
            readingMode: .continuousScroll,
            scrollDirection: 1,
            forwardCount: 3,
            backwardCount: 1,
            includesCurrentPage: true
        )
        let up = ReaderPrefetchPolicy.pageIndices(
            currentPageIndex: 1,
            pageCount: 4,
            readingDirection: .leftToRight,
            readingMode: .continuousScroll,
            scrollDirection: -1,
            forwardCount: 3,
            backwardCount: 1,
            includesCurrentPage: false
        )

        #expect(down == [5, 6, 7, 8, 4])
        #expect(up == [0, 2])
    }

}

private actor LibrarySyncProbe {
    private(set) var invocationScopes: [LibrarySyncScope] = []

    var invocationCount: Int {
        invocationScopes.count
    }

    func record(_ scope: LibrarySyncScope) {
        invocationScopes.append(scope)
    }

    // MARK: - 代码审查回归测试

    @Test func opdsAuthorizationNotForwardedToCrossOriginHost() {
        // OPDS feed 可能给出指向第三方域名的 cover/acquisition URL：
        // 同源（scheme+host+port 一致）才转发凭据，跨域绝不携带 Authorization。
        #expect(
            OPDSAuthorizationPolicy.shouldForward(
                sourceBaseURL: "https://my-komga.example.com",
                to: URL(string: "https://my-komga.example.com/book.cbz")!
            )
        )
        #expect(
            OPDSAuthorizationPolicy.shouldForward(
                sourceBaseURL: "https://my-komga.example.com",
                to: URL(string: "https://evil.example.com/book.cbz")!
            ) == false
        )
        #expect(
            OPDSAuthorizationPolicy.shouldForward(
                sourceBaseURL: "http://my-komga.example.com:8080",
                to: URL(string: "http://my-komga.example.com/book.cbz")!
            ) == false
        )
        #expect(
            OPDSAuthorizationPolicy.shouldForward(
                sourceBaseURL: "http://my-komga.example.com:8080",
                to: URL(string: "http://my-komga.example.com:8080/book.cbz")!
            )
        )
        #expect(
            OPDSAuthorizationPolicy.shouldForward(
                sourceBaseURL: "https://my-komga.example.com",
                to: URL(string: "http://my-komga.example.com/book.cbz")!
            ) == false
        )
    }

    @Test func readingProgressMergePreservesBackwardReRead() {
        // Komga 之前记录到 300 页，用户在本地重读到 50 页（updatedAt 更新）。
        // 合并必须保留 50 作为当前阅读位置，而不是 max(300, 50) = 300。
        let existing = ComicBook(
            title: "test",
            bookmarkData: Data(),
            totalPages: 400,
            currentPageIndex: 50,
            furthestPageIndex: 300,
            progressUpdatedAt: Date(timeIntervalSince1970: 2_000)
        )
        let incoming = ComicBook(
            title: "test",
            bookmarkData: Data(),
            totalPages: 400,
            currentPageIndex: 300,
            furthestPageIndex: 300,
            progressUpdatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let resolution = ReadingProgressMergePolicy.resolve(
            existing: existing,
            incoming: incoming,
            totalPages: 400
        )
        #expect(resolution.currentPageIndex == 50)
        #expect(resolution.furthestPageIndex == 300)
    }

    @Test func readingProgressMergeTakesNewerRemoteWhenAhead() {
        // 反向场景：远端更新晚于本地且更靠后时，当前页取远端位置。
        let existing = ComicBook(
            title: "test",
            bookmarkData: Data(),
            totalPages: 400,
            currentPageIndex: 50,
            furthestPageIndex: 300,
            progressUpdatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let incoming = ComicBook(
            title: "test",
            bookmarkData: Data(),
            totalPages: 400,
            currentPageIndex: 320,
            furthestPageIndex: 320,
            progressUpdatedAt: Date(timeIntervalSince1970: 2_000)
        )
        let resolution = ReadingProgressMergePolicy.resolve(
            existing: existing,
            incoming: incoming,
            totalPages: 400
        )
        #expect(resolution.currentPageIndex == 320)
        #expect(resolution.furthestPageIndex == 320)
    }

    @Test func ocrCoordinateMapperOriginalDoesNotUpscale() {
        // “原始尺寸”语义：小图 1:1（1 image pixel = 1 point），不再等同 fitScreen。
        let transform = OCRCoordinateMapper.displayTransform(
            sourcePixelSize: CGSize(width: 400, height: 300),
            containerSize: CGSize(width: 1_000, height: 1_000),
            fitMode: .original
        )
        #expect(transform.imageRect.width == 400)
        #expect(transform.imageRect.height == 300)

        // 大图则等比缩小到容器内，而不是溢出
        let large = OCRCoordinateMapper.displayTransform(
            sourcePixelSize: CGSize(width: 2_000, height: 4_000),
            containerSize: CGSize(width: 1_000, height: 1_000),
            fitMode: .original
        )
        #expect(large.imageRect.width == 500)
        #expect(large.imageRect.height == 1_000)
    }

    @Test func settingsBackupPlainEncodeRefusesCredentials() {
        // 明文设置备份不允许携带任何 API Key / 凭据；带凭据必须走加密。
        let backup = MReaderSettingsBackup(
            openAIAPIKey: "sk-test",
            openAIBaseURL: "https://api.openai.com/v1",
            openAIModel: "gpt-4o-mini",
            translationTargetLanguage: "中文",
            isHapticFeedbackEnabled: true,
            containsCredentials: true
        )
        #expect(throws: (any Error).self) {
            _ = try SettingsBackupCodec.encodePlain(backup)
        }

        // 不带凭据的备份可以明文编码
        let plain = MReaderSettingsBackup(
            openAIAPIKey: nil,
            openAIBaseURL: "https://api.openai.com/v1",
            openAIModel: "gpt-4o-mini",
            translationTargetLanguage: "中文",
            isHapticFeedbackEnabled: true,
            containsCredentials: false
        )
        #expect((try? SettingsBackupCodec.encodePlain(plain)) != nil)
    }

    // MARK: - 第二份审查报告回归测试（源语言 + 模型拆分）

    @Test func legacySelectedModelMigratesToBothRoles() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "name": "旧接口",
          "baseURL": "https://example.com/v1",
          "models": ["old-model"],
          "selectedModel": "old-model",
          "createdAt": 1000,
          "updatedAt": 1000
        }
        """
        let profile = try JSONDecoder().decode(
            AIProviderProfile.self,
            from: Data(json.utf8)
        )
        #expect(profile.selectedTextModel == "old-model")
        #expect(profile.selectedVisionModel == "old-model")
    }

    @Test @MainActor func replaceProfilesWithEmptyListClearsActiveID() throws {
        let suiteName = "ReplaceProfilesClearTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AIProviderStore(defaults: defaults, credentials: InMemoryAICredentialStore())
        let profile = AIProviderProfile.normalized(
            name: "接口",
            baseURL: "https://a.example/v1",
            modelsText: "model-a",
            selectedTextModel: "model-a",
            selectedVisionModel: "model-a"
        )
        try store.save(profile: profile, apiKey: "k")
        store.setActiveProfile(id: profile.id)
        #expect(store.activeProfileID() == profile.id)

        try store.replaceProfiles([], activeProfileID: profile.id)
        #expect(store.activeProfileID() == nil)
    }

    @Test func translationSourceLanguageDefaultsToAutomatic() {
        let comic = ComicBook(title: "t", bookmarkData: Data(), totalPages: 1)
        #expect(comic.translationSourceLanguage == .automatic)
    }

    @Test func translationSourceResolverUsesManualPreferenceFirst() {
        let decision = TranslationSourceResolver.resolve(
            preference: .english,
            blocks: [TextBlock(text: "No!", boundingBox: .zero, confidence: 0.9, ocrSource: "original:en")],
            previousStableLanguage: nil
        )
        #expect(decision?.languageCode == "en")
        #expect(decision?.confidence == 1)
    }

    @Test func translationSourceResolverFallsBackToPreviousWhenUncertain() {
        let decision = TranslationSourceResolver.resolve(
            preference: .automatic,
            blocks: [],
            previousStableLanguage: "ja"
        )
        #expect(decision?.languageCode == "ja")
    }

    @Test func translationSourceResolverReturnsNilWhenUnknownAndNoPrevious() {
        let decision = TranslationSourceResolver.resolve(
            preference: .automatic,
            blocks: [],
            previousStableLanguage: nil
        )
        #expect(decision == nil)
    }

    @Test func translationOutputValidatorPageLevelRejectsDifferentLatinLanguage() {
        // 目标英语：整页译文若是清晰的其它拉丁语言（法语），应判定不兼容
        let french = "Bonjour, comment allez-vous aujourd'hui? Je vais tres bien, merci beaucoup."
        #expect(
            TranslationOutputValidator.pageIsCompatible(
                [french],
                target: .english
            ) == false
        )
        let english = "Hello, how are you doing today? I am doing very well, thank you."
        #expect(
            TranslationOutputValidator.pageIsCompatible(
                [english],
                target: .english
            )
        )
    }

    @Test func translationPageCacheKeyTracksModelRoles() {
        // 纯 OCR 翻译：只依赖 textModel；visionModel 变化不应改变缓存 key
        let ocrA = makeTestPageRequest(mode: .ocr, textModel: "text-a", visionModel: "vision-a", visualVerify: false)
        let ocrB = makeTestPageRequest(mode: .ocr, textModel: "text-a", visionModel: "vision-b", visualVerify: false)
        #expect(ocrA.cacheKey == ocrB.cacheKey)

        let ocrC = makeTestPageRequest(mode: .ocr, textModel: "text-b", visionModel: "vision-a", visualVerify: false)
        #expect(ocrA.cacheKey != ocrC.cacheKey)

        // 开启视觉复核：visionModel 变化必须使缓存 key 变化
        let verifyA = makeTestPageRequest(mode: .ocr, textModel: "text-a", visionModel: "vision-a", visualVerify: true)
        let verifyB = makeTestPageRequest(mode: .ocr, textModel: "text-a", visionModel: "vision-b", visualVerify: true)
        #expect(verifyA.cacheKey != verifyB.cacheKey)

        // Vision 模式：visionModel 与 textModel 都进入缓存 key
        let visionA = makeTestPageRequest(mode: .vision, textModel: "text-a", visionModel: "vision-a", visualVerify: false)
        let visionB = makeTestPageRequest(mode: .vision, textModel: "text-a", visionModel: "vision-b", visualVerify: false)
        #expect(visionA.cacheKey != visionB.cacheKey)
        let visionC = makeTestPageRequest(mode: .vision, textModel: "text-b", visionModel: "vision-a", visualVerify: false)
        #expect(visionA.cacheKey != visionC.cacheKey)
    }
}

private func makeTestPageRequest(
    mode: AITranslationMode,
    textModel: String,
    visionModel: String,
    visualVerify: Bool
) -> AITranslationPageRequest {
    AITranslationPageRequest(
        pageURL: URL(fileURLWithPath: "/tmp/page.png"),
        image: UIImage(),
        mode: mode,
        configuration: AIActiveConfiguration(
            profileID: UUID(),
            profileName: "p",
            baseURL: "https://example.com/v1",
            apiKey: "k",
            textModel: textModel,
            visionModel: visionModel
        ),
        target: .simplifiedChinese,
        translationPromptTemplate: "t",
        visionPromptTemplate: "v",
        isRightToLeft: false,
        minimumTextHeight: 0.002,
        ocrRecognitionMode: .adaptive,
        safeAreaInset: 0,
        usesVisualOCRVerification: visualVerify,
        viewportAspect: 1.5,
        sourceLanguagePreference: nil
    )
}

@MainActor
private final class InMemoryAICredentialStore: AICredentialStoring {
    private var values: [UUID: String] = [:]

    func apiKey(for profileID: UUID) -> String? {
        values[profileID]
    }

    func saveAPIKey(_ apiKey: String, for profileID: UUID) throws {
        values[profileID] = apiKey
    }

    func removeAPIKey(for profileID: UUID) {
        values[profileID] = nil
    }
}
