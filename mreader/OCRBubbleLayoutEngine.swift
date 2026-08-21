import CoreGraphics
import UIKit

nonisolated enum OCRBubbleLayoutEngine {
    struct TranslationLayout: Sendable {
        let rect: CGRect
        let fontSize: CGFloat
    }

    static func preferredTranslationFontSize(sourceFontSize: CGFloat) -> CGFloat {
        // 译文默认应接近原文字号；只在内容装不下时由 anchoredTranslationLayout 缩小。
        max(sourceFontSize * 0.98, 1)
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
        // 保持原文中心不变时能扩展到的最大范围；只有图片边缘无法容纳时才由 clamped 做最小位移。
        let maximumWidth = max(1, min(
            safeBounds.width,
            2 * min(anchor.x - safeBounds.minX, safeBounds.maxX - anchor.x)
        ))
        let maximumHeight = max(1, min(
            safeBounds.height,
            2 * min(anchor.y - safeBounds.minY, safeBounds.maxY - anchor.y)
        ))
        let targetFontSize = preferredTranslationFontSize(sourceFontSize: sourceFontSize)
        let initialWidth = min(max(sourceRect.width + padding * 2, 1), maximumWidth)

        func measuredSize(contentWidth: CGFloat) -> CGSize {
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineBreakMode = .byWordWrapping
            paragraphStyle.alignment = .center
            paragraphStyle.lineSpacing = lineSpacing
            let measured = (text as NSString).boundingRect(
                with: CGSize(width: max(contentWidth, 24), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [
                    .font: UIFont.systemFont(ofSize: targetFontSize, weight: .bold),
                    .paragraphStyle: paragraphStyle
                ],
                context: nil
            ).integral.size
            return CGSize(width: measured.width + padding * 2, height: measured.height + padding * 2)
        }

        func rect(width: CGFloat, height: CGFloat) -> CGRect {
            CGRect(
                x: anchor.x - width / 2,
                y: anchor.y - height / 2,
                width: width,
                height: height
            )
        }

        // 先保持字号，以原 textBox 为起点逐步扩展到 bubbleBox（或图片）允许的范围。
        let expansionSteps = 8
        for step in 0...expansionSteps {
            let progress = CGFloat(step) / CGFloat(expansionSteps)
            let width = initialWidth + (maximumWidth - initialWidth) * progress
            let measured = measuredSize(contentWidth: max(width - padding * 2, 1))
            let height = max(sourceRect.height + padding * 2, measured.height)
            guard height <= maximumHeight else { continue }
            return TranslationLayout(
                rect: clamped(rect(width: width, height: height), to: safeBounds, margin: 0),
                fontSize: targetFontSize
            )
        }

        // 可用区域已经扩到上限后才缩字号；最低约为原字号 60%，不再使用固定 pt 下限。
        let width = maximumWidth
        var lower = max(sourceFontSize * 0.60, 1)
        var upper = targetFontSize
        func fittingHeight(fontSize: CGFloat) -> CGFloat {
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineBreakMode = .byWordWrapping
            paragraphStyle.alignment = .center
            paragraphStyle.lineSpacing = lineSpacing
            let measured = (text as NSString).boundingRect(
                with: CGSize(width: max(width - padding * 2, 1), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [
                    .font: UIFont.systemFont(ofSize: fontSize, weight: .bold),
                    .paragraphStyle: paragraphStyle
                ],
                context: nil
            ).integral.size
            return max(sourceRect.height + padding * 2, measured.height + padding * 2)
        }
        for _ in 0..<10 {
            let candidate = (lower + upper) / 2
            if fittingHeight(fontSize: candidate) <= maximumHeight {
                lower = candidate
            } else {
                upper = candidate
            }
        }
        let finalHeight = min(fittingHeight(fontSize: lower), maximumHeight)
        return TranslationLayout(
            rect: clamped(rect(width: width, height: finalHeight), to: safeBounds, margin: 0),
            fontSize: lower
        )
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
