//
//  TranslationSurfacePolicyTests.swift
//  mreaderTests
//
//  译文"表面样式"的回归测试。
//
//  这里锁定的不变量是：
//  只要画面上不存在可靠的漫画气泡（usableTranslationBubbleBounds == nil），
//  最终渲染层就绝不能产生覆盖整个 translation rect 的 RoundedRectangle。
//

import Testing
import CoreGraphics
import UIKit
@testable import mreader

@Suite struct TranslationSurfacePolicyTests {

    private static let imageBounds = CGRect(x: 0, y: 0, width: 390, height: 780)

    private static var transform: OCRDisplayTransform {
        OCRDisplayTransform(imageRect: imageBounds)
    }

    /// 用显示坐标书写样本，再换算成 TextBlock 需要的归一化矩形，
    /// 避免整数字面量相除被推断成 Int 除法。
    private static func normalized(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX / imageBounds.width,
            y: rect.minY / imageBounds.height,
            width: rect.width / imageBounds.width,
            height: rect.height / imageBounds.height
        )
    }

    // MARK: - P0: 气泡存在性决定表面样式

    @Test func surfaceStylePolicyRequiresReliableBubble() {
        #expect(TranslationSurfacePolicy.surfaceStyle(hasReliableBubble: true) == .bubble)
        #expect(TranslationSurfacePolicy.surfaceStyle(hasReliableBubble: false) == .borderless)
        #expect(TranslationSurfaceStyle.bubble.drawsBackground)
        #expect(TranslationSurfaceStyle.borderless.drawsBackground == false)
    }

    /// 截图里“大白框”的根因回归：没有 bubbleBox 的普通对白仍然是 dialogue 语义，
    /// 但绝不能凭空获得一张白色背景卡片。
    @Test func dialogueWithoutBubbleBoxNeverDrawsBackground() {
        let block = TextBlock(
            text: "城市熟女。",
            boundingBox: CGRect(x: 0.62, y: 0.18, width: 0.08, height: 0.34),
            ocrSource: "vision:ja",
            bubbleBox: nil,
            textOrientation: .vertical,
            layoutRole: .dialogue
        )
        let textRect = OCRCoordinateMapper.displayRect(
            forNormalizedPageRect: block.boundingBox,
            using: Self.transform
        )

        // 语义仍然是对白，不能因为缺气泡就被降级成 standalone。
        #expect(block.layoutRole == .dialogue)
        #expect(OCRBubbleLayoutEngine.usesStandaloneLayout(for: block) == false)

        let surface = OCRBubbleLayoutEngine.translationSurfaceStyle(
            for: block,
            textRect: textRect,
            using: Self.transform
        )
        #expect(surface == .borderless)
        #expect(surface.drawsBackground == false)
        #expect(
            OCRBubbleLayoutEngine.usableTranslationBubbleBounds(
                for: block,
                textRect: textRect,
                using: Self.transform
            ) == nil
        )
    }

    /// 旁白 / 音效这类本来就没有气泡的文字，同样必须是 borderless。
    @Test func standaloneTextWithoutBubbleIsBorderless() {
        let block = TextBlock(
            text: "FIDGET",
            boundingBox: CGRect(x: 0.20, y: 0.22, width: 0.46, height: 0.20),
            ocrSource: "vision-model:soundEffect",
            bubbleBox: nil,
            textOrientation: .horizontal,
            layoutRole: .standalone
        )
        let textRect = OCRCoordinateMapper.displayRect(
            forNormalizedPageRect: block.boundingBox,
            using: Self.transform
        )
        #expect(OCRBubbleLayoutEngine.usesStandaloneLayout(for: block))
        #expect(
            OCRBubbleLayoutEngine.translationSurfaceStyle(
                for: block,
                textRect: textRect,
                using: Self.transform
            ) == .borderless
        )
    }

    /// 病态气泡（覆盖整页）会被可靠性判定拒绝，此时也不能回退成“画一张大卡片”。
    @Test func wholePageBubbleIsRejectedAndBecomesBorderless() {
        let block = TextBlock(
            text: "I knew it wouldn't be...",
            boundingBox: CGRect(x: 0.20, y: 0.30, width: 0.42, height: 0.08),
            ocrSource: "vision",
            bubbleBox: CGRect(x: 0, y: 0, width: 1, height: 1),
            textOrientation: .horizontal,
            layoutRole: .dialogue
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
    }

    /// 真正合格的气泡必须继续保留气泡背景，避免过度修复把正常漫画对白也变成裸字。
    @Test func validBubbleKeepsBubbleSurface() {
        let block = TextBlock(
            text: "I knew it wouldn't be...",
            boundingBox: Self.normalized(CGRect(x: 150, y: 260, width: 70, height: 32)),
            ocrSource: "vision",
            bubbleBox: Self.normalized(CGRect(x: 125, y: 220, width: 120, height: 100)),
            textOrientation: .horizontal,
            layoutRole: .dialogue
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
            ) == .bubble
        )
    }

    /// 同一段文字：气泡存在性变化只应改变表面样式，不应改变语义角色。
    @Test func surfaceStyleIsOrthogonalToLayoutRole() {
        let base = TextBlock(
            text: "I knew it wouldn't be...",
            boundingBox: Self.normalized(CGRect(x: 150, y: 260, width: 70, height: 32)),
            ocrSource: "vision",
            textOrientation: .horizontal,
            layoutRole: .dialogue
        )
        let textRect = OCRCoordinateMapper.displayRect(
            forNormalizedPageRect: base.boundingBox,
            using: Self.transform
        )
        let withBubble = TextBlock(
            text: base.text,
            boundingBox: base.boundingBox,
            ocrSource: "vision",
            bubbleBox: Self.normalized(CGRect(x: 125, y: 220, width: 120, height: 100)),
            textOrientation: .horizontal,
            layoutRole: .dialogue
        )

        #expect(
            OCRBubbleLayoutEngine.translationSurfaceStyle(
                for: base,
                textRect: textRect,
                using: Self.transform
            ) == .borderless
        )
        #expect(
            OCRBubbleLayoutEngine.translationSurfaceStyle(
                for: withBubble,
                textRect: textRect,
                using: Self.transform
            ) == .bubble
        )
        #expect(base.layoutRole == withBubble.layoutRole)
    }

    // MARK: - P1: 无气泡时的排版范围只由文字测量结果决定

    /// 又窄又高的竖排 OCR 框不能再把译文区域撑成巨大矩形。
    @Test @MainActor func verticalBorderlessLayoutUsesMeasuredGlyphsNotOCRBox() {
        let sourceRect = CGRect(x: 240, y: 120, width: 30, height: 400)
        let allowedBounds = CGRect(x: 200, y: 60, width: 110, height: 560)
        let text = "城市熟女。"

        let borderless = OCRBubbleLayoutEngine.anchoredTranslationLayout(
            text: text,
            sourceFontSize: 16,
            sourceRect: sourceRect,
            allowedBounds: allowedBounds,
            lineSpacing: 2,
            textOrientation: .vertical,
            useSourceRectAsMinimumExtent: false
        )
        let bubble = OCRBubbleLayoutEngine.anchoredTranslationLayout(
            text: text,
            sourceFontSize: 16,
            sourceRect: sourceRect,
            allowedBounds: allowedBounds,
            lineSpacing: 2,
            textOrientation: .vertical,
            useSourceRectAsMinimumExtent: true
        )

        // 无气泡：排版范围只由文字测量结果决定，不继承 400pt 高的 OCR 框。
        #expect(borderless.rect.height < sourceRect.height)
        #expect(borderless.rect.height < bubble.rect.height)
        // 但仍必须装得下这五个字，不能把文字裁掉。
        let expectedMinimum = 5 * 16 * TranslationLayoutMetrics.verticalAdvanceMultiplier
        #expect(borderless.rect.height >= expectedMinimum)

        // 有气泡：保持原有行为，译文应当填满气泡范围。
        #expect(bubble.rect.height >= sourceRect.height)

        #expect(allowedBounds.contains(borderless.rect))
        #expect(allowedBounds.contains(bubble.rect))
    }

    @Test @MainActor func horizontalBorderlessLayoutIgnoresTallOCRBox() {
        let sourceRect = CGRect(x: 150, y: 200, width: 90, height: 300)
        let allowedBounds = CGRect(x: 120, y: 100, width: 200, height: 500)

        let borderless = OCRBubbleLayoutEngine.anchoredTranslationLayout(
            text: "Hello there",
            sourceFontSize: 14,
            sourceRect: sourceRect,
            allowedBounds: allowedBounds,
            lineSpacing: 2,
            textOrientation: .horizontal,
            useSourceRectAsMinimumExtent: false
        )
        let bubble = OCRBubbleLayoutEngine.anchoredTranslationLayout(
            text: "Hello there",
            sourceFontSize: 14,
            sourceRect: sourceRect,
            allowedBounds: allowedBounds,
            lineSpacing: 2,
            textOrientation: .horizontal,
            useSourceRectAsMinimumExtent: true
        )

        #expect(borderless.rect.height < sourceRect.height)
        #expect(borderless.rect.height < bubble.rect.height)
        #expect(bubble.rect.height >= sourceRect.height)
        #expect(allowedBounds.contains(borderless.rect))
    }
}
