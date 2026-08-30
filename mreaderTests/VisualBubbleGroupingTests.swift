//
//  VisualBubbleGroupingTests.swift
//  mreaderTests
//
//  "同一个真实漫画气泡被错误拆成多个翻译单元"的回归测试。
//
//  核心不变量：
//  【如果多个文本块拥有经过验证、可靠且明确属于同一个漫画气泡的 bubble
//  geometry，那么它们必须优先被归入同一个 logical bubble / translation
//  unit。】可靠视觉气泡身份的优先级高于 estimatedFontScale、textBox 高宽、
//  textColorHex、行间距、center distance、layoutRole 等弱 OCR 启发式。
//
//  反向不变量同样被锁定：
//  【两个可靠且明确不同的 bubble geometry，绝不因距离较近而被合并。】
//  纯 OCR fallback（无 bubbleBox）的 complete-link 启发式保持原样。
//

import Testing
import CoreGraphics
@testable import mreader

@Suite(.serialized)
@MainActor
struct VisualBubbleGroupingTests {

    private static func block(
        text: String,
        boundingBox: CGRect,
        bubbleBox: CGRect?,
        estimatedFontScale: Double,
        textColorHex: String? = "#111111",
        layoutRole: TranslationLayoutRole = .dialogue,
        textOrientation: TextOrientation = .horizontal
    ) -> TextBlock {
        TextBlock(
            text: text,
            boundingBox: boundingBox,
            confidence: 0.9,
            ocrSource: "vision",
            estimatedFontScale: estimatedFontScale,
            textColorHex: textColorHex,
            bubbleBox: bubbleBox,
            textOrientation: textOrientation,
            layoutRole: layoutRole
        )
    }

    // MARK: - 测试 1：截图核心回归

    /// "I THINK YOU COULD USE SOME" / "REST." 属于同一个可靠气泡。
    /// 两行长度悬殊、第二行非常短、字号估计有 OCR 波动（比率 1.43 > 1.25）、
    /// 行间距（0.030）超过旧阈值 scale*0.62（0.026）——旧实现会被
    /// stylesAreCompatible 与间距启发式拆成两个单元。
    @Test func screenshotRegressionSameBubbleRowsMergeIntoOneUnit() {
        let bubble = CGRect(x: 0.12, y: 0.18, width: 0.62, height: 0.30)
        let line1 = Self.block(
            text: "I THINK YOU COULD USE SOME",
            boundingBox: CGRect(x: 0.20, y: 0.24, width: 0.46, height: 0.075),
            bubbleBox: bubble,
            estimatedFontScale: 0.060
        )
        let line2 = Self.block(
            text: "REST.",
            boundingBox: CGRect(x: 0.205, y: 0.345, width: 0.09, height: 0.06),
            bubbleBox: bubble,
            estimatedFontScale: 0.042
        )

        let segmentation = MangaTextSegmenter.segment([line1, line2], isRightToLeft: false)

        #expect(segmentation.bubbles.count == 1)
        #expect(segmentation.bubbles[0].text == "I THINK YOU COULD USE SOME REST.")
        // 合并后的单元必须保留视觉气泡（渲染层据此使用 detected bubble 表面）。
        #expect(segmentation.bubbles[0].bubbleBox != nil)
    }

    // MARK: - 测试 2：三行同气泡（A-B 相邻、B-C 相邻、A-C 距离远）

    /// complete-link 要求新成员与组内所有成员配对满足关系；A↔C 的纯 OCR 几何
    /// 不满足（纵向间距 0.23 远超 scale*0.62）。同一可靠气泡身份必须压过这一
    /// every-pair 约束，避免三行气泡被拆开。
    @Test func threeLinesWithDistantEndpointsShareOneReliableBubble() {
        let bubble = CGRect(x: 0.30, y: 0.15, width: 0.40, height: 0.42)
        let lineA = Self.block(
            text: "IF YOU SAY",
            boundingBox: CGRect(x: 0.42, y: 0.18, width: 0.16, height: 0.06),
            bubbleBox: bubble,
            estimatedFontScale: 0.050
        )
        let lineB = Self.block(
            text: "SO LOUDLY",
            boundingBox: CGRect(x: 0.34, y: 0.27, width: 0.30, height: 0.06),
            bubbleBox: bubble,
            estimatedFontScale: 0.050
        )
        let lineC = Self.block(
            text: "AGAIN.",
            boundingBox: CGRect(x: 0.50, y: 0.47, width: 0.12, height: 0.06),
            bubbleBox: bubble,
            estimatedFontScale: 0.050
        )

        let segmentation = MangaTextSegmenter.segment([lineA, lineB, lineC], isRightToLeft: false)

        #expect(segmentation.bubbles.count == 1)
        #expect(segmentation.bubbles[0].text == "IF YOU SAY SO LOUDLY AGAIN.")
    }

    // MARK: - 测试 3：同气泡字号尺度波动

    /// 同一可靠 bubble，两行 estimatedFontScale 比率 1.67，远超纯 OCR fallback
    /// 的 1.25 阈值——身份层必须仍然合并；且无 bubbleBox 的同几何样本仍按原
    /// 阈值拆开，证明 fallback 的全局字号阈值没有被放宽。
    @Test func sameBubbleMergesBeyondFontScaleThresholdWithoutLooseningFallback() {
        let bubble = CGRect(x: 0.2, y: 0.3, width: 0.5, height: 0.24)
        let line1 = Self.block(
            text: "YOU SHOULD REST",
            boundingBox: CGRect(x: 0.28, y: 0.36, width: 0.34, height: 0.07),
            bubbleBox: bubble,
            estimatedFontScale: 0.060
        )
        let line2 = Self.block(
            text: "MORE.",
            boundingBox: CGRect(x: 0.285, y: 0.455, width: 0.10, height: 0.055),
            bubbleBox: bubble,
            estimatedFontScale: 0.036
        )
        #expect(line1.estimatedFontScale / line2.estimatedFontScale > 1.25)

        let withBubble = MangaTextSegmenter.segment([line1, line2], isRightToLeft: false)
        #expect(withBubble.bubbles.count == 1)
        #expect(withBubble.bubbles[0].text == "YOU SHOULD REST MORE.")

        let withoutBubble = MangaTextSegmenter.segment(
            [
                Self.block(
                    text: line1.text,
                    boundingBox: line1.boundingBox,
                    bubbleBox: nil,
                    estimatedFontScale: line1.estimatedFontScale
                ),
                Self.block(
                    text: line2.text,
                    boundingBox: line2.boundingBox,
                    bubbleBox: nil,
                    estimatedFontScale: line2.estimatedFontScale
                )
            ],
            isRightToLeft: false
        )
        #expect(withoutBubble.bubbles.count == 2)
    }

    // MARK: - 测试 4：同气泡颜色采样波动

    /// 同一可靠 bubble，两行 textColorHex 的 RGB 距离远超 colorsAreCompatible
    /// 的 42 阈值——颜色偏差不得拆开真实气泡。
    @Test func sameBubbleMergesDespiteColorSamplingDeviation() {
        let bubble = CGRect(x: 0.15, y: 0.22, width: 0.55, height: 0.26)
        let line1 = Self.block(
            text: "IT WAS NEVER",
            boundingBox: CGRect(x: 0.24, y: 0.27, width: 0.36, height: 0.065),
            bubbleBox: bubble,
            estimatedFontScale: 0.055,
            textColorHex: "#101010"
        )
        let line2 = Self.block(
            text: "ABOUT YOU.",
            boundingBox: CGRect(x: 0.26, y: 0.36, width: 0.28, height: 0.06),
            bubbleBox: bubble,
            estimatedFontScale: 0.050,
            textColorHex: "#5A2E91"
        )

        let segmentation = MangaTextSegmenter.segment([line1, line2], isRightToLeft: false)

        #expect(segmentation.bubbles.count == 1)
        #expect(segmentation.bubbles[0].text == "IT WAS NEVER ABOUT YOU.")
    }

    // MARK: - 测试 5：同气泡 layoutRole 偶发不一致

    /// 一行 dialogue、一行被 OCR/视觉分类误判成 standalone，但两者携带同一
    /// 可靠 bubble geometry——真实气泡不得被拆成两个 translation unit；
    /// 合并结果按阅读顺序继承第一个成员的 layoutRole。
    @Test func sameBubbleSurvivesLayoutRoleMisclassification() {
        let bubble = CGRect(x: 0.18, y: 0.2, width: 0.5, height: 0.28)
        let dialogue = Self.block(
            text: "I KNEW IT",
            boundingBox: CGRect(x: 0.26, y: 0.26, width: 0.32, height: 0.065),
            bubbleBox: bubble,
            estimatedFontScale: 0.055,
            layoutRole: .dialogue
        )
        let misclassified = Self.block(
            text: "WOULDN'T LAST.",
            boundingBox: CGRect(x: 0.27, y: 0.36, width: 0.26, height: 0.06),
            bubbleBox: bubble,
            estimatedFontScale: 0.050,
            layoutRole: .standalone
        )

        #expect(misclassified.layoutRole == .standalone)

        let segmentation = MangaTextSegmenter.segment([dialogue, misclassified], isRightToLeft: false)

        #expect(segmentation.bubbles.count == 1)
        #expect(segmentation.bubbles[0].text == "I KNEW IT WOULDN'T LAST.")
        #expect(segmentation.bubbles[0].layoutRole == .dialogue)
    }

    // MARK: - 测试 6：两个明确不同的真实气泡不得合并

    /// 两个文本块字号相同、颜色相同，但 bubble geometry 明确属于不同气泡
    /// （两个相邻气泡只有轻微交叠，IOU 远低于身份阈值）——必须保持 2 个单元。
    @Test func adjacentDialogueInDifferentReliableBubblesStaysSplit() {
        let bubbleA = CGRect(x: 0.20, y: 0.20, width: 0.40, height: 0.25)
        let bubbleB = CGRect(x: 0.55, y: 0.22, width: 0.40, height: 0.25)
        let left = Self.block(
            text: "STOP IT.",
            boundingBox: CGRect(x: 0.30, y: 0.26, width: 0.20, height: 0.06),
            bubbleBox: bubbleA,
            estimatedFontScale: 0.060
        )
        let right = Self.block(
            text: "NEVER.",
            boundingBox: CGRect(x: 0.62, y: 0.28, width: 0.20, height: 0.06),
            bubbleBox: bubbleB,
            estimatedFontScale: 0.060
        )

        let segmentation = MangaTextSegmenter.segment([left, right], isRightToLeft: false)
        #expect(segmentation.bubbles.count == 2)
        #expect(segmentation.bubbles[0].text == "STOP IT.")
        #expect(segmentation.bubbles[1].text == "NEVER.")
    }

    // MARK: - P1 identity 边界回归

    /// 两个不同气泡的检测框有明显交叠（IoU > 0.18），但文字分别靠近各自气泡。
    /// 它们不能因为“compatible”就跳过 OCR fallback 并被当成同一身份。
    @Test func overlappingDistinctVisualBubblesDoNotMerge() {
        let bubbleA = CGRect(x: 0.10, y: 0.18, width: 0.40, height: 0.24)
        let bubbleB = CGRect(x: 0.32, y: 0.18, width: 0.40, height: 0.24)
        let intersection = bubbleA.intersection(bubbleB)
        let intersectionArea = intersection.width * intersection.height
        let unionArea = bubbleA.width * bubbleA.height
            + bubbleB.width * bubbleB.height
            - intersectionArea
        #expect(intersectionArea / unionArea > 0.18)

        let left = Self.block(
            text: "LEFT SPEAKER.",
            boundingBox: CGRect(x: 0.19, y: 0.25, width: 0.10, height: 0.04),
            bubbleBox: bubbleA,
            estimatedFontScale: 0.040
        )
        let right = Self.block(
            text: "RIGHT SPEAKER.",
            boundingBox: CGRect(x: 0.52, y: 0.25, width: 0.10, height: 0.04),
            bubbleBox: bubbleB,
            estimatedFontScale: 0.040
        )

        let segmentation = MangaTextSegmenter.segment([left, right], isRightToLeft: false)

        #expect(segmentation.bubbles.count == 2)
        #expect(segmentation.bubbles[0].text == "LEFT SPEAKER.")
        #expect(segmentation.bubbles[1].text == "RIGHT SPEAKER.")
    }

    /// 一个较大的外围框包含一个内部框时，单向 containment 只能说明两者
    /// compatible，不能证明它们来自同一个视觉检测结果。
    @Test func nestedButDifferentBubbleGeometryDoesNotAutomaticallyBecomeSameIdentity() {
        let outerBubble = CGRect(x: 0.12, y: 0.15, width: 0.52, height: 0.34)
        let innerBubble = CGRect(x: 0.24, y: 0.23, width: 0.28, height: 0.18)
        #expect(outerBubble.insetBy(dx: -0.006, dy: -0.006).contains(innerBubble))
        #expect(!innerBubble.insetBy(dx: -0.006, dy: -0.006).contains(outerBubble))

        let outerText = Self.block(
            text: "OUTER BUBBLE.",
            boundingBox: CGRect(x: 0.27, y: 0.28, width: 0.08, height: 0.04),
            bubbleBox: outerBubble,
            estimatedFontScale: 0.040
        )
        let innerText = Self.block(
            text: "INNER BUBBLE.",
            boundingBox: CGRect(x: 0.40, y: 0.28, width: 0.08, height: 0.04),
            bubbleBox: innerBubble,
            estimatedFontScale: 0.040
        )

        let segmentation = MangaTextSegmenter.segment([outerText, innerText], isRightToLeft: false)

        #expect(segmentation.bubbles.count == 2)
        #expect(segmentation.bubbles[0].text == "OUTER BUBBLE.")
        #expect(segmentation.bubbles[1].text == "INNER BUBBLE.")
    }

    // MARK: - 测试 7：纯 OCR 多行对白保持既有合并能力

    /// 无 bubbleBox 的普通多行对白（紧凑行距、颜色一致）必须照旧合并——
    /// 视觉身份层的引入不得把纯 OCR 对白全部拆开。
    @Test func pureOCRMultilineDialogueStillMerges() {
        let line1 = Self.block(
            text: "TOMORROW WE RIDE",
            boundingBox: CGRect(x: 0.30, y: 0.30, width: 0.34, height: 0.06),
            bubbleBox: nil,
            estimatedFontScale: 0.050,
            textColorHex: nil
        )
        let line2 = Self.block(
            text: "AT DAWN.",
            boundingBox: CGRect(x: 0.31, y: 0.382, width: 0.18, height: 0.055),
            bubbleBox: nil,
            estimatedFontScale: 0.046,
            textColorHex: nil
        )

        let segmentation = MangaTextSegmenter.segment([line1, line2], isRightToLeft: false)

        #expect(segmentation.bubbles.count == 1)
        #expect(segmentation.bubbles[0].text == "TOMORROW WE RIDE AT DAWN.")
    }

    // MARK: - 测试 8：纯 OCR 邻近对白不因链式合并误并

    /// 无 bubbleBox 的三个邻近块：A-B 是同一气泡内相邻的两行，B-C 行距也
    /// 在配对阈值内（single-link 会允许 C 链入），但 A-C 不满足几何条件。
    /// complete-link 必须保持防链式语义：A-B 成组，C 不被拖入，不能退化成
    /// single-link 把两个说话人的对白连成一片。
    @Test func pureOCRCompleteLinkStillGuardsAgainstChainedMerging() {
        let lineA = Self.block(
            text: "GET DOWN!",
            boundingBox: CGRect(x: 0.30, y: 0.30, width: 0.30, height: 0.05),
            bubbleBox: nil,
            estimatedFontScale: 0.048,
            textColorHex: nil
        )
        let lineB = Self.block(
            text: "BEHIND YOU!",
            boundingBox: CGRect(x: 0.30, y: 0.365, width: 0.30, height: 0.05),
            bubbleBox: nil,
            estimatedFontScale: 0.048,
            textColorHex: nil
        )
        let lineC = Self.block(
            text: "NOT YET.",
            boundingBox: CGRect(x: 0.34, y: 0.44, width: 0.22, height: 0.05),
            bubbleBox: nil,
            estimatedFontScale: 0.048,
            textColorHex: nil
        )

        let segmentation = MangaTextSegmenter.segment([lineA, lineB, lineC], isRightToLeft: false)

        #expect(segmentation.bubbles.count == 2)
        #expect(segmentation.bubbles[0].text == "GET DOWN! BEHIND YOU!")
        #expect(segmentation.bubbles[1].text == "NOT YET.")
    }

    // MARK: - 端到端结构：segmenter → translation input

    /// 端到端结构测试：同一可靠 bubble 的两行 OCR，经 MangaTextSegmenter
    /// 与 translation input 构造（与 AITranslationPageCoordinator 一致地按
    /// bubble 顺序生成 AIPageTranslationItem），必须只产生一个 translation
    /// item / 一个最终 TextBlock / 一个渲染覆盖组件。
    @Test func translationInputConstructionProducesSingleItemForOneBubble() {
        let bubble = CGRect(x: 0.12, y: 0.18, width: 0.62, height: 0.30)
        let line1 = Self.block(
            text: "I THINK YOU COULD USE SOME",
            boundingBox: CGRect(x: 0.20, y: 0.24, width: 0.46, height: 0.075),
            bubbleBox: bubble,
            estimatedFontScale: 0.060
        )
        let line2 = Self.block(
            text: "REST.",
            boundingBox: CGRect(x: 0.205, y: 0.345, width: 0.09, height: 0.06),
            bubbleBox: bubble,
            estimatedFontScale: 0.042
        )

        let segmentation = MangaTextSegmenter.segment([line1, line2], isRightToLeft: false)
        #expect(segmentation.bubbles.count == 1)

        // 与 AITranslationPageCoordinator.applyBatchTranslation 相同的构造方式：
        // 每个 segmented bubble 恰好生成一个 page translation item。
        let items = segmentation.bubbles.enumerated().map {
            AIPageTranslationItem(block: $1, order: $0)
        }
        #expect(items.count == 1)
        #expect(items[0].id == "b0")
        #expect(items[0].sourceText == "I THINK YOU COULD USE SOME REST.")

        // 发送给模型的 items 决定最终 TextBlock / TranslationLayoutItem /
        // TranslationTextRenderer 的数量：一个 item = 一个译文覆盖区域。
        #expect(items.map(\.id).count == 1)
    }
}
