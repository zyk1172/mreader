import CoreGraphics
import Foundation
import UIKit

nonisolated enum OCRBubbleLayoutEngine {
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
        max(sourceFontSize, 1)
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
        guard block.bubbleBox == nil else { return sourceFontSize }

        let glyphCount = max(block.text.filter { !$0.isWhitespace }.count, 1)
        let areaPerGlyph = sqrt(
            max(textRect.width * textRect.height, 1) / CGFloat(glyphCount)
        )
        var candidates = [sourceFontSize, areaPerGlyph]

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
    static func anchoredTranslationLayout(
        text: String,
        sourceFontSize: CGFloat,
        sourceRect: CGRect,
        allowedBounds: CGRect,
        lineSpacing: CGFloat,
        padding: CGFloat = 5
    ) -> TranslationLayout {
        let safeBounds = allowedBounds.standardized
        guard safeBounds.width > 0, safeBounds.height > 0 else {
            return TranslationLayout(rect: sourceRect, fontSize: max(sourceFontSize, 1))
        }

        let anchor = CGPoint(
            x: min(max(sourceRect.midX, safeBounds.minX), safeBounds.maxX),
            y: min(max(sourceRect.midY, safeBounds.minY), safeBounds.maxY)
        )
        let targetFontSize = preferredTranslationFontSize(sourceFontSize: sourceFontSize)
        let initialWidth = min(max(sourceRect.width + padding * 2, 1), safeBounds.width)
        // 原 textBox 本身可能几乎占满模型给出的 bubbleBox。此时仍优先让实际文字测量结果决定高度，
        // 不因为 padding 把本来可显示的译文错误判为无法容纳。
        let minimumHeight = min(
            max(sourceRect.height + padding * 2, 1),
            safeBounds.height
        )

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
        padding: CGFloat = 5
    ) -> TranslationLayoutChoice {
        let naturalText = translation.trimmingCharacters(in: .whitespacesAndNewlines)
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
                    padding: padding
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
