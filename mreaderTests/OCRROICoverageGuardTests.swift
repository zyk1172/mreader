import CoreGraphics
import Testing
@testable import mreader

@Suite(.serialized)
@MainActor
struct OCRROICoverageGuardTests {
    @Test func noDetectorROIsWithTextEvidenceFallsBackToFullPage() {
        let locator = fiveBlocks()
        let decision = OCRROICoverageGuard.evaluate(
            detectorRegions: [],
            preliminaryBlocks: [],
            locatorBlocks: locator,
            reference: nil
        )
        #expect(decision.level == .fullPage)
        #expect(decision.reason == .missingDetectorCoverage)
        #expect(decision.uncoveredBlockCount == 5)
    }

    @Test func fiveOfFiveCoveredStaysROIOnly() {
        let locator = fiveBlocks()
        let detector = locator.map { padded($0.boundingBox) }
        let decision = OCRROICoverageGuard.evaluate(
            detectorRegions: detector,
            preliminaryBlocks: locator,
            locatorBlocks: locator,
            reference: nil
        )
        #expect(decision.level == .roiOnly)
        #expect(decision.reason == .complete)
        #expect(decision.uncoveredBlockCount == 0)
    }

    @Test func twoOfFiveCoveredEscalatesToFullPage() {
        let locator = fiveBlocks()
        let detector = locator.prefix(2).map { padded($0.boundingBox) }
        let decision = OCRROICoverageGuard.evaluate(
            detectorRegions: detector,
            preliminaryBlocks: Array(locator.prefix(2)),
            locatorBlocks: locator,
            reference: nil
        )
        #expect(decision.level == .fullPage)
        #expect(decision.reason == .largeGeometricGap)
        #expect(decision.uncoveredBlockCount == 3)
    }

    @Test func detectorFalsePositivesDoNotForceRecoveryWhenRealTextIsCovered() {
        let locator = fiveBlocks()
        var detector = locator.map { padded($0.boundingBox) }
        detector.append(CGRect(x: 0.02, y: 0.82, width: 0.20, height: 0.10))
        detector.append(CGRect(x: 0.74, y: 0.72, width: 0.18, height: 0.12))
        let decision = OCRROICoverageGuard.evaluate(
            detectorRegions: detector,
            preliminaryBlocks: locator,
            locatorBlocks: locator,
            reference: nil
        )
        #expect(decision.level == .roiOnly)
        #expect(decision.uncoveredBlockCount == 0)
    }

    @Test func oneMissedJapaneseVerticalColumnUsesPartialRescan() {
        let columns = [
            block("これは", x: 0.72, y: 0.14, width: 0.035, height: 0.24, orientation: .vertical),
            block("テスト", x: 0.64, y: 0.15, width: 0.035, height: 0.22, orientation: .vertical),
            block("です", x: 0.56, y: 0.16, width: 0.035, height: 0.18, orientation: .vertical)
        ]
        let decision = OCRROICoverageGuard.evaluate(
            detectorRegions: columns.prefix(2).map { padded($0.boundingBox) },
            preliminaryBlocks: Array(columns.prefix(2)),
            locatorBlocks: columns,
            reference: nil
        )
        #expect(decision.level == .partialRescan)
        #expect(decision.reason == .smallGeometricGap)
        #expect(decision.recoveryRegions.count == 1)
        #expect(decision.recoveryRegions[0].contains(CGPoint(x: columns[2].boundingBox.midX, y: columns[2].boundingBox.midY)))
    }

    @Test func lowContrastCharacterDeficitUsesFullPageFallback() {
        let weakLocator = block(
            "薄い文字",
            x: 0.52,
            y: 0.28,
            width: 0.12,
            height: 0.08,
            confidence: 0.10
        )
        let reference = AppleOCRReference(
            transcript: "これは薄い文字ですがページには十分な文字があります",
            characterCount: 23,
            kanaCount: 12,
            hanCount: 9,
            hangulCount: 0,
            latinCount: 0,
            detectedLanguage: "ja"
        )
        let decision = OCRROICoverageGuard.evaluate(
            detectorRegions: [padded(weakLocator.boundingBox)],
            preliminaryBlocks: [],
            locatorBlocks: [weakLocator],
            reference: reference
        )
        #expect(decision.level == .fullPage)
        #expect(decision.reason == .characterDeficit)
    }

    @Test func longStripSingleMissKeepsRecoveryLocal() {
        let blocks = [
            block("一", x: 0.35, y: 0.06, width: 0.18, height: 0.04),
            block("二", x: 0.35, y: 0.28, width: 0.18, height: 0.04),
            block("三", x: 0.35, y: 0.50, width: 0.18, height: 0.04),
            block("四", x: 0.35, y: 0.78, width: 0.18, height: 0.04)
        ]
        let decision = OCRROICoverageGuard.evaluate(
            detectorRegions: blocks.prefix(3).map { padded($0.boundingBox) },
            preliminaryBlocks: Array(blocks.prefix(3)),
            locatorBlocks: blocks,
            reference: nil
        )
        #expect(decision.level == .partialRescan)
        #expect(decision.recoveryRegions.count == 1)
        #expect(decision.recoveryRegions[0].minY > 0.70)
        #expect(MangaPageCoordinateSpace.area(decision.recoveryRegions[0]) < 0.05)
    }

    @Test func textFreePageDoesNotInventRecoveryWork() {
        let decision = OCRROICoverageGuard.evaluate(
            detectorRegions: [CGRect(x: 0.2, y: 0.2, width: 0.12, height: 0.08)],
            preliminaryBlocks: [],
            locatorBlocks: [],
            reference: nil
        )
        #expect(decision.level == .roiOnly)
        #expect(decision.reason == .noTextEvidence)
        #expect(decision.recoveryRegions.isEmpty)
    }

    @Test func partialRescanCoordinatesMapBackIntoWholePageSpace() {
        let local = TextBlock(
            text: "mapped",
            boundingBox: CGRect(x: 0.20, y: 0.10, width: 0.40, height: 0.20),
            confidence: 0.9,
            ocrSource: "original:en",
            estimatedFontScale: 0.10,
            polygon: [CGPoint(x: 0.2, y: 0.1), CGPoint(x: 0.6, y: 0.3)],
            textOrientation: .horizontal
        )
        let crop = CGRect(x: 0.10, y: 0.60, width: 0.50, height: 0.20)
        let mapped = OCRROICoverageRecognizer.remappedForDiagnostics(local, from: crop)
        #expect(abs(mapped.boundingBox.minX - 0.20) < 0.0001)
        #expect(abs(mapped.boundingBox.minY - 0.62) < 0.0001)
        #expect(abs(mapped.boundingBox.width - 0.20) < 0.0001)
        #expect(abs(mapped.boundingBox.height - 0.04) < 0.0001)
        #expect(abs(mapped.estimatedFontScale - 0.02) < 0.0001)
        #expect(mapped.ocrSource.hasPrefix("roi-recovery:"))
        #expect(abs((mapped.polygon.first?.x ?? 0) - 0.20) < 0.0001)
        #expect(abs((mapped.polygon.first?.y ?? 0) - 0.62) < 0.0001)
    }

    private func fiveBlocks() -> [TextBlock] {
        [
            block("one", x: 0.08, y: 0.10, width: 0.16, height: 0.06),
            block("two", x: 0.58, y: 0.12, width: 0.16, height: 0.06),
            block("three", x: 0.10, y: 0.38, width: 0.18, height: 0.06),
            block("four", x: 0.56, y: 0.42, width: 0.18, height: 0.06),
            block("five", x: 0.30, y: 0.68, width: 0.18, height: 0.06)
        ]
    }

    private func block(
        _ text: String,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
        confidence: Double = 0.90,
        orientation: TextOrientation = .horizontal
    ) -> TextBlock {
        TextBlock(
            text: text,
            boundingBox: CGRect(x: x, y: y, width: width, height: height),
            confidence: confidence,
            ocrSource: "coverage-locator",
            estimatedFontScale: Double(min(width, height)),
            textOrientation: orientation
        )
    }

    private func padded(_ rect: CGRect) -> CGRect {
        MangaPageCoordinateSpace.clampedNormalizedRect(
            rect.insetBy(dx: -0.012, dy: -0.012)
        )
    }
}
