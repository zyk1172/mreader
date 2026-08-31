import CoreGraphics
import Foundation
import UIKit

/// 译文表面样式：决定背景卡片的几何来源，而不是决定背景是否存在。
///
/// 背景卡片的产品职责是：遮住原文、在复杂漫画背景上保证译文可读性、
/// 给译文一个稳定的视觉承载区域。因此不变量是：
/// **任何正常显示的翻译结果都必须有一个可遮挡原文的背景承载层。**
///
/// 这是与 `TranslationLayoutRole` 正交的维度。`layoutRole` 描述文字的语义类别
/// （对白 / 旁白 / 音效），而 `surfaceStyle` 只回答一个问题：
/// **背景卡片的矩形来自真实气泡，还是来自译文自身的测量结果？**
///
/// 两者不能混用。没有 bubbleBox 的对白并不等于 standalone：纯 OCR 完全可能
/// 识别不到气泡，此时若按 standalone 处理会丢失对白的排版语义；但它也
/// 不需要为"看起来像气泡"复刻原漫画轮廓——没有可靠气泡时生成紧凑的
/// synthetic bubble 即可，尺寸由译文实际排版结果决定，绝不继承病态
/// OCR / fallback 大矩形。
nonisolated enum TranslationSurfaceStyle: String, Sendable, Codable, CaseIterable {
    /// 存在经过验证的真实漫画气泡，背景沿用气泡范围（较宽松）。
    case detectedBubble
    /// 没有可靠气泡：仍必须绘制背景以遮挡原文，但背景是紧凑的 synthetic
    /// bubble——锚定原文字中心，宽高由译文实际排版结果决定。
    case syntheticBubble

    /// 所有 surface style 都绘制背景。该属性是"翻译必须有可遮挡原文的
    /// 背景承载层"这条产品不变量的代码化：渲染层只依据它决定是否画背景，
    /// 任何新增 case 都必须显式面对这条规则。
    var drawsBackground: Bool {
        true
    }

    /// 背景中白色填充的浓度。synthetic bubble 略轻，避免显得像贴纸；
    /// 但仍须足以压住其下的原文。
    var backgroundOpacity: Double {
        switch self {
        case .detectedBubble: return 0.50
        case .syntheticBubble: return 0.44
        }
    }

    /// 背景边框的浓度。
    var borderOpacity: Double {
        switch self {
        case .detectedBubble: return 0.86
        case .syntheticBubble: return 0.78
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .detectedBubble: return 7
        case .syntheticBubble: return 6
        }
    }
}

nonisolated enum TranslationSurfacePolicy {
    /// 唯一入口：可靠气泡只决定背景卡片的几何来源。
    ///
    /// `hasReliableBubble` 必须来自 `OCRBubbleLayoutEngine.reliableTranslationBubbleBounds`
    /// 的判定结果——它已经排除了 bubbleBox 缺失、越界、覆盖整页等病态情况。
    ///
    /// 有可靠气泡 → `.detectedBubble`，背景沿用气泡范围。
    /// 没有可靠气泡 → `.syntheticBubble`：不得把病态 OCR / fallback 大矩形直接
    /// 当成可见背景，但仍必须生成基于译文实际排版尺寸的紧凑背景卡片，
    /// 以遮挡原文并保证可读性。
    static func surfaceStyle(hasReliableBubble: Bool) -> TranslationSurfaceStyle {
        hasReliableBubble ? .detectedBubble : .syntheticBubble
    }
}

nonisolated enum TranslationLayoutMetrics {
    static let contentPadding: CGFloat = 5
    static let verticalAdvanceMultiplier: CGFloat = 1.08
    static let verticalColumnWidthMultiplier: CGFloat = 1.10
    static let geometryFontScaleMultiplier: CGFloat = 1.25
    static let absoluteFontSizeCap: CGFloat = 72
    static let maximumCardWidthFraction: CGFloat = 0.78
    static let maximumCardHeightFraction: CGFloat = 0.68
    static let maximumCardAreaFraction: CGFloat = 0.38
}

nonisolated enum OCRBubbleLayoutEngine {
    nonisolated enum TranslationTextSizingMode: Sendable {
        case bubble
        case standaloneGlyph
    }

    struct TranslationLayout: Sendable {
        let rect: CGRect
        let fontSize: CGFloat
    }

    struct TranslationLayoutChoice: Sendable {
        let text: String
        let layout: TranslationLayout
        let usesSuggestedLineBreaks: Bool
    }

    static func preferredTranslationFontSize(sourceFontSize: CGFloat) -> CGFloat {
        // 先尝试原文字号；气泡边界是硬约束，装不下时由 anchoredTranslationLayout 缩小文字。
        min(max(sourceFontSize, 1), TranslationLayoutMetrics.absoluteFontSizeCap)
    }

    /// 有可靠气泡时沿用 OCR 几何字号；没有可靠气泡（synthetic bubble）时，
    /// OCR 框不再参与字号决策，改用用户设置的无气泡字号。
    /// 后续布局仍会在 allowedBounds 内按实际文本测量结果缩小字号。
    static func requestedTranslationFontSize(
        hasReliableBubble: Bool,
        automaticFontSize: CGFloat,
        borderlessFontSize: CGFloat
    ) -> CGFloat {
        guard !hasReliableBubble else {
            return preferredTranslationFontSize(sourceFontSize: automaticFontSize)
        }
        return CGFloat(
            ComicBook.clampedBorderlessTranslationFontSize(Double(borderlessFontSize))
        )
    }

    static func effectiveTranslationOrientation(
        sourceOrientation: TextOrientation,
        targetLanguage: TranslationTargetLanguage,
        translatedText: String
    ) -> TextOrientation {
        guard sourceOrientation == .vertical else { return .horizontal }
        switch targetLanguage {
        case .simplifiedChinese, .traditionalChinese, .japanese:
            return isPrimarilyCJK(translatedText) ? .vertical : .horizontal
        default:
            return .horizontal
        }
    }

    static func isPrimarilyCJK(_ text: String) -> Bool {
        var cjkCount = 0
        var meaningfulCount = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF,
                 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                cjkCount += 1
                meaningfulCount += 1
            case 0x0041...0x024F,
                 0x0400...0x052F,
                 0x0E00...0x0E7F,
                 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF,
                 0xAC00...0xD7AF:
                meaningfulCount += 1
            default:
                if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                    meaningfulCount += 1
                }
            }
        }
        guard meaningfulCount > 0 else { return false }
        return Double(cjkCount) / Double(meaningfulCount) >= 0.60
    }

    static func usesStandaloneLayout(for block: TextBlock) -> Bool {
        block.layoutRole == .standalone
    }

    /// 把 OCR bubbleBox 映射到显示坐标，并剔除不可靠的气泡（缺失、越界、覆盖整页、
    /// 与文字实际位置不匹配）。返回值非空才代表"画面上确实存在一个漫画气泡"。
    static func usableTranslationBubbleBounds(
        for block: TextBlock,
        textRect: CGRect,
        using transform: OCRDisplayTransform
    ) -> CGRect? {
        guard let bubbleBox = block.bubbleBox else { return nil }
        let imageBounds = transform.imageRect
        let mappedBubble = OCRCoordinateMapper.displayRect(
            forNormalizedPageRect: bubbleBox,
            using: transform
        )
        return reliableTranslationBubbleBounds(
            mappedBubble,
            textRect: textRect,
            imageBounds: imageBounds,
            toleranceX: max(2, imageBounds.width * 0.005),
            toleranceY: max(2, imageBounds.height * 0.005)
        )
    }

    /// 从 TextBlock 直接得出渲染层表面样式。
    ///
    /// 这是"背景卡片几何来源"的端到端判定入口：气泡存在性在布局层得到后，
    /// 必须由渲染层消费。无论判定结果如何，译文都会获得背景卡片——真实气泡
    /// 只决定背景沿用气泡范围还是改用译文测量出的紧凑 synthetic bubble。ReaderView
    /// 已经算过 `usableTranslationBubbleBounds` 时会直接复用该结果再套 policy；
    /// 本函数供尚未持有该结果（以及测试）的场景使用，判定组件完全相同。
    static func translationSurfaceStyle(
        for block: TextBlock,
        textRect: CGRect,
        using transform: OCRDisplayTransform
    ) -> TranslationSurfaceStyle {
        TranslationSurfacePolicy.surfaceStyle(
            hasReliableBubble: usableTranslationBubbleBounds(
                for: block,
                textRect: textRect,
                using: transform
            ) != nil
        )
    }

    /// Standalone text (sound effects, labels, and tilted words) has no real
    /// bubbleBox to provide a generous layout area. Its axis-aligned OCR box
    /// can be much larger than the glyphs when the word is rotated, so use the
    /// actual polygon short axis or the per-glyph area estimate as a lower
    /// bound for the display font size.
    static func standaloneTextFontSize(
        for block: TextBlock,
        imageRect: CGRect,
        textRect: CGRect
    ) -> CGFloat {
        let sourceFontSize = block.sourceFontSize(in: imageRect)
        guard usesStandaloneLayout(for: block) else { return sourceFontSize }

        let glyphCount = max(block.text.filter { !$0.isWhitespace }.count, 1)
        let areaPerGlyph = sqrt(
            max(textRect.width * textRect.height, 1) / CGFloat(glyphCount)
        )
        // The short display axis is a safer estimate than the long axis of a
        // merged or rotated OCR rectangle. It also keeps a bad crop from
        // enlarging a standalone translation merely because its text is long.
        let axisGlyphSize = block.textOrientation == .horizontal
            ? textRect.height
            : textRect.width
        var candidates = [sourceFontSize, areaPerGlyph, axisGlyphSize]

        let displayPolygon = block.polygon.map { point in
            CGPoint(
                x: imageRect.minX + point.x * imageRect.width,
                y: imageRect.minY + point.y * imageRect.height
            )
        }
        if let shortAxis = orientedShortAxis(of: displayPolygon) {
            candidates.append(shortAxis)
        }
        return max(candidates.min() ?? sourceFontSize, 1)
    }

    static func sourceFontSize(
        for block: TextBlock,
        imageRect: CGRect,
        textRect: CGRect,
        sizingMode: TranslationTextSizingMode
    ) -> CGFloat {
        switch sizingMode {
        case .bubble:
            return block.sourceFontSize(in: imageRect)
        case .standaloneGlyph:
            return standaloneTextFontSize(for: block, imageRect: imageRect, textRect: textRect)
        }
    }

    static func geometryCappedSourceFontSize(
        for block: TextBlock,
        imageRect: CGRect,
        textRect: CGRect,
        sizingMode: TranslationTextSizingMode
    ) -> CGFloat {
        let estimated = sourceFontSize(
            for: block,
            imageRect: imageRect,
            textRect: textRect,
            sizingMode: sizingMode
        )
        let glyphAxis = block.textOrientation == .horizontal
            ? textRect.height
            : textRect.width
        let geometryCap = max(
            glyphAxis * TranslationLayoutMetrics.geometryFontScaleMultiplier,
            1
        )
        return min(
            max(estimated, 1),
            geometryCap,
            TranslationLayoutMetrics.absoluteFontSizeCap
        )
    }

    /// Caps a pathological OCR/model bubble before layout can expand a card
    /// over the artwork. The returned rectangle remains inside the original
    /// allowed bounds, while the debug layer can continue to show the raw
    /// allowed bounds separately.
    static func boundedTranslationBounds(
        around sourceRect: CGRect,
        within allowedBounds: CGRect,
        imageBounds: CGRect
    ) -> CGRect {
        let safeImageBounds = imageBounds.standardized
        let safeAllowed = allowedBounds.standardized.intersection(safeImageBounds)
        guard safeAllowed.width > 0, safeAllowed.height > 0 else {
            return safeAllowed
        }

        var width = min(
            safeAllowed.width,
            safeImageBounds.width * TranslationLayoutMetrics.maximumCardWidthFraction
        )
        var height = min(
            safeAllowed.height,
            safeImageBounds.height * TranslationLayoutMetrics.maximumCardHeightFraction
        )
        let maximumArea = safeImageBounds.width
            * safeImageBounds.height
            * TranslationLayoutMetrics.maximumCardAreaFraction
        if width * height > maximumArea, maximumArea > 0 {
            let scale = sqrt(maximumArea / (width * height))
            width *= scale
            height *= scale
        }

        let center = CGPoint(
            x: min(max(sourceRect.midX, safeAllowed.minX), safeAllowed.maxX),
            y: min(max(sourceRect.midY, safeAllowed.minY), safeAllowed.maxY)
        )
        let capped = CGRect(
            x: center.x - width / 2,
            y: center.y - height / 2,
            width: width,
            height: height
        )
        return capped.intersection(safeAllowed).isNull
            ? safeAllowed
            : clamped(capped, to: safeAllowed, margin: 0)
    }

    /// Standalone translations may grow only by a small, finite padding around
    /// the original textBox. A long translation therefore causes the layout
    /// engine to reduce the font size instead of creating a large card over the
    /// artwork.
    static func standaloneTranslationBounds(
        around textRect: CGRect,
        within imageBounds: CGRect
    ) -> CGRect {
        guard !textRect.isNull,
              !imageBounds.isNull,
              textRect.width > 0,
              textRect.height > 0,
              imageBounds.width > 0,
              imageBounds.height > 0 else {
            return textRect
        }

        let horizontalPadding = min(max(textRect.width * 0.35, 8), 24)
        let verticalPadding = min(max(textRect.height * 0.35, 6), 20)
        let maximumWidth = max(
            textRect.width,
            min(textRect.width + horizontalPadding * 2, imageBounds.width * 0.36)
        )
        let maximumHeight = max(
            textRect.height,
            min(textRect.height + verticalPadding * 2, imageBounds.height * 0.28)
        )
        let bounds = CGRect(
            x: textRect.midX - maximumWidth / 2,
            y: textRect.midY - maximumHeight / 2,
            width: maximumWidth,
            height: maximumHeight
        ).intersection(imageBounds)
        return bounds.isNull || bounds.width <= 0 || bounds.height <= 0
            ? textRect.intersection(imageBounds)
            : bounds
    }

    /// 验证可用于 synthetic bubble 的原文覆盖范围。
    ///
    /// `sourceRect` 是合并后的 OCR textBox union，而不是任意 fallback / bubble 框。
    /// 正常对白必须保留在最终卡片的最小覆盖范围内；越界、整页、超宽、超高或
    /// 面积异常的 OCR 几何则放弃这个覆盖约束，避免旧的大白框回归。验证还必须
    /// 结合 block 的文字方向、字号尺度、glyph 数量和横排源 line 数：单个短句或
    /// 少量横排对白不能仅因为轴向比例没有超过页面百分比阈值，就把病态的长框传给
    /// synthetic bubble。
    static func validatedSourceCoverageRect(
        for block: TextBlock,
        sourceRect: CGRect,
        within imageBounds: CGRect
    ) -> CGRect? {
        let safeImage = imageBounds.standardized
        let safeSource = sourceRect.standardized
        guard rectIsFinite(safeImage),
              rectIsFinite(safeSource),
              safeImage.width > 0,
              safeImage.height > 0,
              safeSource.width > 0,
              safeSource.height > 0 else {
            return nil
        }

        let toleranceX = max(2, safeImage.width * 0.005)
        let toleranceY = max(2, safeImage.height * 0.005)
        guard safeImage.insetBy(dx: -toleranceX, dy: -toleranceY).contains(safeSource) else {
            return nil
        }

        let clipped = safeSource.intersection(safeImage)
        guard clipped.width > 0,
              clipped.height > 0 else {
            return nil
        }

        let pageArea = safeImage.width * safeImage.height
        let sourceArea = clipped.width * clipped.height
        guard clipped.width <= safeImage.width * TranslationLayoutMetrics.maximumCardWidthFraction,
              clipped.height <= safeImage.height * TranslationLayoutMetrics.maximumCardHeightFraction,
              sourceArea <= pageArea * TranslationLayoutMetrics.maximumCardAreaFraction else {
            return nil
        }

        guard glyphAwareSourceCoverageIsPlausible(
            for: block,
            sourceRect: clipped,
            within: safeImage
        ) else {
            return nil
        }
        return clipped
    }

    /// Page fractions reject obvious full-page boxes, but they cannot distinguish a
    /// short sentence from a narrow OCR crop that spans hundreds of points. The short
    /// display axis is the most stable glyph-size estimate for a vertical block. For
    /// horizontal merged blocks, sourceLineCount supplies the missing line structure;
    /// the estimated scale is additionally bounded by average glyph advance so a bad
    /// union cannot make the cross-line check permissive.
    private static func glyphAwareSourceCoverageIsPlausible(
        for block: TextBlock,
        sourceRect: CGRect,
        within imageBounds: CGRect
    ) -> Bool {
        let glyphCount = max(
            block.text.filter { !$0.isWhitespace && $0 != "\n" }.count,
            1
        )
        let estimatedFontSize = block.sourceFontSize(in: imageBounds)
        guard estimatedFontSize.isFinite, estimatedFontSize > 0 else {
            return false
        }

        switch block.textOrientation {
        case .vertical:
            let glyphWidth = max(sourceRect.width, 1)
            let glyphSize = min(
                max(estimatedFontSize, glyphWidth * 0.65),
                glyphWidth * 1.25
            )
            let expectedGlyphSpan = CGFloat(glyphCount)
                * glyphSize
                * TranslationLayoutMetrics.verticalAdvanceMultiplier
            let maximumGlyphSpan = expectedGlyphSpan * 1.35 + glyphSize * 2
            return sourceRect.height <= maximumGlyphSpan
        case .horizontal:
            let lineCount = CGFloat(max(block.sourceLineCount, 1))
            let averageGlyphAdvance = sourceRect.width / CGFloat(glyphCount)
            let glyphBasedLineHeight = max(averageGlyphAdvance * 5, 1)
            let widthBoundedLineHeight = max(sourceRect.width * 1.5, 1)
            // A malformed union can make estimatedFontSize come from the bad
            // cross-axis extent. Keep a broad glyph-advance tolerance, but bound
            // that inflated estimate by the source width so it cannot authorize a
            // 200-300pt single line or a similarly tall small-line union.
            let lineHeight = min(
                estimatedFontSize,
                min(glyphBasedLineHeight, widthBoundedLineHeight)
            )
            let interLineTolerance = max(lineHeight * 0.5, 2)
            let maximumLineSpan = lineCount * lineHeight * 1.6 + interLineTolerance
            return sourceRect.height <= maximumLineSpan
        }
    }

    private static func rectIsFinite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite
            && rect.origin.y.isFinite
            && rect.size.width.isFinite
            && rect.size.height.isFinite
    }

    @MainActor
    /// - Parameter useSourceRectAsMinimumExtent: 有可靠气泡时，译文应当填满气泡,
    ///   因此把 OCR textBox 当作最小排版范围；没有可靠气泡时，只有经过
    ///   `validatedSourceCoverageRect` 验证的原文区域才会成为 synthetic bubble 的
    ///   最小范围，病态 OCR 框不会把译文区域撑成巨大矩形。
    static func anchoredTranslationLayout(
        text: String,
        sourceFontSize: CGFloat,
        sourceRect: CGRect,
        allowedBounds: CGRect,
        lineSpacing: CGFloat,
        padding: CGFloat = TranslationLayoutMetrics.contentPadding,
        textOrientation: TextOrientation = .horizontal,
        useSourceRectAsMinimumExtent: Bool = true,
        minimumSourceCoverageRect: CGRect? = nil
    ) -> TranslationLayout {
        if textOrientation == .vertical {
            return anchoredVerticalTranslationLayout(
                text: text,
                sourceFontSize: sourceFontSize,
                sourceRect: sourceRect,
                allowedBounds: allowedBounds,
                padding: padding,
                useSourceRectAsMinimumExtent: useSourceRectAsMinimumExtent,
                minimumSourceCoverageRect: minimumSourceCoverageRect
            )
        }

        let safeBounds = allowedBounds.standardized
        guard safeBounds.width > 0, safeBounds.height > 0 else {
            return TranslationLayout(rect: sourceRect, fontSize: max(sourceFontSize, 1))
        }

        let coverageRect: CGRect?
        if let minimumSourceCoverageRect {
            let intersection = minimumSourceCoverageRect.standardized.intersection(safeBounds)
            coverageRect = intersection.width > 0 && intersection.height > 0 ? intersection : nil
        } else {
            coverageRect = nil
        }
        let anchorRect = coverageRect ?? sourceRect
        let anchor = CGPoint(
            x: min(max(anchorRect.midX, safeBounds.minX), safeBounds.maxX),
            y: min(max(anchorRect.midY, safeBounds.minY), safeBounds.maxY)
        )
        let targetFontSize = preferredTranslationFontSize(sourceFontSize: sourceFontSize)

        /// 文字在给定字号下的自然宽度，取最长行。translationLines 用换行分隔，
        /// 因此不能只测量整串。
        func measuredNaturalWidth(fontSize: CGFloat) -> CGFloat {
            let font = UIFont.systemFont(ofSize: fontSize, weight: .bold)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            return lines.reduce(CGFloat(0)) { widest, line in
                max(widest, (String(line) as NSString).size(withAttributes: [.font: font]).width)
            }
        }

        // 有可靠气泡时从 OCR textBox 宽度起步；synthetic bubble 则从“可信原文
        // 覆盖范围”和译文自然宽度两者中的较大值起步。病态 OCR 框不会进入
        // minimumSourceCoverageRect，因此不会重新产生超宽的 translation rect。
        let minimumCoverageWidth = coverageRect.map { max($0.width + padding * 2, 1) } ?? 0
        let minimumCoverageHeight = coverageRect.map { max($0.height + padding * 2, 1) } ?? 0
        let minimumWidth = useSourceRectAsMinimumExtent
            ? max(sourceRect.width + padding * 2, 1)
            : minimumCoverageWidth
        let initialWidth: CGFloat
        if useSourceRectAsMinimumExtent {
            // detected bubble 沿用原有策略：先从 OCR textBox 宽度起步，
            // 保持原文字中心；只有放不下时才扩展到允许范围。
            initialWidth = min(minimumWidth, safeBounds.width)
        } else {
            initialWidth = min(
                max(measuredNaturalWidth(fontSize: targetFontSize) + padding * 2, minimumWidth),
                safeBounds.width
            )
        }

        // 原 textBox / validated source coverage 本身可能几乎占满允许区域。此时仍优先
        // 让实际文字测量结果决定额外高度，不因为 padding 把本来可显示的译文判为无法容纳。
        let minimumHeightValue = useSourceRectAsMinimumExtent
            ? max(sourceRect.height + padding * 2, 1)
            : minimumCoverageHeight
        let minimumHeight = min(minimumHeightValue, safeBounds.height)

        func measuredHeight(fontSize: CGFloat, contentWidth: CGFloat) -> CGFloat {
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineBreakMode = .byWordWrapping
            paragraphStyle.alignment = .center
            paragraphStyle.lineSpacing = lineSpacing
            let measured = (text as NSString).boundingRect(
                with: CGSize(width: max(contentWidth, 1), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [
                    .font: UIFont.systemFont(ofSize: fontSize, weight: .bold),
                    .paragraphStyle: paragraphStyle
                ],
                context: nil
            ).integral.size
            return max(minimumHeight, measured.height + padding * 2)
        }

        func rect(width: CGFloat, height: CGFloat) -> CGRect {
            CGRect(
                x: anchor.x - width / 2,
                y: anchor.y - height / 2,
                width: width,
                height: height
            )
        }

        func layout(fontSize: CGFloat, width: CGFloat) -> TranslationLayout? {
            let height = measuredHeight(fontSize: fontSize, contentWidth: max(width - padding * 2, 1))
            guard height <= safeBounds.height else { return nil }
            // clamped 只会在气泡超出允许区域时产生最小位移，绝不缩短已测量的宽高。
            return TranslationLayout(
                rect: clamped(rect(width: width, height: height), to: safeBounds, margin: 0),
                fontSize: fontSize
            )
        }

        // 优先级：原字号 + 原中心；原字号 + 最小必要位移；最后才缩字号。
        if let anchored = layout(fontSize: targetFontSize, width: initialWidth) {
            return anchored
        }
        if layout(fontSize: targetFontSize, width: safeBounds.width) != nil {
            var lowerWidth = initialWidth
            var upperWidth = safeBounds.width
            for _ in 0..<12 {
                let candidateWidth = (lowerWidth + upperWidth) / 2
                if layout(fontSize: targetFontSize, width: candidateWidth) != nil {
                    upperWidth = candidateWidth
                } else {
                    lowerWidth = candidateWidth
                }
            }
            return layout(fontSize: targetFontSize, width: upperWidth)!
        }

        // 宽度已扩到允许上限后再找真正能放下文字的最大字号。不能以 60% 为硬下限，
        // 否则 SwiftUI 的 fixedSize 会让已知放不下的文字顶出气泡。
        let width = safeBounds.width
        let smallestFontSize: CGFloat = 0.1
        guard layout(fontSize: smallestFontSize, width: width) != nil else {
            // 病态文本仍不得突破漫画原气泡/allowedBounds。字号继续按既定策略缩到最小值；
            // 仅允许文字渲染自身退化，边框绝不能因为兜底分支扩到漫画画面之外。
            return TranslationLayout(
                rect: safeBounds,
                fontSize: smallestFontSize
            )
        }

        var lower = smallestFontSize
        var upper = targetFontSize
        for _ in 0..<14 {
            let candidate = (lower + upper) / 2
            if layout(fontSize: candidate, width: width) != nil {
                lower = candidate
            } else {
                upper = candidate
            }
        }
        return layout(fontSize: lower, width: width)!
    }

    /// translationLines 是模型的建议换行而不是硬排版。在同一个 allowedBounds 内分别测量
    /// 自然换行和建议换行，优先保留能使用更大字号的版本，避免不必要的人工断行缩小文字。
    @MainActor
    static func preferredTranslationLayout(
        translation: String,
        translationLines: [String],
        sourceFontSize: CGFloat,
        sourceRect: CGRect,
        allowedBounds: CGRect,
        lineSpacing: CGFloat,
        padding: CGFloat = TranslationLayoutMetrics.contentPadding,
        textOrientation: TextOrientation = .horizontal,
        useSourceRectAsMinimumExtent: Bool = true,
        minimumSourceCoverageRect: CGRect? = nil
    ) -> TranslationLayoutChoice {
        let naturalText = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        if textOrientation == .vertical {
            let text = naturalText.isEmpty ? " " : naturalText
            return TranslationLayoutChoice(
                text: text,
                layout: anchoredTranslationLayout(
                    text: text,
                    sourceFontSize: sourceFontSize,
                    sourceRect: sourceRect,
                    allowedBounds: allowedBounds,
                    lineSpacing: lineSpacing,
                    padding: padding,
                    textOrientation: .vertical,
                    useSourceRectAsMinimumExtent: useSourceRectAsMinimumExtent,
                    minimumSourceCoverageRect: minimumSourceCoverageRect
                ),
                usesSuggestedLineBreaks: false
            )
        }

        let suggestedText = translationLines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        var candidates: [(text: String, usesSuggestedLineBreaks: Bool)] = [
            (naturalText.isEmpty ? " " : naturalText, false)
        ]
        if !suggestedText.isEmpty, suggestedText != naturalText {
            candidates.append((suggestedText, true))
        }

        func makeChoice(_ candidate: (text: String, usesSuggestedLineBreaks: Bool)) -> TranslationLayoutChoice {
            TranslationLayoutChoice(
                text: candidate.text,
                layout: anchoredTranslationLayout(
                    text: candidate.text,
                    sourceFontSize: sourceFontSize,
                    sourceRect: sourceRect,
                    allowedBounds: allowedBounds,
                    lineSpacing: lineSpacing,
                    padding: padding,
                    textOrientation: textOrientation,
                    useSourceRectAsMinimumExtent: useSourceRectAsMinimumExtent,
                    minimumSourceCoverageRect: minimumSourceCoverageRect
                ),
                usesSuggestedLineBreaks: candidate.usesSuggestedLineBreaks
            )
        }

        return candidates.dropFirst().reduce(makeChoice(candidates[0])) { best, candidate in
            let contender = makeChoice(candidate)
            if abs(best.layout.fontSize - contender.layout.fontSize) > 0.5 {
                return contender.layout.fontSize > best.layout.fontSize ? contender : best
            }
            let bestArea = best.layout.rect.width * best.layout.rect.height
            let contenderArea = contender.layout.rect.width * contender.layout.rect.height
            if abs(bestArea - contenderArea) > 1 {
                return contenderArea < bestArea ? contender : best
            }
            return contender.usesSuggestedLineBreaks ? contender : best
        }
    }

    /// Vision bubbleBox 与本地 OCR textBox 来自不同识别源，允许少量显示坐标误差。
    static func acceptsTranslationTextRect(
        _ textRect: CGRect,
        in bubbleRect: CGRect,
        toleranceX: CGFloat,
        toleranceY: CGFloat
    ) -> Bool {
        guard !textRect.isNull, !bubbleRect.isNull,
              textRect.width > 0, textRect.height > 0,
              bubbleRect.width > 0, bubbleRect.height > 0 else {
            return false
        }
        return bubbleRect.insetBy(
            dx: -max(toleranceX, 0),
            dy: -max(toleranceY, 0)
        ).contains(textRect)
    }

    /// 将模型给出的 bubbleBox 收口为可用于翻译布局的可靠边界。
    /// 除了容纳 textRect，还拒绝明显越出图片或几乎覆盖整页的病态框。
    static func reliableTranslationBubbleBounds(
        _ bubbleRect: CGRect?,
        textRect: CGRect,
        imageBounds: CGRect,
        toleranceX: CGFloat,
        toleranceY: CGFloat
    ) -> CGRect? {
        let safeImageBounds = imageBounds.standardized
        guard let bubbleRect,
              safeImageBounds.width > 0,
              safeImageBounds.height > 0 else {
            return nil
        }

        let safeBubble = bubbleRect.standardized
        let safeTextRect = textRect.standardized
        guard safeBubble.width > 0,
              safeBubble.height > 0,
              safeTextRect.width > 0,
              safeTextRect.height > 0,
              safeImageBounds.insetBy(
                  dx: -max(toleranceX, 0),
                  dy: -max(toleranceY, 0)
              ).contains(safeBubble),
              acceptsTranslationTextRect(
                  safeTextRect,
                  in: safeBubble,
                  toleranceX: toleranceX,
                  toleranceY: toleranceY
              ) else {
            return nil
        }

        let isNearlyWholePage = safeBubble.width >= safeImageBounds.width * 0.96
            && safeBubble.height >= safeImageBounds.height * 0.96
        guard !isNearlyWholePage else { return nil }

        let bubbleArea = safeBubble.width * safeBubble.height
        let textArea = safeTextRect.width * safeTextRect.height
        let pageArea = safeImageBounds.width * safeImageBounds.height
        let bubbleToPageAreaRatio = bubbleArea / pageArea
        let bubbleToTextAreaRatio = bubbleArea / max(textArea, 1)
        let maximumAxisExpansion = max(
            safeBubble.width / max(safeTextRect.width, max(toleranceX, 1)),
            safeBubble.height / max(safeTextRect.height, max(toleranceY, 1))
        )
        // 这些是“允许自动字号”的保守上限，而不是气泡绘制上限；超过任一
        // 条件就回退到无气泡字号，避免一个异常大框重新放大译文。
        guard bubbleToPageAreaRatio <= 0.72,
              bubbleToTextAreaRatio <= 48,
              maximumAxisExpansion <= 18 else {
            return nil
        }

        let centerDistance = hypot(
            safeBubble.midX - safeTextRect.midX,
            safeBubble.midY - safeTextRect.midY
        )
        let maximumCenterDistance = hypot(safeBubble.width, safeBubble.height) * 0.55
            + max(toleranceX, toleranceY)
        guard centerDistance <= maximumCenterDistance else { return nil }

        let clipped = safeBubble.intersection(safeImageBounds)
        return clipped.width > 0 && clipped.height > 0 ? clipped : nil
    }

    /// 兼容旧调用；离线翻译改用 anchoredTranslationLayout，以 textBox 为锚点。
    @MainActor
    static func measuredBubbleRect(
        text: String,
        fontSize: CGFloat,
        sourceRect: CGRect,
        bounds: CGRect,
        maximumWidth: CGFloat,
        lineSpacing: CGFloat,
        margin: CGFloat = 12
    ) -> CGRect {
        let insetBounds = bounds.insetBy(dx: margin, dy: margin)
        let allowed = insetBounds.intersection(
            CGRect(
                x: sourceRect.midX - maximumWidth / 2,
                y: insetBounds.minY,
                width: maximumWidth,
                height: insetBounds.height
            )
        )
        return anchoredTranslationLayout(
            text: text,
            sourceFontSize: fontSize,
            sourceRect: sourceRect,
            allowedBounds: allowed.isNull ? insetBounds : allowed,
            lineSpacing: lineSpacing
        ).rect
    }

    static func clamped(
        _ rect: CGRect,
        to bounds: CGRect,
        margin: CGFloat = 12
    ) -> CGRect {
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return rect }
        let availableWidth = max(bounds.width - margin * 2, 1)
        let availableHeight = max(bounds.height - margin * 2, 1)
        let width = min(rect.width, availableWidth)
        let height = min(rect.height, availableHeight)
        let centerX = min(
            max(rect.midX, bounds.minX + margin + width / 2),
            bounds.maxX - margin - width / 2
        )
        let centerY = min(
            max(rect.midY, bounds.minY + margin + height / 2),
            bounds.maxY - margin - height / 2
        )
        return CGRect(
            x: centerX - width / 2,
            y: centerY - height / 2,
            width: width,
            height: height
        )
    }

    private static func orientedShortAxis(of points: [CGPoint]) -> CGFloat? {
        guard points.count >= 3 else { return nil }

        var best: CGFloat?
        for firstIndex in points.indices {
            for secondIndex in points.indices where secondIndex > firstIndex {
                let dx = points[secondIndex].x - points[firstIndex].x
                let dy = points[secondIndex].y - points[firstIndex].y
                let length = hypot(dx, dy)
                guard length > 0.001 else { continue }
                let angle = atan2(dy, dx)
                let cosine = cos(angle)
                let sine = sin(angle)
                var minimumAlong = CGFloat.greatestFiniteMagnitude
                var maximumAlong = -CGFloat.greatestFiniteMagnitude
                var minimumAcross = CGFloat.greatestFiniteMagnitude
                var maximumAcross = -CGFloat.greatestFiniteMagnitude
                for point in points {
                    let along = point.x * cosine + point.y * sine
                    let across = -point.x * sine + point.y * cosine
                    minimumAlong = min(minimumAlong, along)
                    maximumAlong = max(maximumAlong, along)
                    minimumAcross = min(minimumAcross, across)
                    maximumAcross = max(maximumAcross, across)
                }
                let width = maximumAlong - minimumAlong
                let height = maximumAcross - minimumAcross
                guard width > 0.001, height > 0.001 else { continue }
                let shortAxis = min(width, height)
                best = min(best ?? shortAxis, shortAxis)
            }
        }
        return best
    }

    /// Measures a vertical translation as columns of glyph advances. CoreText
    /// performs the actual vertical-form shaping in the renderer; this method
    /// supplies the same bounded geometry without inserting a newline between
    /// every character or rotating a horizontal text view.
    @MainActor
    private static func anchoredVerticalTranslationLayout(
        text: String,
        sourceFontSize: CGFloat,
        sourceRect: CGRect,
        allowedBounds: CGRect,
        padding: CGFloat,
        useSourceRectAsMinimumExtent: Bool,
        minimumSourceCoverageRect: CGRect?
    ) -> TranslationLayout {
        let safeBounds = allowedBounds.standardized
        guard safeBounds.width > 0, safeBounds.height > 0 else {
            return TranslationLayout(rect: sourceRect, fontSize: max(sourceFontSize, 1))
        }

        let coverageRect: CGRect?
        if let minimumSourceCoverageRect {
            let intersection = minimumSourceCoverageRect.standardized.intersection(safeBounds)
            coverageRect = intersection.width > 0 && intersection.height > 0 ? intersection : nil
        } else {
            coverageRect = nil
        }
        let anchorRect = coverageRect ?? sourceRect
        let anchor = CGPoint(
            x: min(max(anchorRect.midX, safeBounds.minX), safeBounds.maxX),
            y: min(max(anchorRect.midY, safeBounds.minY), safeBounds.maxY)
        )
        let glyphCount = max(text.filter { !$0.isWhitespace && $0 != "\n" }.count, 1)
        let targetFontSize = max(sourceFontSize, 1)

        func layout(fontSize: CGFloat) -> TranslationLayout? {
            let advance = max(fontSize * TranslationLayoutMetrics.verticalAdvanceMultiplier, 1)
            let columnWidth = max(fontSize * TranslationLayoutMetrics.verticalColumnWidthMultiplier, 1)
            let availableHeight = max(safeBounds.height - padding * 2, advance)
            let rows = max(Int(floor(availableHeight / advance)), 1)
            let columns = max(Int(ceil(Double(glyphCount) / Double(rows))), 1)
            let measuredColumnsWidth = CGFloat(columns) * columnWidth + padding * 2
            let minimumCoverageWidth = coverageRect?.width ?? 0
            let minimumWidth = useSourceRectAsMinimumExtent
                ? max(sourceRect.width + padding * 2, 1)
                : max(minimumCoverageWidth + padding * 2, 1)
            let width = min(
                safeBounds.width,
                max(minimumWidth, measuredColumnsWidth)
            )
            let usedRows = min(rows, Int(ceil(Double(glyphCount) / Double(columns))))
            let measuredRowsHeight = CGFloat(usedRows) * advance + padding * 2
            let minimumCoverageHeight = coverageRect?.height ?? 0
            let minimumHeight = useSourceRectAsMinimumExtent
                ? max(sourceRect.height + padding * 2, 1)
                : max(minimumCoverageHeight + padding * 2, 1)
            let height = min(
                safeBounds.height,
                max(minimumHeight, measuredRowsHeight)
            )
            guard width >= CGFloat(columns) * columnWidth + padding * 2 - 0.5,
                  height >= CGFloat(usedRows) * advance + padding * 2 - 0.5 else {
                return nil
            }
            let rect = CGRect(
                x: anchor.x - width / 2,
                y: anchor.y - height / 2,
                width: width,
                height: height
            )
            return TranslationLayout(
                rect: clamped(rect, to: safeBounds, margin: 0),
                fontSize: fontSize
            )
        }

        if let result = layout(fontSize: targetFontSize) {
            return result
        }

        var lower: CGFloat = 0.1
        var upper = targetFontSize
        if layout(fontSize: lower) == nil {
            return TranslationLayout(rect: safeBounds, fontSize: lower)
        }
        for _ in 0..<16 {
            let candidate = (lower + upper) / 2
            if layout(fontSize: candidate) != nil {
                lower = candidate
            } else {
                upper = candidate
            }
        }
        return layout(fontSize: lower) ?? TranslationLayout(rect: safeBounds, fontSize: lower)
    }

    static func nonOverlappingRect(
        _ original: CGRect,
        anchor: CGPoint,
        occupiedRects: [CGRect],
        bounds: CGRect,
        margin: CGFloat = 12
    ) -> CGRect {
        let clampedOriginal = clamped(original, to: bounds, margin: margin)
        guard occupiedRects.contains(where: { $0.intersects(clampedOriginal) }) else {
            return clampedOriginal
        }

        let stepY = max(original.height * 0.85, 22)
        let stepX = max(original.width * 0.45, 32)
        var candidates: [CGRect] = []
        for distance in 1...6 {
            let dy = CGFloat(distance) * stepY
            let dx = CGFloat(distance) * stepX
            candidates.append(original.offsetBy(dx: 0, dy: -dy))
            candidates.append(original.offsetBy(dx: 0, dy: dy))
            candidates.append(original.offsetBy(dx: -dx, dy: 0))
            candidates.append(original.offsetBy(dx: dx, dy: 0))
            candidates.append(original.offsetBy(dx: -dx * 0.65, dy: -dy * 0.65))
            candidates.append(original.offsetBy(dx: dx * 0.65, dy: -dy * 0.65))
            candidates.append(original.offsetBy(dx: -dx * 0.65, dy: dy * 0.65))
            candidates.append(original.offsetBy(dx: dx * 0.65, dy: dy * 0.65))
        }

        return candidates
            .map { clamped($0, to: bounds, margin: margin) }
            .min { layoutScore($0, anchor: anchor, occupiedRects: occupiedRects) < layoutScore($1, anchor: anchor, occupiedRects: occupiedRects) }
            ?? clampedOriginal
    }

    private static func layoutScore(
        _ rect: CGRect,
        anchor: CGPoint,
        occupiedRects: [CGRect]
    ) -> CGFloat {
        let overlapPenalty = occupiedRects.reduce(CGFloat.zero) { partial, occupied in
            let overlap = rect.intersection(occupied)
            guard !overlap.isNull else { return partial }
            return partial + overlap.width * overlap.height * 90
        }
        return hypot(rect.midX - anchor.x, rect.midY - anchor.y) + overlapPenalty
    }
}
