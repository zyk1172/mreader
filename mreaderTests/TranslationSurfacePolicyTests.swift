//
//  TranslationSurfacePolicyTests.swift
//  mreaderTests
//
//  译文"表面样式"的回归测试。
//
//  这里锁定的不变量是：
//  【任何正常显示的翻译结果都必须有一个可遮挡原文的背景承载层。】
//
//  可靠 bubbleBox 只决定背景卡片的几何来源，不决定背景是否存在：
//  - usableTranslationBubbleBounds != nil → .detectedBubble，背景沿用气泡范围；
//  - usableTranslationBubbleBounds == nil → .syntheticBubble，仍绘制背景，
//    但尺寸由译文实际排版结果决定，绝不继承病态 OCR / fallback 大矩形。
//  病态 bubbleBox（整页、越界、与文字不匹配）被可靠性判定拒绝后，
//  回退目标是 synthetic bubble，而不是"无背景裸字"。
//
//  说明：这里测的是 policy 层与布局层。渲染层的背景绘制由
//  `TranslationSurfaceStyle.drawsBackground` 统一门控——renderer 只依据
//  该属性决定是否画背景，因此约束 policy 即约束渲染行为；真正的视觉
//  回归（描边是否清晰、卡片是否紧凑）最好以后补 snapshot / UI test。
//

import Testing
import CoreGraphics
import UIKit
@testable import mreader

// TextBlock 与布局引擎入口都是 MainActor 隔离的，套件整体运行在 MainActor 上。
@Suite
@MainActor
struct TranslationSurfacePolicyTests {

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

    // MARK: - P0: 气泡可靠性决定背景卡片的几何来源

    @Test func surfaceStylePolicyMapsReliabilityToGeometrySource() {
        #expect(TranslationSurfacePolicy.surfaceStyle(hasReliableBubble: true) == .detectedBubble)
        #expect(TranslationSurfacePolicy.surfaceStyle(hasReliableBubble: false) == .syntheticBubble)
    }

    /// 本次最重要的不变量：detected 与 synthetic 都必须有背景。
    /// renderer 只依据 drawsBackground 决定是否绘制背景卡片。
    @Test func syntheticBubbleStillDrawsBackground() {
        #expect(TranslationSurfaceStyle.syntheticBubble.drawsBackground)
        #expect(TranslationSurfaceStyle.detectedBubble.drawsBackground)
        #expect(TranslationSurfaceStyle.allCases.allSatisfy { $0.drawsBackground })
    }

    /// 截图回归（borderless 时代）：没有 bubbleBox 的普通对白仍然是 dialogue 语义，
    /// 并获得一个 synthetic bubble 背景，而不是裸字压在原文上。
    @Test func dialogueWithoutReliableBubbleUsesSyntheticBubble() {
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

        #expect(
            OCRBubbleLayoutEngine.usableTranslationBubbleBounds(
                for: block,
                textRect: textRect,
                using: Self.transform
            ) == nil
        )
        let surface = OCRBubbleLayoutEngine.translationSurfaceStyle(
            for: block,
            textRect: textRect,
            using: Self.transform
        )
        #expect(surface == .syntheticBubble)
        #expect(surface.drawsBackground == true)
    }

    /// 旁白 / 音效这类本来就没有气泡的文字，同样获得 synthetic bubble 背景。
    @Test func standaloneTextWithoutBubbleUsesSyntheticBubble() {
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
            ) == .syntheticBubble
        )
    }

    /// 病态气泡（覆盖整页）会被可靠性判定拒绝，回退到 synthetic bubble，
    /// 而不是恢复成"整页大卡片"或"无背景裸字"。
    @Test func wholePageBubbleFallsBackToSyntheticBubble() {
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
        let surface = OCRBubbleLayoutEngine.translationSurfaceStyle(
            for: block,
            textRect: textRect,
            using: Self.transform
        )
        #expect(surface == .syntheticBubble)
        #expect(surface.drawsBackground == true)
    }

    /// 真正合格的气泡必须继续保留 detected bubble 背景。
    @Test func validBubbleUsesDetectedBubble() {
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
            ) == .detectedBubble
        )
    }

    /// 同一段文字：气泡存在性变化只改变背景的几何来源，不改变语义角色。
    /// dialogue + detectedBubble、dialogue + syntheticBubble、
    /// standalone + syntheticBubble 都是合法组合。
    @Test func surfaceStyleRemainsOrthogonalToLayoutRole() {
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
            ) == .syntheticBubble
        )
        #expect(
            OCRBubbleLayoutEngine.translationSurfaceStyle(
                for: withBubble,
                textRect: textRect,
                using: Self.transform
            ) == .detectedBubble
        )
        #expect(base.layoutRole == withBubble.layoutRole)

        // 反方向同样正交：standalone 即使带有可靠 bubbleBox，也不因此变成 dialogue，
        // 气泡存在性只影响背景来源。
        let standaloneWithBubble = TextBlock(
            text: base.text,
            boundingBox: base.boundingBox,
            ocrSource: "vision",
            bubbleBox: Self.normalized(CGRect(x: 125, y: 220, width: 120, height: 100)),
            textOrientation: .horizontal,
            layoutRole: .standalone
        )
        #expect(OCRBubbleLayoutEngine.usesStandaloneLayout(for: standaloneWithBubble))
        #expect(
            OCRBubbleLayoutEngine.translationSurfaceStyle(
                for: standaloneWithBubble,
                textRect: textRect,
                using: Self.transform
            ) == .detectedBubble
        )
    }

    // MARK: - P1: synthetic bubble 使用可信覆盖范围并拒绝病态几何

    /// 又窄又高的竖排 OCR 框不能再把 synthetic bubble 撑成巨大矩形。
    @Test func verticalSyntheticBubbleIgnoresTallOCRBox() {
        let sourceRect = CGRect(x: 240, y: 120, width: 30, height: 400)
        let allowedBounds = CGRect(x: 200, y: 60, width: 110, height: 560)
        let text = "城市熟女。"

        let synthetic = OCRBubbleLayoutEngine.anchoredTranslationLayout(
            text: text,
            sourceFontSize: 16,
            sourceRect: sourceRect,
            allowedBounds: allowedBounds,
            lineSpacing: 2,
            textOrientation: .vertical,
            useSourceRectAsMinimumExtent: false
        )
        let detected = OCRBubbleLayoutEngine.anchoredTranslationLayout(
            text: text,
            sourceFontSize: 16,
            sourceRect: sourceRect,
            allowedBounds: allowedBounds,
            lineSpacing: 2,
            textOrientation: .vertical,
            useSourceRectAsMinimumExtent: true
        )

        // 未传入 validated coverage 时，兼容旧调用仍只按文字测量；真实 Reader
        // 路径会为合格 textBox 传入 coverage，而病态框会被验证器拒绝。
        #expect(synthetic.rect.height < sourceRect.height)
        #expect(synthetic.rect.height < detected.rect.height)
        // 但仍必须装得下这五个字，不能把文字裁掉。
        let expectedMinimum = 5 * 16 * TranslationLayoutMetrics.verticalAdvanceMultiplier
        #expect(synthetic.rect.height >= expectedMinimum)

        // 有可靠气泡：保持原有行为，译文应当填满气泡范围。
        #expect(detected.rect.height >= sourceRect.height)

        #expect(allowedBounds.contains(synthetic.rect))
        #expect(allowedBounds.contains(detected.rect))
    }

    /// 病态超宽的 OCR 框同样不能被继承。synthetic bubble 虽然仍画背景，
    /// 但过大的排版矩形会参与避让计算，把附近的正常译文推走。
    @Test func horizontalSyntheticBubbleIgnoresWideOCRBox() {
        let sourceRect = CGRect(x: 40, y: 300, width: 320, height: 40)
        let allowedBounds = CGRect(x: 20, y: 260, width: 360, height: 120)

        let synthetic = OCRBubbleLayoutEngine.anchoredTranslationLayout(
            text: "Yes.",
            sourceFontSize: 16,
            sourceRect: sourceRect,
            allowedBounds: allowedBounds,
            lineSpacing: 2,
            textOrientation: .horizontal,
            useSourceRectAsMinimumExtent: false
        )
        let detected = OCRBubbleLayoutEngine.anchoredTranslationLayout(
            text: "Yes.",
            sourceFontSize: 16,
            sourceRect: sourceRect,
            allowedBounds: allowedBounds,
            lineSpacing: 2,
            textOrientation: .horizontal,
            useSourceRectAsMinimumExtent: true
        )

        #expect(synthetic.rect.width < sourceRect.width)
        #expect(synthetic.rect.width < detected.rect.width)
        // 有可靠气泡时保持原有行为：译文宽度应当填满气泡。
        #expect(detected.rect.width >= sourceRect.width)
        #expect(allowedBounds.contains(synthetic.rect))
    }

    /// 文字自然宽度超过允许区域时必须被截断，而不是溢出到画面外。
    @Test func syntheticWidthNeverExceedsAllowedBounds() {
        let sourceRect = CGRect(x: 60, y: 300, width: 300, height: 40)
        let allowedBounds = CGRect(x: 20, y: 260, width: 140, height: 200)

        let layout = OCRBubbleLayoutEngine.anchoredTranslationLayout(
            text: "This is a very long translated sentence that cannot fit on one line.",
            sourceFontSize: 16,
            sourceRect: sourceRect,
            allowedBounds: allowedBounds,
            lineSpacing: 2,
            textOrientation: .horizontal,
            useSourceRectAsMinimumExtent: false
        )

        #expect(layout.rect.width <= allowedBounds.width + 0.5)
        #expect(allowedBounds.contains(layout.rect))
    }

    @Test func validatedSourceCoverageAcceptsNormalTextAndRejectsPathologicalGeometry() {
        let normal = CGRect(x: 145, y: 260, width: 100, height: 60)
        #expect(
            OCRBubbleLayoutEngine.validatedSourceCoverageRect(
                normal,
                within: Self.imageBounds
            ) == normal
        )

        let wholePage = CGRect(x: 0, y: 0, width: 390, height: 780)
        let tooWide = CGRect(x: 35, y: 300, width: 320, height: 40)
        let outside = CGRect(x: -20, y: 300, width: 80, height: 40)
        #expect(
            OCRBubbleLayoutEngine.validatedSourceCoverageRect(
                wholePage,
                within: Self.imageBounds
            ) == nil
        )
        #expect(
            OCRBubbleLayoutEngine.validatedSourceCoverageRect(
                tooWide,
                within: Self.imageBounds
            ) == nil
        )
        #expect(
            OCRBubbleLayoutEngine.validatedSourceCoverageRect(
                outside,
                within: Self.imageBounds
            ) == nil
        )
    }

    @Test @MainActor func syntheticBubbleCoversValidatedSourceWithoutInheritingGiantBox() {
        let sourceRect = CGRect(x: 145, y: 260, width: 100, height: 60)
        let imageBounds = Self.imageBounds
        let coverage = OCRBubbleLayoutEngine.validatedSourceCoverageRect(
            sourceRect,
            within: imageBounds
        )
        let covered = OCRBubbleLayoutEngine.anchoredTranslationLayout(
            text: "你好。",
            sourceFontSize: 16,
            sourceRect: sourceRect,
            allowedBounds: imageBounds,
            lineSpacing: 2,
            textOrientation: .horizontal,
            useSourceRectAsMinimumExtent: false,
            minimumSourceCoverageRect: coverage
        )
        #expect(covered.rect.contains(sourceRect))

        let pathological = CGRect(x: 35, y: 300, width: 320, height: 40)
        let compact = OCRBubbleLayoutEngine.anchoredTranslationLayout(
            text: "Yes.",
            sourceFontSize: 16,
            sourceRect: pathological,
            allowedBounds: imageBounds,
            lineSpacing: 2,
            textOrientation: .horizontal,
            useSourceRectAsMinimumExtent: false,
            minimumSourceCoverageRect: OCRBubbleLayoutEngine.validatedSourceCoverageRect(
                pathological,
                within: imageBounds
            )
        )
        #expect(compact.rect.width < pathological.width)
        #expect(imageBounds.contains(compact.rect))
    }

    /// 横排 synthetic bubble 也不能继承异常高的 OCR 框。
    @Test func horizontalSyntheticBubbleIgnoresTallOCRBox() {
        let sourceRect = CGRect(x: 150, y: 200, width: 90, height: 300)
        let allowedBounds = CGRect(x: 120, y: 100, width: 200, height: 500)

        let synthetic = OCRBubbleLayoutEngine.anchoredTranslationLayout(
            text: "Hello there",
            sourceFontSize: 14,
            sourceRect: sourceRect,
            allowedBounds: allowedBounds,
            lineSpacing: 2,
            textOrientation: .horizontal,
            useSourceRectAsMinimumExtent: false
        )
        let detected = OCRBubbleLayoutEngine.anchoredTranslationLayout(
            text: "Hello there",
            sourceFontSize: 14,
            sourceRect: sourceRect,
            allowedBounds: allowedBounds,
            lineSpacing: 2,
            textOrientation: .horizontal,
            useSourceRectAsMinimumExtent: true
        )

        #expect(synthetic.rect.height < sourceRect.height)
        #expect(synthetic.rect.height < detected.rect.height)
        #expect(detected.rect.height >= sourceRect.height)
        #expect(allowedBounds.contains(synthetic.rect))
    }
}
