import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import mreader

@Suite(.serialized)
@MainActor
struct MangaVisionLayerTests {
    @Test func mangaBalloonGeometryCombinesVerticalColumnsIntoOneTranslationUnit() {
        let balloon = region(
            .balloon,
            x: 0.48,
            y: 0.16,
            width: 0.28,
            height: 0.42,
            confidence: 0.92
        )
        let analysis = MangaPageAnalysis(
            pageIdentifier: MangaPageIdentifier(
                scope: "balloon-test",
                pageIndex: 0,
                sourceFingerprint: "fixture"
            ),
            imageSize: CGSize(width: 1200, height: 1800),
            panels: [],
            texts: [],
            balloons: [balloon],
            modelIdentifier: "fixture",
            modelVersion: 3
        )
        let rightColumn = TextBlock(
            text: "これは",
            boundingBox: CGRect(x: 0.66, y: 0.22, width: 0.035, height: 0.22),
            confidence: 0.95,
            ocrSource: "original:ja",
            estimatedFontScale: 0.035,
            textOrientation: .vertical
        )
        let leftColumn = TextBlock(
            text: "テストです",
            boundingBox: CGRect(x: 0.57, y: 0.20, width: 0.035, height: 0.26),
            confidence: 0.94,
            ocrSource: "original:ja",
            estimatedFontScale: 0.035,
            textOrientation: .vertical
        )

        let enriched = MangaVisionOCRGeometry.applyingDetectedGeometry(
            to: [rightColumn, leftColumn],
            analysis: analysis
        )
        #expect(enriched.allSatisfy { $0.bubbleBox != nil })
        #expect(enriched.allSatisfy { $0.bubbleBox == balloon.normalizedRect })

        let segmentation = MangaTextSegmenter.segment(enriched, isRightToLeft: true)
        #expect(segmentation.lines.count == 2)
        #expect(segmentation.bubbles.count == 1)
        #expect(segmentation.bubbles[0].sourceLineCount == 2)
        #expect(segmentation.bubbles[0].bubbleBox == balloon.normalizedRect)
    }

    @Test func mangaBalloonContourFlowsIntoTranslationUnitAndSafeRegion() {
        let contourPoints = [
            CGPoint(x: 0.50, y: 0.18),
            CGPoint(x: 0.70, y: 0.18),
            CGPoint(x: 0.76, y: 0.34),
            CGPoint(x: 0.70, y: 0.54),
            CGPoint(x: 0.50, y: 0.54),
            CGPoint(x: 0.46, y: 0.34)
        ]
        let balloon = MangaVisionRegion(
            type: .balloon,
            normalizedRect: CGRect(x: 0.46, y: 0.18, width: 0.30, height: 0.36),
            confidence: 0.94,
            contour: MangaVisionContour(points: contourPoints)
        )
        let analysis = MangaPageAnalysis(
            pageIdentifier: MangaPageIdentifier(
                scope: "contour-test",
                pageIndex: 0,
                sourceFingerprint: "fixture"
            ),
            imageSize: CGSize(width: 1200, height: 1800),
            panels: [],
            texts: [],
            balloons: [balloon],
            modelIdentifier: "fixture",
            modelVersion: 3
        )
        let block = TextBlock(
            text: "輪郭を使う",
            boundingBox: CGRect(x: 0.57, y: 0.24, width: 0.06, height: 0.20),
            confidence: 0.96,
            ocrSource: "original:ja",
            estimatedFontScale: 0.04,
            textOrientation: .vertical
        )

        let enriched = MangaVisionOCRGeometry.applyingDetectedGeometry(
            to: [block],
            analysis: analysis
        )
        #expect(enriched[0].bubbleBox == balloon.normalizedRect)
        #expect(enriched[0].bubblePolygon == balloon.contour?.cgPoints)
        #expect((enriched[0].layoutSafeRegion?.width ?? 1) < balloon.normalizedRect.width)
        #expect((enriched[0].layoutSafeRegion?.height ?? 1) < balloon.normalizedRect.height)

        let segmentation = MangaTextSegmenter.segment(enriched, isRightToLeft: true)
        #expect(segmentation.bubbles.count == 1)
        #expect(segmentation.bubbles[0].bubblePolygon == balloon.contour?.cgPoints)
    }

    @Test func sharedTranslationPreparationReappliesVisionGeometryAfterReview() {
        let balloon = MangaVisionRegion(
            type: .balloon,
            normalizedRect: CGRect(x: 0.42, y: 0.12, width: 0.34, height: 0.40),
            confidence: 0.91,
            contour: MangaVisionContour(points: [
                CGPoint(x: 0.44, y: 0.18),
                CGPoint(x: 0.72, y: 0.18),
                CGPoint(x: 0.74, y: 0.46),
                CGPoint(x: 0.44, y: 0.46)
            ])
        )
        let analysis = MangaPageAnalysis(
            pageIdentifier: MangaPageIdentifier(
                scope: "shared-preparation",
                pageIndex: 2,
                sourceFingerprint: "fixture"
            ),
            imageSize: CGSize(width: 1000, height: 1600),
            panels: [],
            texts: [],
            balloons: [balloon],
            modelIdentifier: "fixture",
            modelVersion: 3
        )
        let local = TextBlock(
            text: "元のOCR",
            boundingBox: CGRect(x: 0.56, y: 0.22, width: 0.05, height: 0.18),
            confidence: 0.94,
            ocrSource: "original:ja",
            estimatedFontScale: 0.04,
            textOrientation: .vertical
        )
        let visuallyReviewed = TextBlock(
            id: local.id,
            text: "視覚復核後",
            boundingBox: local.boundingBox,
            confidence: 0.97,
            ocrSource: "visual-review",
            estimatedFontScale: local.estimatedFontScale,
            textOrientation: .vertical
        )
        let base = OCRPipelineResult(
            rawBlocks: [local],
            resolvedBlocks: [local],
            lineBlocks: [local],
            bubbleBlocks: [local],
            rejectedBlocks: [],
            detectedLanguage: "ja",
            quality: nil
        )

        let prepared = MangaVisionOCRTranslationPreparation.prepare(
            baseResult: base,
            candidateBlocks: [visuallyReviewed],
            analysis: analysis,
            safeAreaInset: 0,
            minimumTextHeight: 0.002,
            isRightToLeft: true
        )
        #expect(prepared.bubbleBlocks.count == 1)
        #expect(prepared.bubbleBlocks[0].text == "視覚復核後")
        #expect(prepared.bubbleBlocks[0].bubbleBox == balloon.normalizedRect)
        #expect(prepared.bubbleBlocks[0].bubblePolygon == balloon.contour?.cgPoints)
    }

    @Test func mangaTextRegionProvidesLayoutSafeRegionWithoutInventingBubble() {
        let textRegion = region(
            .text,
            x: 0.54,
            y: 0.18,
            width: 0.15,
            height: 0.28,
            confidence: 0.88
        )
        let analysis = MangaPageAnalysis(
            pageIdentifier: MangaPageIdentifier(
                scope: "safe-region-test",
                pageIndex: 0,
                sourceFingerprint: "fixture"
            ),
            imageSize: CGSize(width: 1200, height: 1800),
            panels: [],
            texts: [textRegion],
            balloons: [],
            modelIdentifier: "fixture",
            modelVersion: 3
        )
        let block = TextBlock(
            text: "小さい文字も残す",
            boundingBox: CGRect(x: 0.60, y: 0.23, width: 0.018, height: 0.17),
            confidence: 0.92,
            ocrSource: "original:ja",
            estimatedFontScale: 0.018,
            textOrientation: .vertical
        )

        let enriched = MangaVisionOCRGeometry.applyingDetectedGeometry(
            to: [block],
            analysis: analysis
        )
        #expect(enriched[0].bubbleBox == nil)
        #expect(enriched[0].layoutSafeRegion != nil)
        #expect(enriched[0].layoutSafeRegion?.contains(block.boundingBox) == true)
        #expect((enriched[0].layoutSafeRegion?.width ?? 0) > block.boundingBox.width)
    }

    @Test func mangaBalloonGeometryDoesNotOverwriteExistingVisualBubble() {
        let visualBubble = CGRect(x: 0.12, y: 0.12, width: 0.24, height: 0.20)
        let block = TextBlock(
            text: "already grouped",
            boundingBox: CGRect(x: 0.16, y: 0.16, width: 0.12, height: 0.05),
            confidence: 0.95,
            ocrSource: "visual-dialogue",
            bubbleBox: visualBubble,
            textOrientation: .horizontal
        )
        let analysis = MangaPageAnalysis(
            pageIdentifier: MangaPageIdentifier(
                scope: "visual-preserve",
                pageIndex: 0,
                sourceFingerprint: "fixture"
            ),
            imageSize: CGSize(width: 1000, height: 1600),
            panels: [],
            texts: [region(.text, x: 0.14, y: 0.14, width: 0.16, height: 0.08)],
            balloons: [region(.balloon, x: 0.10, y: 0.10, width: 0.30, height: 0.26)],
            modelIdentifier: "fixture",
            modelVersion: 3
        )

        let enriched = MangaVisionOCRGeometry.applyingDetectedGeometry(
            to: [block],
            analysis: analysis
        )
        #expect(enriched[0].bubbleBox == visualBubble)
    }

    @Test func scaleFitCoordinatesMapBackToOriginalPage() {
        let rect = MangaPageCoordinateSpace.sourceNormalizedRectFromScaleFitXYXY(
            x1: 160,
            y1: 0,
            x2: 480,
            y2: 640,
            inputSize: CGSize(width: 640, height: 640),
            sourceSize: CGSize(width: 320, height: 640)
        )
        #expect(abs(rect.minX) < 0.0001)
        #expect(abs(rect.minY) < 0.0001)
        #expect(abs(rect.width - 1) < 0.0001)
        #expect(abs(rect.height - 1) < 0.0001)
    }

    @Test func visionBottomLeftCoordinatesFlipIntoPageSpace() {
        let result = MangaPageCoordinateSpace.topLeftNormalizedRect(
            fromVisionRect: CGRect(x: 0.2, y: 0.1, width: 0.3, height: 0.25)
        )
        #expect(abs(result.minX - 0.2) < 0.0001)
        #expect(abs(result.minY - 0.65) < 0.0001)
        #expect(abs(result.width - 0.3) < 0.0001)
        #expect(abs(result.height - 0.25) < 0.0001)
    }

    @Test func normalizedRectClampNeverLeavesPage() {
        let result = MangaPageCoordinateSpace.clampedNormalizedRect(
            CGRect(x: -0.2, y: 0.8, width: 0.5, height: 0.5)
        )
        #expect(result.minX == 0)
        #expect(result.maxX <= 1)
        #expect(result.minY >= 0)
        #expect(result.maxY == 1)
    }

    @Test func sameTypeNMSKeepsHigherConfidenceButDoesNotMergeDifferentTypes() {
        let high = region(.text, x: 0.1, y: 0.1, width: 0.3, height: 0.2, confidence: 0.9)
        let low = region(.text, x: 0.11, y: 0.11, width: 0.29, height: 0.19, confidence: 0.5)
        let sfx = region(.onomatopoeia, x: 0.11, y: 0.11, width: 0.29, height: 0.19, confidence: 0.8)
        let result = MangaVisionRegionPostProcessor.deduplicated([low, sfx, high])
        #expect(result.count == 2)
        #expect(result.contains { $0.id == high.id })
        #expect(result.contains { $0.id == sfx.id })
    }

    @Test func textROIPaddingDeduplicatesAndClampsAtPageEdges() {
        let first = region(.text, x: 0.0, y: 0.0, width: 0.20, height: 0.10, confidence: 0.9)
        let duplicate = region(.text, x: 0.01, y: 0.005, width: 0.19, height: 0.095, confidence: 0.7)
        let rois = MangaVisionTextROIPlanner.recognitionRegions(from: [duplicate, first])
        #expect(rois.count == 1)
        #expect(rois[0].minX == 0)
        #expect(rois[0].minY == 0)
        #expect(rois[0].maxX <= 1)
        #expect(rois[0].maxY <= 1)
        #expect(rois[0].width > first.normalizedRect.width)
    }

    @Test func noDetectedTextLeavesROIsEmptyForFullPageOCRFallback() {
        #expect(MangaVisionTextROIPlanner.recognitionRegions(from: []).isEmpty)
    }

    @Test func textOwnershipUsesContainingPanelAndAvoidsCrossPanelGuessing() {
        let left = region(.panel, x: 0.05, y: 0.05, width: 0.40, height: 0.80)
        let right = region(.panel, x: 0.55, y: 0.05, width: 0.40, height: 0.80)
        let inside = MangaSemanticAnalyzer.owningPanel(
            for: CGRect(x: 0.62, y: 0.20, width: 0.15, height: 0.08),
            panels: [left, right]
        )
        let gutter = MangaSemanticAnalyzer.owningPanel(
            for: CGRect(x: 0.47, y: 0.30, width: 0.06, height: 0.06),
            panels: [left, right]
        )
        #expect(inside?.id == right.id)
        #expect(gutter == nil)
    }

    @Test func textReadingOrderRespectsRTLAndLTR() {
        let left = region(.text, x: 0.10, y: 0.10, width: 0.20, height: 0.08)
        let right = region(.text, x: 0.65, y: 0.10, width: 0.20, height: 0.08)
        let lower = region(.text, x: 0.60, y: 0.45, width: 0.20, height: 0.08)
        let rtl = MangaSemanticAnalyzer.orderedTextRegions([left, lower, right], isRightToLeft: true)
        let ltr = MangaSemanticAnalyzer.orderedTextRegions([left, lower, right], isRightToLeft: false)
        #expect(rtl.map(\.id) == [right.id, left.id, lower.id])
        #expect(ltr.map(\.id) == [left.id, right.id, lower.id])
    }

    @Test func onomatopoeiaAndTextBothDriveOCRRegionPlanning() {
        let text = region(.text, x: 0.10, y: 0.10, width: 0.20, height: 0.08, confidence: 0.90)
        let sfx = region(.onomatopoeia, x: 0.60, y: 0.30, width: 0.16, height: 0.12, confidence: 0.90)
        let rois = MangaVisionTextROIPlanner.recognitionRegions(from: [text, sfx])

        #expect(rois.count == 2)
        #expect(rois.contains { $0.contains(CGPoint(x: text.normalizedRect.midX, y: text.normalizedRect.midY)) })
        #expect(rois.contains { $0.contains(CGPoint(x: sfx.normalizedRect.midX, y: sfx.normalizedRect.midY)) })
    }

    @Test func semanticPageAssignsTextAndOnomatopoeiaWithoutPersonHints() {
        let panel = region(.panel, x: 0.05, y: 0.05, width: 0.90, height: 0.90)
        let text = region(.text, x: 0.15, y: 0.20, width: 0.20, height: 0.08)
        let sfx = region(.onomatopoeia, x: 0.60, y: 0.50, width: 0.18, height: 0.12)
        let analysis = MangaPageAnalysis(
            pageIdentifier: MangaPageIdentifier(scope: "semantic-layout4", pageIndex: 0, sourceFingerprint: "fixture"),
            imageSize: CGSize(width: 1000, height: 1500),
            panels: [panel],
            texts: [text],
            balloons: [],
            onomatopoeias: [sfx],
            modelIdentifier: MangaLayout4V1Provider.modelIdentifier,
            modelVersion: 1
        )

        let semantic = MangaSemanticAnalyzer.makeSemanticPage(from: analysis, isRightToLeft: true)

        #expect(semantic.panels.count == 1)
        #expect(Set(semantic.panels[0].texts.map { $0.region.id }) == Set([text.id, sfx.id]))
        #expect(semantic.unassignedTexts.isEmpty)
    }

    @Test func samePageAnalysisUsesProviderOnlyOnce() async throws {
        let provider = FakeMangaVisionProvider(modelVersion: 1)
        let directory = temporaryCacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = MangaVisionService(provider: provider, cacheDirectory: directory)
        let image = makeImage()
        let url = URL(fileURLWithPath: "/tmp/mreader-manga-vision-cache-page.png")
        let comicID = UUID()

        _ = try await service.analysis(
            comicID: comicID, pageIndex: 0, pageURL: url, image: image
        )
        _ = try await service.analysis(
            comicID: comicID, pageIndex: 0, pageURL: url, image: image
        )
        #expect(await provider.calls() == 1)
    }

    @Test func modelVersionChangeInvalidatesDiskAnalysisCache() async throws {
        let directory = temporaryCacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = makeImage()
        let url = URL(fileURLWithPath: "/tmp/mreader-manga-vision-version-page.png")
        let comicID = UUID()

        let v1 = FakeMangaVisionProvider(modelVersion: 1)
        let first = MangaVisionService(provider: v1, cacheDirectory: directory)
        _ = try await first.analysis(
            comicID: comicID, pageIndex: 2, pageURL: url, image: image
        )
        #expect(await v1.calls() == 1)

        let v2 = FakeMangaVisionProvider(modelVersion: 2)
        let second = MangaVisionService(provider: v2, cacheDirectory: directory)
        _ = try await second.analysis(
            comicID: comicID, pageIndex: 2, pageURL: url, image: image
        )
        #expect(await v2.calls() == 1)
    }

    private func region(
        _ type: MangaRegionType,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
        confidence: Float = 0.9
    ) -> MangaVisionRegion {
        MangaVisionRegion(
            type: type,
            normalizedRect: CGRect(x: x, y: y, width: width, height: height),
            confidence: confidence
        )
    }

    private func makeImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 64, height: 96)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 96))
        }
    }

    private func temporaryCacheDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MangaVisionTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor FakeMangaVisionProvider: MangaVisionProvider {
    private let version: Int
    private var callCount = 0

    init(modelVersion: Int) {
        version = modelVersion
    }

    var descriptor: MangaVisionProviderDescriptor {
        get async {
            MangaVisionProviderDescriptor(
                modelIdentifier: "fake-manga-vision",
                modelVersion: version,
                inputSize: CGSize(width: 64, height: 64),
                supportedRegionTypes: Set(MangaRegionType.allCases)
            )
        }
    }

    func analyzePage(
        image: CGImage,
        sourceImageSize: CGSize,
        pageIdentifier: MangaPageIdentifier
    ) async throws -> MangaPageAnalysis {
        _ = image
        callCount += 1
        return MangaPageAnalysis(
            pageIdentifier: pageIdentifier,
            imageSize: sourceImageSize,
            panels: [
                MangaVisionRegion(
                    type: .panel,
                    normalizedRect: CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9),
                    confidence: 0.9
                )
            ],
            texts: [],
            balloons: [],
            modelIdentifier: "fake-manga-vision",
            modelVersion: version
        )
    }

    func calls() -> Int { callCount }
}
