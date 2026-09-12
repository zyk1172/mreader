import CoreText
import Foundation
import UIKit

/// Shared translation text layout contract used by both measurement and drawing.
///
/// The caller owns the outer card/padding geometry. This typesetter receives the
/// exact content rectangle size that will later be given to the renderer, so a
/// layout is only considered fitted when CoreText can actually expose the full
/// UTF-16 string in that same rectangle.
nonisolated enum TranslationTypesetter {
    struct Measurement: Sendable, Equatable {
        let usedSize: CGSize
        let visibleUTF16Length: Int
        let totalUTF16Length: Int

        var fitsAllText: Bool {
            visibleUTF16Length >= totalUTF16Length
        }
    }

    @MainActor
    static func measurement(
        text: String,
        fontSize: CGFloat,
        bounds: CGSize,
        orientation: TextOrientation,
        lineSpacing: CGFloat
    ) -> Measurement {
        let safeBounds = CGSize(
            width: max(bounds.width, 1),
            height: max(bounds.height, 1)
        )
        let attributed = attributedString(
            text: text,
            fontSize: fontSize,
            orientation: orientation,
            lineSpacing: lineSpacing,
            color: .label
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let frame = makeFrame(
            framesetter: framesetter,
            length: attributed.length,
            bounds: safeBounds,
            orientation: orientation
        )
        let visibleRange = CTFrameGetVisibleStringRange(frame)
        let visibleEnd = max(0, visibleRange.location + visibleRange.length)

        let usedSize: CGSize
        if orientation == .horizontal {
            var fitRange = CFRange()
            let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter,
                CFRange(location: 0, length: attributed.length),
                nil,
                CGSize(width: safeBounds.width, height: .greatestFiniteMagnitude),
                &fitRange
            )
            usedSize = CGSize(
                width: ceil(min(max(suggested.width, 0), safeBounds.width)),
                height: ceil(max(suggested.height, 0))
            )
        } else {
            // Vertical used bounds are intentionally conservative. Exact fit is
            // decided by CTFrameGetVisibleStringRange rather than a glyph-grid
            // estimate, which is the correctness condition this type exists for.
            usedSize = safeBounds
        }

        return Measurement(
            usedSize: usedSize,
            visibleUTF16Length: min(visibleEnd, attributed.length),
            totalUTF16Length: attributed.length
        )
    }

    @MainActor
    static func horizontalMeasuredSize(
        text: String,
        fontSize: CGFloat,
        maximumWidth: CGFloat,
        lineSpacing: CGFloat
    ) -> CGSize {
        let width = max(maximumWidth, 1)
        let attributed = attributedString(
            text: text,
            fontSize: fontSize,
            orientation: .horizontal,
            lineSpacing: lineSpacing,
            color: .label
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        var fitRange = CFRange()
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: attributed.length),
            nil,
            CGSize(width: width, height: .greatestFiniteMagnitude),
            &fitRange
        )
        return CGSize(
            width: ceil(min(max(suggested.width, 0), width)),
            height: ceil(max(suggested.height, 1))
        )
    }

    @MainActor
    static func draw(
        text: String,
        in bounds: CGRect,
        context: CGContext,
        fontSize: CGFloat,
        orientation: TextOrientation,
        lineSpacing: CGFloat,
        color: UIColor
    ) {
        guard !text.isEmpty, bounds.width > 0, bounds.height > 0 else { return }
        let attributed = attributedString(
            text: text,
            fontSize: fontSize,
            orientation: orientation,
            lineSpacing: lineSpacing,
            color: color
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let frame = makeFrame(
            framesetter: framesetter,
            length: attributed.length,
            bounds: bounds.size,
            orientation: orientation
        )

        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: bounds.minX, y: bounds.maxY)
        context.scaleBy(x: 1, y: -1)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    @MainActor
    private static func attributedString(
        text: String,
        fontSize: CGFloat,
        orientation: TextOrientation,
        lineSpacing: CGFloat,
        color: UIColor
    ) -> NSAttributedString {
        let safeFontSize = max(fontSize, 1)
        let uiFont = UIFont.systemFont(ofSize: safeFontSize, weight: .bold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = lineSpacing
        paragraph.lineBreakMode = orientation == .vertical ? .byCharWrapping : .byWordWrapping

        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: uiFont,
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
        )
        if orientation == .vertical, attributed.length > 0 {
            attributed.addAttribute(
                NSAttributedString.Key(kCTVerticalFormsAttributeName as String),
                value: true,
                range: NSRange(location: 0, length: attributed.length)
            )
        }
        return attributed
    }

    @MainActor
    private static func makeFrame(
        framesetter: CTFramesetter,
        length: Int,
        bounds: CGSize,
        orientation: TextOrientation
    ) -> CTFrame {
        let path = CGPath(
            rect: CGRect(
                origin: .zero,
                size: CGSize(width: max(bounds.width, 1), height: max(bounds.height, 1))
            ),
            transform: nil
        )
        let attributes: CFDictionary?
        if orientation == .vertical {
            attributes = [
                NSAttributedString.Key(kCTFrameProgressionAttributeName as String): NSNumber(value: 1)
            ] as CFDictionary
        } else {
            attributes = nil
        }
        return CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: length),
            path,
            attributes
        )
    }
}
