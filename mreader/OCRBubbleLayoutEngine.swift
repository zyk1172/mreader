import CoreGraphics
import UIKit

nonisolated enum OCRBubbleLayoutEngine {
    struct TranslationLayout: Sendable {
        let rect: CGRect
        let fontSize: CGFloat
    }

    static func preferredTranslationFontSize(sourceFontSize: CGFloat) -> CGFloat {
        // 第一轮必须严格沿用原文字号；只有确实装不下时才由 anchoredTranslationLayout 缩小。
        max(sourceFontSize, 1)
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
                with: CGSize(width: max(contentWidth, 24), height: .greatestFiniteMagnitude),
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
            // 只有病态超长文本才会到这里；宁可让气泡最后有限外扩，也不能返回被截断的高度。
            let height = measuredHeight(fontSize: smallestFontSize, contentWidth: max(width - padding * 2, 1))
            return TranslationLayout(
                rect: rect(width: width, height: height),
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

    /// Vision bubbleBox 与本地 OCR textBox 来自不同识别源，允许少量显示坐标误差。
    static func acceptsTranslationTextRect(
        _ textRect: CGRect,
        in bubbleRect: CGRect,
        tolerance: CGFloat = 3
    ) -> Bool {
        guard !textRect.isNull, !bubbleRect.isNull,
              textRect.width > 0, textRect.height > 0,
              bubbleRect.width > 0, bubbleRect.height > 0 else {
            return false
        }
        return bubbleRect.insetBy(dx: -max(tolerance, 0), dy: -max(tolerance, 0)).contains(textRect)
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
