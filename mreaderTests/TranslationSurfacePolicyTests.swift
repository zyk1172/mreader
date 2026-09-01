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

    @Test func noBubbleShortTranslationUsesMeasuredCard() {
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
            ) == .measuredText
        )
        #expect(TranslationSurfacePolicy.surfaceStyle(hasReliableBubble: false) == .measuredText)
        #expect(TranslationSurfaceStyle.measuredText.drawsBackground)
        #expect(TranslationSurfaceStyle.measuredText.backgroundOpacity > 0)
        #expect(TranslationSurfaceStyle.measuredText.borderOpacity > 0)

        let layout = OCRBubbleLayoutEngine.anchoredTranslationLayout(
            text: "城市熟女。",
            sourceFontSize: 20,
            sourceRect: textRect,
            allowedBounds: Self.imageBounds,
            lineSpacing: 2,
            textOrientation: .vertical,
            geometryStrategy: .measuredText
        )
        #expect(layout.contentPadding > 0)
        #expect(layout.rect.height < 200)
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
        #expect(TranslationSurfaceStyle.detectedBubble.borderOpacity > 0)
    }

    @Test func invalidBubbleFallsBackToMeasuredText() {
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
            ) == .measuredText
        )
    }

    @Test func noBubblePathologicalTallOCRDoesNotEnlargeCard() {
        let sourceRect = CGRect(x: 150, y: 200, width: 90, height: 300)
        let normalSourceRect = CGRect(x: 185, y: 340, width: 30, height: 20)
        let allowedBounds = CGRect(x: 120, y: 100, width: 200, height: 500)
        let layout = OCRBubbleLayoutEngine.anchoredTranslationLayout(
            text: "Hello there",
            sourceFontSize: 14,
            sourceRect: sourceRect,
            allowedBounds: allowedBounds,
            lineSpacing: 2,
            textOrientation: .horizontal,
            geometryStrategy: .measuredText
        )
        let normalLayout = OCRBubbleLayoutEngine.anchoredTranslationLayout(
            text: "Hello there",
            sourceFontSize: 14,
            sourceRect: normalSourceRect,
            allowedBounds: allowedBounds,
            lineSpacing: 2,
            textOrientation: .horizontal,
            geometryStrategy: .measuredText
        )

        #expect(layout.rect.height < 200)
        #expect(layout.rect.width < 160)
        #expect(abs(layout.rect.width - normalLayout.rect.width) < 0.001)
        #expect(abs(layout.rect.height - normalLayout.rect.height) < 0.001)
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
            geometryStrategy: .detectedBubble
        )

        #expect(layout.rect.width >= sourceRect.width)
        #expect(layout.rect.height >= sourceRect.height)
        #expect(layout.contentPadding == TranslationLayoutMetrics.contentPadding)
    }

    @Test func noBubbleMultilineCardWrapsActualTranslation() {
        let choice = OCRBubbleLayoutEngine.preferredTranslationLayout(
            translation: "第一行\n第二行",
            translationLines: ["第一行", "第二行"],
            sourceFontSize: 16,
            sourceRect: CGRect(x: 120, y: 220, width: 80, height: 36),
            allowedBounds: CGRect(x: 80, y: 180, width: 180, height: 140),
            lineSpacing: 2,
            geometryStrategy: .measuredText
        )

        #expect(choice.text == "第一行\n第二行")
        #expect(
            TranslationSurfacePolicy.surfaceStyle(hasReliableBubble: false)
                == .measuredText
        )
        #expect(TranslationSurfaceStyle.measuredText.drawsBackground)
        let measuredText = OCRBubbleLayoutEngine.measuredHorizontalTextSize(
            choice.text,
            fontSize: choice.layout.fontSize,
            maximumWidth: choice.layout.contentRect.width,
            lineSpacing: 2
        )
        #expect(abs(choice.layout.contentRect.width - measuredText.width) <= 1)
        #expect(abs(choice.layout.contentRect.height - measuredText.height) <= 1)
        #expect(
            abs(
                choice.layout.rect.width
                    - (choice.layout.contentRect.width + choice.layout.contentPadding * 2)
            ) < 0.001
        )
        #expect(
            abs(
                choice.layout.rect.height
                    - (choice.layout.contentRect.height + choice.layout.contentPadding * 2)
            ) < 0.001
        )
        #expect(choice.layout.rect.height > choice.layout.contentPadding * 2)
    }

    @Test func measuredTextFontDoesNotUseOCRBoxSize() {
        let requested = OCRBubbleLayoutEngine.requestedTranslationFontSize(
            hasReliableBubble: false,
            automaticFontSize: 300,
            measuredTextFontSize: 18
        )

        #expect(requested == 18)
    }

    @Test func detectedBubbleAndMeasuredTextAreTheOnlySurfaceStates() {
        #expect(Set(TranslationSurfaceStyle.allCases) == [.detectedBubble, .measuredText])
        #expect(
            TranslationSurfaceStyle.allCases.filter(\.drawsBackground)
                == [.detectedBubble, .measuredText]
        )
    }

    @Test func translationTextPassIsAboveEverySurfacePass() {
        #expect(TranslationSurfaceLayering.surfaceZIndex < TranslationSurfaceLayering.textZIndex)
    }

    @Test func measuredTextCardPaddingEqualsHalfFinalLineHeight() {
        let sourceRect = CGRect(x: 150, y: 200, width: 90, height: 300)
        let text = "Hello there"
        let layout = OCRBubbleLayoutEngine.anchoredTranslationLayout(
            text: text,
            sourceFontSize: 18,
            sourceRect: sourceRect,
            allowedBounds: CGRect(x: 80, y: 100, width: 300, height: 400),
            lineSpacing: 2,
            geometryStrategy: .measuredText
        )
        let expectedPadding = OCRBubbleLayoutEngine.measuredTextCardPadding(
            fontSize: layout.fontSize,
            textOrientation: .horizontal
        )
        let font = UIFont.systemFont(ofSize: layout.fontSize, weight: .bold)
        let measuredWidth = OCRBubbleLayoutEngine.measuredHorizontalTextSize(
            text,
            fontSize: layout.fontSize,
            maximumWidth: max(layout.rect.width - expectedPadding * 2, 1),
            lineSpacing: 2
        ).width
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.alignment = .center
        paragraphStyle.lineSpacing = 2
        let measuredHeight = (text as NSString).boundingRect(
            with: CGSize(
                width: max(layout.rect.width - expectedPadding * 2, 1),
                height: .greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [
                .font: font,
                .paragraphStyle: paragraphStyle
            ],
            context: nil
        ).integral.height

        #expect(abs(layout.contentPadding - expectedPadding) < 0.001)
        #expect(
            abs(
                layout.rect.width
                    - (layout.contentRect.width + layout.contentPadding * 2)
            ) < 0.001
        )
        #expect(
            abs(
                layout.rect.height
                    - (layout.contentRect.height + layout.contentPadding * 2)
            ) < 0.001
        )
        #expect(abs(layout.rect.width - (measuredWidth + expectedPadding * 2)) < 0.1)
        #expect(abs(layout.rect.height - (measuredHeight + expectedPadding * 2)) <= 1)
        #expect(layout.rect.height < sourceRect.height)
    }

    @Test func noBubblePathologicalWideOCRDoesNotEnlargeCard() {
        let sourceRect = CGRect(x: 20, y: 360, width: 340, height: 40)
        let layout = OCRBubbleLayoutEngine.anchoredTranslationLayout(
            text: "短句",
            sourceFontSize: 18,
            sourceRect: sourceRect,
            allowedBounds: CGRect(x: 0, y: 300, width: 390, height: 180),
            lineSpacing: 2,
            geometryStrategy: .measuredText
        )

        #expect(layout.rect.width < sourceRect.width)
        #expect(layout.rect.height < 80)
    }

    @Test func verticalMeasuredCardUsesHalfGlyphHeightPadding() {
        let layout = OCRBubbleLayoutEngine.anchoredTranslationLayout(
            text: "城市熟女。",
            sourceFontSize: 20,
            sourceRect: CGRect(x: 240, y: 120, width: 30, height: 400),
            allowedBounds: CGRect(x: 180, y: 80, width: 150, height: 500),
            lineSpacing: 2,
            textOrientation: .vertical,
            geometryStrategy: .measuredText
        )
        let expectedPadding = OCRBubbleLayoutEngine.measuredTextCardPadding(
            fontSize: layout.fontSize,
            textOrientation: .vertical
        )

        #expect(abs(layout.contentPadding - expectedPadding) < 0.001)
        #expect(layout.rect.height < 400)
        #expect(layout.rect.height < 200)
    }
}
