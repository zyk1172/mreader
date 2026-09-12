import CoreGraphics
import Foundation
import UIKit

/// 译文表面样式：决定译文卡片的几何来源。
///
/// 这是与 `TranslationLayoutRole` 正交的维度。`layoutRole` 描述文字的语义类别
/// （对白 / 旁白 / 音效），而 `surfaceStyle` 只回答一个问题：
/// **译文卡片应该使用真实气泡边界，还是使用最终译文的测量结果？**
///
/// 两种表面都会绘制背景和边框，区别只在卡片尺寸的来源：
/// 可靠 `bubbleBox` 使用真实漫画气泡约束；没有可靠 `bubbleBox` 时使用最终译文
/// 的实际排版范围，OCR 矩形只能作为位置锚点。
nonisolated enum TranslationSurfaceStyle: String, Sendable, Codable, CaseIterable, Hashable {
    /// 存在经过验证的真实漫画气泡，背景沿用该气泡范围。
    case detectedBubble
    /// 没有可靠漫画气泡，卡片尺寸由最终译文的测量结果决定。
    case measuredText

    var drawsBackground: Bool {
        true
    }

    /// 两种表面使用相同的视觉样式；它们只采用不同的卡片几何策略。
    var backgroundOpacity: Double {
        0.50
    }

    var borderOpacity: Double {
        0.86
    }

    var cornerRadius: CGFloat {
        7
    }
}

nonisolated enum TranslationSurfacePolicy {
    /// 唯一入口：可靠气泡与 measured text 都是带背景的译文表面。
    ///
    /// `hasReliableBubble` 必须来自 `OCRBubbleLayoutEngine.reliableTranslationBubbleBounds`
    /// 的判定结果——它已经排除了 bubbleBox 缺失、越界、覆盖整页等病态情况。
    ///
    /// 有可靠气泡 → `.detectedBubble`；没有可靠气泡 → `.measuredText`。
    static func surfaceStyle(hasReliableBubble: Bool) -> TranslationSurfaceStyle {
        hasReliableBubble ? .detectedBubble : .measuredText
    }
}

/// The translation overlay deliberately renders every surface before every
/// glyph. This remains true even when two layout items overlap (for example
/// while an offline result is being shown).
nonisolated enum TranslationSurfaceLayering {
    static let surfaceZIndex: Double = 0
    static let textZIndex: Double = 1
}

/// 可见译文卡片的几何来源。显式传入它，避免调用方漏传参数而意外把
/// measured-text 译文当成需要填满 OCR 框的 detected bubble。
nonisolated enum TranslationLayoutStrategy: Sendable, Equatable {
    case detectedBubble
    case measuredText

    var usesSourceRectAsMinimumExtent: Bool {
        self == .detectedBubble
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

    enum TranslationLayoutStatus: String, Sendable, Equatable {
        case fitted
        case needsExpansion
    }

    struct TranslationLayout: Sendable {
        let rect: CGRect
        /// `contentRect` is the exact rectangle passed to TranslationTypesetter
        /// for both measurement and drawing.
        let contentRect: CGRect
        let fontSize: CGFloat
        let contentPadding: CGFloat
        let status: TranslationLayoutStatus

        init(
            rect: CGRect,
            contentRect: CGRect,
            fontSize: CGFloat,
            contentPadding: CGFloat,
            status: TranslationLayoutStatus = .fitted
        ) {
            self.rect = rect
            self.contentRect = contentRect
            self.fontSize = fontSize
            self.contentPadding = contentPadding
            self.status = status
        }

        init(
            rect: CGRect,
            fontSize: CGFloat,
            contentPadding: CGFloat,
            status: TranslationLayoutStatus = .fitted
        ) {
            self.init(
                rect: rect,
                contentRect: rect.insetBy(dx: contentPadding, dy: contentPadding),
                fontSize: fontSize,
                contentPadding: contentPadding,
                status: status
            )
        }
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

    /// 有可靠气泡时沿用 OCR 几何字号；没有可靠气泡时，OCR 框不参与字号决策，
    /// 改用用户设置的 measured-text 字号。
    /// 后续布局仍会在 allowedBounds 内按实际文本测量结果缩小字号。
    static func requestedTranslationFontSize(
        hasReliableBubble: Bool,
        automaticFontSize: CGFloat,
        measuredTextFontSize: CGFloat
    ) -> CGFloat {
        guard !hasReliableBubble else {
            return preferredTranslationFontSize(sourceFontSize: automaticFontSize)
        }
        return CGFloat(
            ComicBook.clampedMeasuredTextTranslationFontSize(Double(measuredTextFontSize))
        )
    }

    /// measuredText 卡片每一边的 padding。这个值必须由最终字号重新计算，不能
    /// 使用 OCR 框尺寸，也不能固定复用 detected bubble 的 5pt padding。
    static func measuredTextCardPadding(
        fontSize: CGFloat,
        textOrientation: TextOrientation
    ) -> CGFloat {
        let safeFontSize = max(fontSize, 0.1)
        switch textOrientation {
        case .horizontal:
            let font = UIFont.systemFont(ofSize: safeFontSize, weight: .bold)
            return max(font.lineHeight * 0.5, 0)
        case .vertical:
            let glyphHeight = safeFontSize * TranslationLayoutMetrics.verticalAdvanceMultiplier
            return max(glyphHeight * 0.5, 0)
        }
    }

    /// Horizontal measurement uses the same CoreText attributed string and
    /// line-breaking contract as the renderer.
    @MainActor
    static func measuredHorizontalTextSize(
        _ text: String,
        fontSize: CGFloat,
        maximumWidth: CGFloat,
        lineSpacing: CGFloat
    ) -> CGSize {
        TranslationTypesetter.horizontalMeasuredSize(
            text: text,
            fontSize: fontSize,
            maximumWidth: maximumWidth,
            lineSpacing: lineSpacing
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
    /// 这是"是否允许绘制气泡背景"的端到端判定入口：气泡存在性在布局层得到后，
    /// 必须由渲染层消费。ReaderView 已经算过 `usableTranslationBubbleBounds` 时会
    /// 直接复用该结果再套 policy；本函数供尚未持有该结果（以及测试）的场景使用，
    /// 判定组件完全相同。
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

    @MainActor
    /// - Parameter geometryStrategy: detected bubble uses the OCR text box as
    ///   its minimum extent; measuredText uses only the translated text.
    static func anchoredTranslationLayout(
        text: String,
        sourceFontSize: CGFloat,
        sourceRect: CGRect,
        allowedBounds: CGRect,
        lineSpacing: CGFloat,
        padding: CGFloat = TranslationLayoutMetrics.contentPadding,
        textOrientation: TextOrientation = .horizontal,
        geometryStrategy: TranslationLayoutStrategy,
        minimumReadableFontSize: CGFloat = CGFloat(ComicBook.defaultMinimumReadableTranslationFontSize)
    ) -> TranslationLayout {
        let readableFloor = max(minimumReadableFontSize, 1)
        let useSourceRectAsMinimumExtent = geometryStrategy.usesSourceRectAsMinimumExtent
        if textOrientation == .vertical {
            return anchoredVerticalTranslationLayout(
                text: text,
                sourceFontSize: sourceFontSize,
                sourceRect: sourceRect,
                allowedBounds: allowedBounds,
                padding: padding,
                lineSpacing: lineSpacing,
                geometryStrategy: geometryStrategy,
                minimumReadableFontSize: readableFloor
            )
        }

        let safeBounds = allowedBounds.standardized
        let targetFontSize = max(
            preferredTranslationFontSize(sourceFontSize: sourceFontSize),
            readableFloor
        )
        func effectivePadding(_ fontSize: CGFloat) -> CGFloat {
            useSourceRectAsMinimumExtent
                ? max(padding, 0)
                : measuredTextCardPadding(fontSize: fontSize, textOrientation: .horizontal)
        }

        guard safeBounds.width > 0, safeBounds.height > 0 else {
            let p = effectivePadding(readableFloor)
            return TranslationLayout(
                rect: sourceRect,
                fontSize: readableFloor,
                contentPadding: p,
                status: .needsExpansion
            )
        }

        let anchor = CGPoint(
            x: min(max(sourceRect.midX, safeBounds.minX), safeBounds.maxX),
            y: min(max(sourceRect.midY, safeBounds.minY), safeBounds.maxY)
        )

        func fittedLayout(fontSize: CGFloat) -> TranslationLayout? {
            let p = effectivePadding(fontSize)
            let maximumContentWidth = max(safeBounds.width - p * 2, 1)
            let measured = TranslationTypesetter.horizontalMeasuredSize(
                text: text,
                fontSize: fontSize,
                maximumWidth: maximumContentWidth,
                lineSpacing: lineSpacing
            )
            let contentWidth = min(max(measured.width, 1), maximumContentWidth)
            let minimumCardWidth = useSourceRectAsMinimumExtent
                ? min(max(sourceRect.width + p * 2, 1), safeBounds.width)
                : 0
            let minimumCardHeight = useSourceRectAsMinimumExtent
                ? min(max(sourceRect.height + p * 2, 1), safeBounds.height)
                : 0
            let cardWidth = min(max(contentWidth + p * 2, minimumCardWidth), safeBounds.width)
            let cardHeight = max(measured.height + p * 2, minimumCardHeight)
            guard cardHeight <= safeBounds.height + 0.5 else { return nil }

            let proposed = CGRect(
                x: anchor.x - cardWidth / 2,
                y: anchor.y - cardHeight / 2,
                width: cardWidth,
                height: cardHeight
            )
            let cardRect = clamped(proposed, to: safeBounds, margin: 0)
            let contentRect = cardRect.insetBy(dx: p, dy: p)
            guard contentRect.width > 0, contentRect.height > 0 else { return nil }
            let measurement = TranslationTypesetter.measurement(
                text: text,
                fontSize: fontSize,
                bounds: contentRect.size,
                orientation: .horizontal,
                lineSpacing: lineSpacing
            )
            guard measurement.fitsAllText else { return nil }
            return TranslationLayout(
                rect: cardRect,
                contentRect: contentRect,
                fontSize: fontSize,
                contentPadding: p
            )
        }

        if let target = fittedLayout(fontSize: targetFontSize) {
            return target
        }
        if let floor = fittedLayout(fontSize: readableFloor) {
            if targetFontSize <= readableFloor + 0.01 { return floor }
            var lower = readableFloor
            var upper = targetFontSize
            for _ in 0..<14 {
                let candidate = (lower + upper) / 2
                if fittedLayout(fontSize: candidate) != nil {
                    lower = candidate
                } else {
                    upper = candidate
                }
            }
            return fittedLayout(fontSize: lower) ?? floor
        }

        // Never continue below the user-selected readability floor. The full
        // canonical translation remains available through the expansion UI.
        let p = effectivePadding(readableFloor)
        return TranslationLayout(
            rect: safeBounds,
            contentRect: safeBounds.insetBy(dx: p, dy: p),
            fontSize: readableFloor,
            contentPadding: p,
            status: .needsExpansion
        )
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
        geometryStrategy: TranslationLayoutStrategy,
        minimumReadableFontSize: CGFloat = CGFloat(ComicBook.defaultMinimumReadableTranslationFontSize)
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
                    geometryStrategy: geometryStrategy,
                    minimumReadableFontSize: minimumReadableFontSize
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
                    geometryStrategy: geometryStrategy,
                    minimumReadableFontSize: minimumReadableFontSize
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
            lineSpacing: lineSpacing,
            geometryStrategy: .detectedBubble
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

    /// Vertical layout proposes compact geometry, but CoreText is the final
    /// authority for whether every UTF-16 code unit is actually visible.
    @MainActor
    private static func anchoredVerticalTranslationLayout(
        text: String,
        sourceFontSize: CGFloat,
        sourceRect: CGRect,
        allowedBounds: CGRect,
        padding: CGFloat,
        lineSpacing: CGFloat,
        geometryStrategy: TranslationLayoutStrategy,
        minimumReadableFontSize: CGFloat
    ) -> TranslationLayout {
        let useSourceRectAsMinimumExtent = geometryStrategy.usesSourceRectAsMinimumExtent
        let readableFloor = max(minimumReadableFontSize, 1)
        let safeBounds = allowedBounds.standardized
        let targetFontSize = max(
            preferredTranslationFontSize(sourceFontSize: sourceFontSize),
            readableFloor
        )
        func effectivePadding(_ fontSize: CGFloat) -> CGFloat {
            useSourceRectAsMinimumExtent
                ? max(padding, 0)
                : measuredTextCardPadding(fontSize: fontSize, textOrientation: .vertical)
        }

        guard safeBounds.width > 0, safeBounds.height > 0 else {
            let p = effectivePadding(readableFloor)
            return TranslationLayout(
                rect: sourceRect,
                fontSize: readableFloor,
                contentPadding: p,
                status: .needsExpansion
            )
        }

        let anchor = CGPoint(
            x: min(max(sourceRect.midX, safeBounds.minX), safeBounds.maxX),
            y: min(max(sourceRect.midY, safeBounds.minY), safeBounds.maxY)
        )
        let glyphCount = max(text.filter { !$0.isWhitespace && $0 != "
" }.count, 1)

        func makeLayout(fontSize: CGFloat, forceFullBounds: Bool) -> TranslationLayout? {
            let p = effectivePadding(fontSize)
            let cardRect: CGRect
            if forceFullBounds {
                cardRect = safeBounds
            } else {
                // Keep the old grid only as a compact-size proposal. It is no
                // longer allowed to declare success; CoreText below does that.
                let advance = max(fontSize * TranslationLayoutMetrics.verticalAdvanceMultiplier, 1)
                let columnWidth = max(fontSize * TranslationLayoutMetrics.verticalColumnWidthMultiplier, 1)
                let availableHeight = max(safeBounds.height - p * 2, advance)
                let rows = max(Int(floor(availableHeight / advance)), 1)
                let columns = max(Int(ceil(Double(glyphCount) / Double(rows))), 1)
                let usedRows = min(rows, Int(ceil(Double(glyphCount) / Double(columns))))
                let proposedWidth = CGFloat(columns) * columnWidth + p * 2
                let proposedHeight = CGFloat(usedRows) * advance + p * 2
                let minimumWidth = useSourceRectAsMinimumExtent ? sourceRect.width + p * 2 : 0
                let minimumHeight = useSourceRectAsMinimumExtent ? sourceRect.height + p * 2 : 0
                let width = min(max(proposedWidth, minimumWidth, 1), safeBounds.width)
                let height = min(max(proposedHeight, minimumHeight, 1), safeBounds.height)
                cardRect = clamped(
                    CGRect(
                        x: anchor.x - width / 2,
                        y: anchor.y - height / 2,
                        width: width,
                        height: height
                    ),
                    to: safeBounds,
                    margin: 0
                )
            }
            let contentRect = cardRect.insetBy(dx: p, dy: p)
            guard contentRect.width > 0, contentRect.height > 0 else { return nil }
            let measurement = TranslationTypesetter.measurement(
                text: text,
                fontSize: fontSize,
                bounds: contentRect.size,
                orientation: .vertical,
                lineSpacing: lineSpacing
            )
            guard measurement.fitsAllText else { return nil }
            return TranslationLayout(
                rect: cardRect,
                contentRect: contentRect,
                fontSize: fontSize,
                contentPadding: p
            )
        }

        func fittedLayout(fontSize: CGFloat) -> TranslationLayout? {
            makeLayout(fontSize: fontSize, forceFullBounds: false)
                ?? makeLayout(fontSize: fontSize, forceFullBounds: true)
        }

        if let target = fittedLayout(fontSize: targetFontSize) {
            return target
        }
        if let floor = fittedLayout(fontSize: readableFloor) {
            if targetFontSize <= readableFloor + 0.01 { return floor }
            var lower = readableFloor
            var upper = targetFontSize
            for _ in 0..<16 {
                let candidate = (lower + upper) / 2
                if fittedLayout(fontSize: candidate) != nil {
                    lower = candidate
                } else {
                    upper = candidate
                }
            }
            return fittedLayout(fontSize: lower) ?? floor
        }

        let p = effectivePadding(readableFloor)
        return TranslationLayout(
            rect: safeBounds,
            contentRect: safeBounds.insetBy(dx: p, dy: p),
            fontSize: readableFloor,
            contentPadding: p,
            status: .needsExpansion
        )
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
