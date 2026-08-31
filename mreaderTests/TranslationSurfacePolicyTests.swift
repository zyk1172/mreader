import CoreGraphics
import Testing
import UIKit
@testable import mreader

@Suite
@MainActor
struct TranslationSurfacePolicyTests {
    private static let imageBounds = CGRect(x: 0, y: 0, width: 390, height: 780)

    private static var transform: OCRDisplayTransform {
        OCRDisplayTransform(imageRect: imageBounds)
    }

    private static func normalized(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX / imageBounds.width,
            y: rect.minY / imageBounds.height,
            width: rect.width / imageBounds.width,
            height: rect.height / imageBounds.height
        )
    }

    private static func block(
        text: String = "译文",
        rect: CGRect,
        bubbleBox: CGRect? = nil,
        orientation: TextOrientation = .horizontal,
        layoutRole: TranslationLayoutRole = .dialogue
    ) -> TextBlock {
        TextBlock(
            text: text,
            boundingBox: normalized(rect),
            ocrSource: "vision",
            bubbleBox: bubbleBox.map(normalized),
            textOrientation: orientation,
            layoutRole: layoutRole
        )
    }

    @Test func noBubbleTextRendersBorderless() {
        let block = Self.block(
            text: "城市熟女。",
            rect: CGRect(x: 240, y: 120, width: 30, height: 400),
            orientation: .vertical
        )
        let textRect = OCRCoordinateMapper.displayRect(
            forNormalizedPageRect: block.boundingBox,
            using: Self.transform
        )

        #expect(
            OCRBubbleLayoutEngine.usableTranslationBubbleBounds(
                for: block,
                textRect: textRect,
                using: Self.transform
            ) == nil
        )
        #expect(
            OCRBubbleLayoutEngine.translationSurfaceStyle(
                for: block,
                textRect: textRect,
                using: Self.transform
            ) == .borderless
        )
        #expect(TranslationSurfacePolicy.surfaceStyle(hasReliableBubble: false) == .borderless)
        #expect(TranslationSurfaceStyle.borderless.drawsBackground == false)
        #expect(TranslationSurfaceStyle.borderless.backgroundOpacity == 0)
        #expect(TranslationSurfaceStyle.borderless.borderOpacity == 0)
    }

    @Test func detectedBubbleDrawsBackground() {
        let block = Self.block(
            text: "I knew it wouldn't be...",
            rect: CGRect(x: 150, y: 260, width: 70, height: 32),
            bubbleBox: CGRect(x: 125, y: 220, width: 120, height: 100)
        )
        let textRect = OCRCoordinateMapper.displayRect(
            forNormalizedPageRect: block.boundingBox,
            using: Self.transform
        )

        #expect(
            OCRBubbleLayoutEngine.usableTranslationBubbleBounds(
                for: block,
                textRect: textRect,
                using: Self.transform
            ) != nil
        )
        #expect(
            OCRBubbleLayoutEngine.translationSurfaceStyle(
                for: block,
                textRect: textRect,
                using: Self.transform
            ) == .detectedBubble
        )
        #expect(TranslationSurfacePolicy.surfaceStyle(hasReliableBubble: true) == .detectedBubble)
        #expect(TranslationSurfaceStyle.detectedBubble.drawsBackground)
    }

    @Test func invalidBubbleFallsBackToBorderless() {
        let block = Self.block(
            text: "Whole page",
            rect: CGRect(x: 150, y: 260, width: 70, height: 32),
            bubbleBox: CGRect(x: 0, y: 0, width: 390, height: 780)
        )
        let textRect = OCRCoordinateMapper.displayRect(
            forNormalizedPageRect: block.boundingBox,
            using: Self.transform
        )

        #expect(
            OCRBubbleLayoutEngine.translationSurfaceStyle(
                for: block,
                textRect: textRect,
                using: Self.transform
            ) == .borderless
        )
    }

    @Test func borderlessLayoutDoesNotInheritPathologicalOCRGeometry() {
        let sourceRect = CGRect(x: 150, y: 200, width: 90, height: 300)
        let layout = OCRBubbleLayoutEngine.anchoredTranslationLayout(
            text: "Hello there",
            sourceFontSize: 14,
            sourceRect: sourceRect,
            allowedBounds: CGRect(x: 120, y: 100, width: 200, height: 500),
            lineSpacing: 2,
            textOrientation: .horizontal,
            useSourceRectAsMinimumExtent: false
        )

        #expect(layout.rect.height < sourceRect.height)
        #expect(layout.rect.width < sourceRect.width)
    }

    @Test func detectedBubbleLayoutRetainsSourceExtent() {
        let sourceRect = CGRect(x: 150, y: 200, width: 90, height: 300)
        let layout = OCRBubbleLayoutEngine.anchoredTranslationLayout(
            text: "Hello there",
            sourceFontSize: 14,
            sourceRect: sourceRect,
            allowedBounds: CGRect(x: 120, y: 100, width: 200, height: 500),
            lineSpacing: 2,
            textOrientation: .horizontal,
            useSourceRectAsMinimumExtent: true
        )

        #expect(layout.rect.width >= sourceRect.width)
        #expect(layout.rect.height >= sourceRect.height)
    }

    @Test func lineBreaksInsideTranslatedTextDoNotCreateAdditionalSurface() {
        let choice = OCRBubbleLayoutEngine.preferredTranslationLayout(
            translation: "第一行\n第二行",
            translationLines: ["第一行", "第二行"],
            sourceFontSize: 16,
            sourceRect: CGRect(x: 120, y: 220, width: 80, height: 36),
            allowedBounds: CGRect(x: 80, y: 180, width: 180, height: 140),
            lineSpacing: 2,
            useSourceRectAsMinimumExtent: false
        )

        #expect(choice.text == "第一行\n第二行")
        #expect(
            TranslationSurfacePolicy.surfaceStyle(hasReliableBubble: false)
                == .borderless
        )
        #expect(!TranslationSurfaceStyle.borderless.drawsBackground)
    }

    @Test func borderlessFontDoesNotUseOCRBoxSize() {
        let requested = OCRBubbleLayoutEngine.requestedTranslationFontSize(
            hasReliableBubble: false,
            automaticFontSize: 300,
            borderlessFontSize: 18
        )

        #expect(requested == 18)
    }

    @Test func detectedBubbleAndBorderlessAreTheOnlySurfaceStates() {
        #expect(Set(TranslationSurfaceStyle.allCases) == [.detectedBubble, .borderless])
        #expect(
            TranslationSurfaceStyle.allCases.filter(\.drawsBackground)
                == [.detectedBubble]
        )
    }
}
