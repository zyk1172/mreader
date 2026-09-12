import UIKit
import XCTest
@testable import mreader

final class TranslationComicIntegrationRegressionTests: XCTestCase {
    func testDisplayPolicyKeepsInPlaceOptInAndSoundEffectsAsAnnotations() {
        XCTAssertEqual(
            TranslationDisplayPolicy.mode(
                contentRole: .dialogue,
                hasReliableDetectedBubble: true,
                prefersInPlace: false
            ),
            .assistOverlay
        )
        XCTAssertEqual(
            TranslationDisplayPolicy.mode(
                contentRole: .dialogue,
                hasReliableDetectedBubble: true,
                prefersInPlace: true
            ),
            .inPlace
        )
        XCTAssertEqual(
            TranslationDisplayPolicy.mode(
                contentRole: .soundEffect,
                hasReliableDetectedBubble: true,
                prefersInPlace: true
            ),
            .annotation
        )
    }

    func testLayoutSafeRegionIsConstrainedByPhysicalBubbleWithoutBecomingBubbleEvidence() {
        let text = CGRect(x: 40, y: 40, width: 20, height: 12)
        let bubble = CGRect(x: 30, y: 25, width: 70, height: 55)
        let proposed = CGRect(x: 10, y: 10, width: 120, height: 100)
        let page = CGRect(x: 0, y: 0, width: 200, height: 200)

        let resolved = TranslationRegionPolicy.resolvedLayoutSafeRegion(
            sourceTextRegion: text,
            proposedSafeRegion: proposed,
            detectedBubble: bubble,
            pageBounds: page
        )

        XCTAssertEqual(resolved, bubble)
    }

    func testStandaloneSafeRegionDoesNotCreatePhysicalBubble() {
        let text = CGRect(x: 40, y: 40, width: 20, height: 12)
        let safe = CGRect(x: 34, y: 32, width: 42, height: 30)
        let resolved = TranslationRegionPolicy.resolvedLayoutSafeRegion(
            sourceTextRegion: text,
            proposedSafeRegion: safe,
            detectedBubble: nil,
            pageBounds: CGRect(x: 0, y: 0, width: 200, height: 200)
        )
        XCTAssertEqual(resolved, safe)
    }

    func testDisconnectedSafeRegionIsRejected() {
        let resolved = TranslationRegionPolicy.resolvedLayoutSafeRegion(
            sourceTextRegion: CGRect(x: 10, y: 10, width: 20, height: 12),
            proposedSafeRegion: CGRect(x: 120, y: 120, width: 40, height: 30),
            detectedBubble: nil,
            pageBounds: CGRect(x: 0, y: 0, width: 200, height: 200)
        )
        XCTAssertNil(resolved)
    }

    func testStrictVisionSoundEffectCanOmitPhysicalBubble() throws {
        let json = #"{"coordinateSpace":"normalized","items":[{"sourceText":"ドン","translation":"咚","textBox":{"x":0.20,"y":0.30,"width":0.12,"height":0.08},"layoutSafeRegion":{"x":0.18,"y":0.28,"width":0.18,"height":0.14},"confidence":0.95,"classification":"soundEffect"}]}"#
        let blocks = try AITranslator.parseVisionTranslationBlocksForDiagnostics(
            from: json,
            inputPixelSize: CGSize(width: 1200, height: 1800),
            requiresTextBox: true,
            target: .simplifiedChinese
        )
        let block = try XCTUnwrap(blocks.first)
        XCTAssertNil(block.detectedBubble)
        XCTAssertNotNil(block.effectiveLayoutSafeRegion)
        XCTAssertEqual(block.translationContentRole, .soundEffect)
    }

    func testStrictVisionRequiresIndependentLayoutSafeRegion() {
        let json = #"{"coordinateSpace":"normalized","items":[{"sourceText":"こんにちは","translation":"你好","textBox":{"x":0.20,"y":0.30,"width":0.12,"height":0.08},"bubbleBox":{"x":0.18,"y":0.28,"width":0.18,"height":0.14},"confidence":0.95,"classification":"dialogue"}]}"#
        XCTAssertThrowsError(
            try AITranslator.parseVisionTranslationBlocksForDiagnostics(
                from: json,
                inputPixelSize: CGSize(width: 1200, height: 1800),
                requiresTextBox: true,
                target: .simplifiedChinese
            )
        )
    }

    @MainActor
    func testVisionSliceBoundariesAreStableAcrossViewportAspect() {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 400, height: 1600),
            format: format
        ).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 1600))
            UIColor.black.setFill()
            context.fill(CGRect(x: 20, y: 250, width: 360, height: 100))
            context.fill(CGRect(x: 20, y: 850, width: 360, height: 100))
            context.fill(CGRect(x: 20, y: 1300, width: 360, height: 80))
        }

        let compact = AITranslator.visionSliceRectsForDiagnostics(image, viewportAspect: 1.25)
        let tall = AITranslator.visionSliceRectsForDiagnostics(image, viewportAspect: 2.6)

        XCTAssertGreaterThan(compact.count, 1)
        XCTAssertEqual(compact, tall)
        XCTAssertEqual(compact.first?.minY, 0)
        XCTAssertEqual(compact.last?.maxY, 1, accuracy: 0.0001)
    }
}
