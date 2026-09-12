from pathlib import Path
import re


def read(path):
    return Path(path).read_text()


def write(path, text):
    Path(path).write_text(text)


def replace_once(path, old, new):
    text = read(path)
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one exact match, found {count}")
    write(path, text.replace(old, new, 1))


def replace_regex(path, pattern, replacement):
    text = read(path)
    new_text, count = re.subn(pattern, replacement, text, count=1, flags=re.S)
    if count != 1:
        raise SystemExit(f"{path}: expected one regex match, found {count}: {pattern[:80]}")
    write(path, new_text)


# ---------------------------------------------------------------------------
# ComicBook: make the effective readability floor user-configurable per comic.
# ---------------------------------------------------------------------------
path = "mreader/ComicBook.swift"
replace_once(
    path,
    """    nonisolated static func clampedMeasuredTextTranslationFontSize(_ value: Double) -> Double {\n        clampedBorderlessTranslationFontSize(value)\n    }\n\n""",
    """    nonisolated static func clampedMeasuredTextTranslationFontSize(_ value: Double) -> Double {\n        clampedBorderlessTranslationFontSize(value)\n    }\n\n    /// Readability floor for in-page translation. This is a user preference,\n    /// not a claim that one point size is universally correct for every comic.\n    nonisolated static let defaultMinimumReadableTranslationFontSize = 9.0\n    nonisolated static let minimumReadableTranslationFontSizeRange: ClosedRange<Double> = 6...18\n\n    nonisolated static func clampedMinimumReadableTranslationFontSize(_ value: Double) -> Double {\n        min(\n            max(value, minimumReadableTranslationFontSizeRange.lowerBound),\n            minimumReadableTranslationFontSizeRange.upperBound\n        )\n    }\n\n"""
)
replace_once(
    path,
    """    var borderlessTranslationFontSize: Double\n\n    var measuredTextTranslationFontSize: Double {\n""",
    """    var borderlessTranslationFontSize: Double\n    /// Minimum point size at which translation is rendered in-place. When a\n    /// region cannot fit at this size, layout returns `needsExpansion` instead\n    /// of silently shrinking to microscopic text.\n    var minimumReadableTranslationFontSize: Double\n\n    var measuredTextTranslationFontSize: Double {\n"""
)
replace_once(
    path,
    """ocrMinimumTextHeight: Double = 0.002, borderlessTranslationFontSize: Double = ComicBook.defaultBorderlessTranslationFontSize, aiTranslationModeRaw:""",
    """ocrMinimumTextHeight: Double = 0.002, borderlessTranslationFontSize: Double = ComicBook.defaultBorderlessTranslationFontSize, minimumReadableTranslationFontSize: Double = ComicBook.defaultMinimumReadableTranslationFontSize, aiTranslationModeRaw:"""
)
replace_once(
    path,
    """        self.borderlessTranslationFontSize = ComicBook.clampedBorderlessTranslationFontSize(borderlessTranslationFontSize)\n        self.aiTranslationModeRaw = aiTranslationModeRaw\n""",
    """        self.borderlessTranslationFontSize = ComicBook.clampedBorderlessTranslationFontSize(borderlessTranslationFontSize)\n        self.minimumReadableTranslationFontSize = ComicBook.clampedMinimumReadableTranslationFontSize(minimumReadableTranslationFontSize)\n        self.aiTranslationModeRaw = aiTranslationModeRaw\n"""
)
replace_once(
    path,
    """        borderlessTranslationFontSize = ComicBook.clampedBorderlessTranslationFontSize(\n            try container.decodeIfPresent(Double.self, forKey: .borderlessTranslationFontSize)\n                ?? ComicBook.defaultBorderlessTranslationFontSize\n        )\n        aiTranslationModeRaw = try container.decodeIfPresent(String.self, forKey: .aiTranslationModeRaw) ?? AITranslationMode.ocr.rawValue\n""",
    """        borderlessTranslationFontSize = ComicBook.clampedBorderlessTranslationFontSize(\n            try container.decodeIfPresent(Double.self, forKey: .borderlessTranslationFontSize)\n                ?? ComicBook.defaultBorderlessTranslationFontSize\n        )\n        minimumReadableTranslationFontSize = ComicBook.clampedMinimumReadableTranslationFontSize(\n            try container.decodeIfPresent(Double.self, forKey: .minimumReadableTranslationFontSize)\n                ?? ComicBook.defaultMinimumReadableTranslationFontSize\n        )\n        aiTranslationModeRaw = try container.decodeIfPresent(String.self, forKey: .aiTranslationModeRaw) ?? AITranslationMode.ocr.rawValue\n"""
)


# ---------------------------------------------------------------------------
# OCRBubbleLayoutEngine: shared CoreText fit contract + readable floor/status.
# ---------------------------------------------------------------------------
path = "mreader/OCRBubbleLayoutEngine.swift"
replace_once(
    path,
    """    struct TranslationLayout: Sendable {\n        let rect: CGRect\n        /// `contentRect` 是最终文字的实际可用排版范围；`rect` 应由它按\n        /// `contentPadding` 向四边外扩得到。detected bubble 在这里表示气泡\n        /// 内的排版范围，measured text 则直接表示文字测量结果。\n        let contentRect: CGRect\n        let fontSize: CGFloat\n        /// `rect` 是可见卡片范围；渲染层必须使用同一个 padding，避免测量层与\n        /// SwiftUI 实际绘制出的背景尺寸产生漂移。\n        let contentPadding: CGFloat\n\n        init(\n            rect: CGRect,\n            contentRect: CGRect,\n            fontSize: CGFloat,\n            contentPadding: CGFloat\n        ) {\n            self.rect = rect\n            self.contentRect = contentRect\n            self.fontSize = fontSize\n            self.contentPadding = contentPadding\n        }\n\n        init(rect: CGRect, fontSize: CGFloat, contentPadding: CGFloat) {\n            self.init(\n                rect: rect,\n                contentRect: rect.insetBy(dx: contentPadding, dy: contentPadding),\n                fontSize: fontSize,\n                contentPadding: contentPadding\n            )\n        }\n    }\n""",
    """    enum TranslationLayoutStatus: String, Sendable, Equatable {\n        case fitted\n        case needsExpansion\n    }\n\n    struct TranslationLayout: Sendable {\n        let rect: CGRect\n        /// `contentRect` is the exact rectangle passed to TranslationTypesetter\n        /// for both measurement and drawing.\n        let contentRect: CGRect\n        let fontSize: CGFloat\n        let contentPadding: CGFloat\n        let status: TranslationLayoutStatus\n\n        init(\n            rect: CGRect,\n            contentRect: CGRect,\n            fontSize: CGFloat,\n            contentPadding: CGFloat,\n            status: TranslationLayoutStatus = .fitted\n        ) {\n            self.rect = rect\n            self.contentRect = contentRect\n            self.fontSize = fontSize\n            self.contentPadding = contentPadding\n            self.status = status\n        }\n\n        init(\n            rect: CGRect,\n            fontSize: CGFloat,\n            contentPadding: CGFloat,\n            status: TranslationLayoutStatus = .fitted\n        ) {\n            self.init(\n                rect: rect,\n                contentRect: rect.insetBy(dx: contentPadding, dy: contentPadding),\n                fontSize: fontSize,\n                contentPadding: contentPadding,\n                status: status\n            )\n        }\n    }\n"""
)
replace_regex(
    path,
    r"    /// Measures the actual glyph area after line breaking\..*?    static func effectiveTranslationOrientation\(",
    """    /// Horizontal measurement uses the same CoreText attributed string and\n    /// line-breaking contract as the renderer.\n    @MainActor\n    static func measuredHorizontalTextSize(\n        _ text: String,\n        fontSize: CGFloat,\n        maximumWidth: CGFloat,\n        lineSpacing: CGFloat\n    ) -> CGSize {\n        TranslationTypesetter.horizontalMeasuredSize(\n            text: text,\n            fontSize: fontSize,\n            maximumWidth: maximumWidth,\n            lineSpacing: lineSpacing\n        )\n    }\n\n    static func effectiveTranslationOrientation("""
)

new_horizontal = r'''    @MainActor
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

'''
replace_regex(
    path,
    r"    @MainActor\n    /// - Parameter geometryStrategy:.*?\n    static func anchoredTranslationLayout\(.*?\n    }\n\n    /// translationLines",
    new_horizontal + "    /// translationLines"
)

replace_once(
    path,
    """        textOrientation: TextOrientation = .horizontal,\n        geometryStrategy: TranslationLayoutStrategy\n    ) -> TranslationLayoutChoice {\n""",
    """        textOrientation: TextOrientation = .horizontal,\n        geometryStrategy: TranslationLayoutStrategy,\n        minimumReadableFontSize: CGFloat = CGFloat(ComicBook.defaultMinimumReadableTranslationFontSize)\n    ) -> TranslationLayoutChoice {\n"""
)
# All three calls inside preferredTranslationLayout end with geometryStrategy.
text = read(path)
start = text.index("    static func preferredTranslationLayout(")
end = text.index("    /// Vision bubbleBox", start)
segment = text[start:end]
segment_new = segment.replace(
    """                    geometryStrategy: geometryStrategy\n                ),""",
    """                    geometryStrategy: geometryStrategy,\n                    minimumReadableFontSize: minimumReadableFontSize\n                ),"""
)
segment_new = segment_new.replace(
    """                    geometryStrategy: geometryStrategy\n                ),""",
    """                    geometryStrategy: geometryStrategy,\n                    minimumReadableFontSize: minimumReadableFontSize\n                ),"""
)
if segment_new == segment or segment_new.count("minimumReadableFontSize: minimumReadableFontSize") < 2:
    raise SystemExit("preferredTranslationLayout: failed to wire readable floor")
write(path, text[:start] + segment_new + text[end:])

new_vertical = r'''    /// Vertical layout proposes compact geometry, but CoreText is the final
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
        let glyphCount = max(text.filter { !$0.isWhitespace && $0 != "\n" }.count, 1)

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

'''
replace_regex(
    path,
    r"    /// Measures a vertical translation as columns of glyph advances\..*?    static func nonOverlappingRect\(",
    new_vertical + "    static func nonOverlappingRect("
)


# ---------------------------------------------------------------------------
# ReaderView: pass floor, keep movement inside safe region, split layer tree,
# and expose an expansion panel instead of microscopic/clipped glyphs.
# ---------------------------------------------------------------------------
path = "mreader/ReaderView.swift"
replace_once(
    path,
    """            let items = translationLayoutItems(in: size)\n            ForEach(items) { item in\n                TranslationTextRenderer(\n                    segments: item.displayText.map { [$0] } ?? item.blocks.compactMap {\n                        let value = displayTranslation(for: $0)\n                        return value.isEmpty ? nil : value\n                    },\n                    fontSize: item.fontSize,\n                    layoutSize: item.rect.size,\n                    contentPadding: item.contentPadding,\n                    style: TranslationColorStyle(rawValue: translationColorStyleRaw) ?? .contrast,\n                    textOrientation: item.textOrientation,\n                    surfaceStyle: item.surfaceStyle\n                )\n                .position(x: item.rect.midX, y: item.rect.midY)\n            }\n""",
    """            let items = translationLayoutItems(in: size)\n            ZStack {\n                // F07: all surfaces are one real layer below every glyph layer.\n                ForEach(items) { item in\n                    TranslationSurfaceRenderer(\n                        layoutSize: item.rect.size,\n                        surfaceStyle: item.surfaceStyle\n                    )\n                    .position(x: item.rect.midX, y: item.rect.midY)\n                    .zIndex(TranslationSurfaceLayering.surfaceZIndex)\n                    .allowsHitTesting(false)\n                }\n                ForEach(items) { item in\n                    TranslationTextRenderer(\n                        segments: item.displayText.map { [$0] } ?? item.blocks.compactMap {\n                            let value = displayTranslation(for: $0)\n                            return value.isEmpty ? nil : value\n                        },\n                        fontSize: item.fontSize,\n                        layoutSize: item.rect.size,\n                        contentPadding: item.contentPadding,\n                        style: TranslationColorStyle(rawValue: translationColorStyleRaw) ?? .contrast,\n                        textOrientation: item.textOrientation,\n                        layoutStatus: item.layoutStatus\n                    )\n                    .position(x: item.rect.midX, y: item.rect.midY)\n                    .zIndex(TranslationSurfaceLayering.textZIndex)\n                }\n            }\n"""
)
replace_once(
    path,
    """                    VStack(alignment: .leading, spacing: 8) {\n                        HStack {\n                            Text(\"ocr.measuredTextFontSize\".localized)\n""",
    """                    VStack(alignment: .leading, spacing: 8) {\n                        HStack {\n                            Text(\"ocr.measuredTextFontSize\".localized)\n"""
)
# Insert readability slider immediately after measured-text description block.
replace_once(
    path,
    """                        Text(\"ocr.measuredTextFontSizeDescription\".localized)\n                            .font(.caption)\n                            .foregroundStyle(.secondary)\n                    }\n                }\n""",
    """                        Text(\"ocr.measuredTextFontSizeDescription\".localized)\n                            .font(.caption)\n                            .foregroundStyle(.secondary)\n\n                        Divider()\n\n                        HStack {\n                            Text(\"ocr.minimumReadableTranslationFontSize\".localized)\n                            Slider(value: Binding(\n                                get: { comic.minimumReadableTranslationFontSize },\n                                set: { newValue in\n                                    updateComic {\n                                        $0.minimumReadableTranslationFontSize = ComicBook.clampedMinimumReadableTranslationFontSize(newValue)\n                                    }\n                                }\n                            ), in: ComicBook.minimumReadableTranslationFontSizeRange, step: 1)\n                        }\n                        Text(\"ocr.minimumReadableTranslationFontSizeValue\".localizedFormat(\n                            Int(comic.minimumReadableTranslationFontSize.rounded())\n                        ))\n                        .font(.caption.monospacedDigit())\n                        Text(\"ocr.minimumReadableTranslationFontSizeDescription\".localized)\n                            .font(.caption)\n                            .foregroundStyle(.secondary)\n                    }\n                }\n"""
)
replace_once(
    path,
    """            textOrientation: translationOrientation,\n            // detected bubble 沿用真实气泡范围；measuredText 只按译文测量结果排版。\n            geometryStrategy: hasReliableBubble ? .detectedBubble : .measuredText\n        )\n""",
    """            textOrientation: translationOrientation,\n            // detected bubble 沿用真实气泡范围；measuredText 只按译文测量结果排版。\n            geometryStrategy: hasReliableBubble ? .detectedBubble : .measuredText,\n            minimumReadableFontSize: CGFloat(comic.minimumReadableTranslationFontSize)\n        )\n"""
)
replace_once(
    path,
    """        return TranslationLayoutItem(\n            blocks: [block],\n            rect: geometry.choice.layout.rect,\n            fontSize: geometry.choice.layout.fontSize,\n            contentPadding: geometry.choice.layout.contentPadding,\n            displayText: translation.isEmpty ? nil : geometry.choice.text,\n            textOrientation: geometry.translationOrientation,\n            layoutRole: block.layoutRole,\n            surfaceStyle: geometry.surfaceStyle\n        )\n""",
    """        return TranslationLayoutItem(\n            blocks: [block],\n            rect: geometry.choice.layout.rect,\n            allowedBounds: geometry.allowedBounds,\n            fontSize: geometry.choice.layout.fontSize,\n            contentPadding: geometry.choice.layout.contentPadding,\n            displayText: translation.isEmpty ? nil : geometry.choice.text,\n            textOrientation: geometry.translationOrientation,\n            layoutRole: block.layoutRole,\n            surfaceStyle: geometry.surfaceStyle,\n            layoutStatus: geometry.choice.layout.status\n        )\n"""
)
new_items = r'''    private func translationLayoutItems(in size: CGSize) -> [TranslationLayoutItem] {
        let initialItems = visibleTranslationBlocks.map { translationLayoutItem(for: $0, in: size) }
        var occupiedRects: [CGRect] = []
        var items: [TranslationLayoutItem] = []
        let transform = ocrDisplayTransform(in: size)

        for item in initialItems {
            let original = item.rect
            let sourceRect = item.blocks.reduce(CGRect.null) { $0.union($1.boundingBox) }
            let mappedSourceRect = OCRCoordinateMapper.displayRect(
                forNormalizedPageRect: sourceRect,
                using: transform
            )
            let boundedMovement = item.allowedBounds.intersection(transform.imageRect)
            let movementBounds = boundedMovement.isNull || boundedMovement.width <= 0 || boundedMovement.height <= 0
                ? transform.imageRect
                : boundedMovement
            let rect = OCRBubbleLayoutEngine.nonOverlappingRect(
                original,
                anchor: CGPoint(x: mappedSourceRect.midX, y: mappedSourceRect.midY),
                occupiedRects: occupiedRects,
                // Reliable bubbles are now a hard movement boundary. Measured
                // text keeps its local fallback region as the anchor boundary.
                bounds: movementBounds,
                margin: 0
            )
            let collisionRemains = occupiedRects.contains { $0.intersects(rect) }
            let escapedBubble = item.surfaceStyle == .detectedBubble
                && !movementBounds.insetBy(dx: -0.5, dy: -0.5).contains(rect)
            let layoutStatus: OCRBubbleLayoutEngine.TranslationLayoutStatus =
                item.layoutStatus == .needsExpansion || collisionRemains || escapedBubble
                    ? .needsExpansion
                    : .fitted

            occupiedRects.append(rect.insetBy(dx: -4, dy: -4))
            items.append(TranslationLayoutItem(
                blocks: item.blocks,
                rect: rect,
                allowedBounds: item.allowedBounds,
                fontSize: item.fontSize,
                contentPadding: item.contentPadding,
                displayText: item.displayText,
                textOrientation: item.textOrientation,
                layoutRole: item.layoutRole,
                surfaceStyle: item.surfaceStyle,
                layoutStatus: layoutStatus
            ))
        }
        return items
    }

'''
replace_regex(
    path,
    r"    private func translationLayoutItems\(in size: CGSize\) -> \[TranslationLayoutItem\] \{.*?\n    }\n\n    private func ocrBubbleRect",
    new_items + "    private func ocrBubbleRect"
)
replace_once(
    path,
    """private struct TranslationLayoutItem: Identifiable {\n    let blocks: [TextBlock]\n    let rect: CGRect\n    let fontSize: CGFloat\n""",
    """private struct TranslationLayoutItem: Identifiable {\n    let blocks: [TextBlock]\n    let rect: CGRect\n    /// Region inside which collision avoidance is allowed to move this item.\n    let allowedBounds: CGRect\n    let fontSize: CGFloat\n"""
)
replace_once(
    path,
    """    let surfaceStyle: TranslationSurfaceStyle\n\n    var id: UUID { blocks.first?.id ?? UUID() }\n""",
    """    let surfaceStyle: TranslationSurfaceStyle\n    let layoutStatus: OCRBubbleLayoutEngine.TranslationLayoutStatus\n\n    var id: UUID { blocks.first?.id ?? UUID() }\n"""
)
# OCR magnification layout item is not translation output, so it is always fitted.
replace_once(
    path,
    """                blocks: [block],\n                rect: rect,\n                fontSize: uniformOCRFontSize,\n""",
    """                blocks: [block],\n                rect: rect,\n                allowedBounds: transform.imageRect,\n                fontSize: uniformOCRFontSize,\n"""
)
replace_once(
    path,
    """                // OCR 放大本身就是要盖住原文字，属于有意绘制的白底卡片。\n                surfaceStyle: .detectedBubble\n            ))\n""",
    """                // OCR 放大本身就是要盖住原文字，属于有意绘制的白底卡片。\n                surfaceStyle: .detectedBubble,\n                layoutStatus: .fitted\n            ))\n"""
)

new_renderer = r'''private struct TranslationSurfaceRenderer: View {
    let layoutSize: CGSize
    let surfaceStyle: TranslationSurfaceStyle

    var body: some View {
        RoundedRectangle(cornerRadius: surfaceStyle.cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: surfaceStyle.cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(surfaceStyle.backgroundOpacity))
            }
            .overlay {
                RoundedRectangle(cornerRadius: surfaceStyle.cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(surfaceStyle.borderOpacity), lineWidth: 0.75)
                    .shadow(color: .black.opacity(0.34), radius: 0.8, y: 0.6)
            }
            .frame(width: layoutSize.width, height: layoutSize.height)
    }
}

private struct TranslationTextRenderer: View {
    let segments: [String]
    let fontSize: CGFloat
    let layoutSize: CGSize
    let contentPadding: CGFloat
    let style: TranslationColorStyle
    let textOrientation: TextOrientation
    let layoutStatus: OCRBubbleLayoutEngine.TranslationLayoutStatus
    @State private var isExpansionPresented = false

    private var fullText: String {
        segments.joined(separator: "\n\n")
    }

    var body: some View {
        Group {
            if layoutStatus == .needsExpansion {
                Button {
                    isExpansionPresented = true
                } label: {
                    Image(systemName: "text.magnifyingglass")
                        .font(.system(size: max(min(fontSize, 18), 12), weight: .semibold))
                        .foregroundStyle(style.coreTextColor.swiftUIColor)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("ocr.translationNeedsExpansion".localized)
            } else {
                CoreTextTranslationView(
                    text: fullText,
                    fontSize: fontSize,
                    color: style.coreTextColor,
                    textOrientation: textOrientation,
                    lineSpacing: 2
                )
            }
        }
        .padding(contentPadding)
        .frame(width: layoutSize.width, height: layoutSize.height)
        .sheet(isPresented: $isExpansionPresented) {
            NavigationStack {
                ScrollView {
                    Text(fullText)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                        .textSelection(.enabled)
                }
                .navigationTitle("ocr.aiTranslation".localized)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("nav.done".localized) {
                            isExpansionPresented = false
                        }
                    }
                }
            }
        }
    }

    static let palette: [Color] = [
        Color(red: 0.10, green: 0.38, blue: 0.82),
        Color(red: 0.32, green: 0.22, blue: 0.78),
        Color(red: 0.55, green: 0.18, blue: 0.72),
        Color(red: 0.75, green: 0.20, blue: 0.55),
        Color(red: 0.12, green: 0.58, blue: 0.65),
        Color(red: 0.18, green: 0.50, blue: 0.78),
        Color(red: 0.72, green: 0.38, blue: 0.18).opacity(0.7)
    ]
}

private extension UIColor {
    var swiftUIColor: Color { Color(self) }
}

/// Measurement and drawing both use TranslationTypesetter. The renderer no
/// longer has a second line-breaking algorithm that can disagree with layout.
private struct CoreTextTranslationView: UIViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let color: UIColor
    let textOrientation: TextOrientation
    let lineSpacing: CGFloat

    func makeUIView(context: Context) -> TranslationTextUIView {
        TranslationTextUIView()
    }

    func updateUIView(_ uiView: TranslationTextUIView, context: Context) {
        uiView.text = text
        uiView.fontSize = fontSize
        uiView.color = color
        uiView.textOrientation = textOrientation
        uiView.lineSpacing = lineSpacing
        uiView.setNeedsDisplay()
    }
}

private final class TranslationTextUIView: UIView {
    var text = ""
    var fontSize: CGFloat = 16
    var color = UIColor.label
    var textOrientation: TextOrientation = .horizontal
    var lineSpacing: CGFloat = 2

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    override func draw(_ rect: CGRect) {
        guard !text.isEmpty, bounds.width > 0, bounds.height > 0,
              let context = UIGraphicsGetCurrentContext() else { return }
        TranslationTypesetter.draw(
            text: text,
            in: bounds,
            context: context,
            fontSize: fontSize,
            orientation: textOrientation,
            lineSpacing: lineSpacing,
            color: color
        )
    }
}

'''
replace_regex(
    path,
    r"private struct TranslationTextRenderer: View \{.*?private struct AppleIntelligenceGlowBorder: View \{",
    new_renderer + "private struct AppleIntelligenceGlowBorder: View {"
)


# ---------------------------------------------------------------------------
# Localized copy for the explicit readability/expansion behavior.
# ---------------------------------------------------------------------------
localizations = {
    "mreader/Base.lproj/Localizable.strings": [
        '"ocr.minimumReadableTranslationFontSize" = "最小可读译文字号";',
        '"ocr.minimumReadableTranslationFontSizeValue" = "可读下限：%d pt";',
        '"ocr.minimumReadableTranslationFontSizeDescription" = "低于此字号时不再继续缩小，而改为可展开阅读。";',
        '"ocr.translationNeedsExpansion" = "译文需要展开阅读";',
    ],
    "mreader/zh-Hans.lproj/Localizable.strings": [
        '"ocr.minimumReadableTranslationFontSize" = "最小可读译文字号";',
        '"ocr.minimumReadableTranslationFontSizeValue" = "可读下限：%d pt";',
        '"ocr.minimumReadableTranslationFontSizeDescription" = "低于此字号时不再继续缩小，而改为可展开阅读。";',
        '"ocr.translationNeedsExpansion" = "译文需要展开阅读";',
    ],
    "mreader/en.lproj/Localizable.strings": [
        '"ocr.minimumReadableTranslationFontSize" = "Minimum readable translation size";',
        '"ocr.minimumReadableTranslationFontSizeValue" = "Readable floor: %d pt";',
        '"ocr.minimumReadableTranslationFontSizeDescription" = "Below this size, text is not shrunk further; use the expandable translation instead.";',
        '"ocr.translationNeedsExpansion" = "Translation needs expanded reading";',
    ],
    "mreader/ja.lproj/Localizable.strings": [
        '"ocr.minimumReadableTranslationFontSize" = "翻訳の最小可読サイズ";',
        '"ocr.minimumReadableTranslationFontSizeValue" = "可読下限：%d pt";',
        '"ocr.minimumReadableTranslationFontSizeDescription" = "このサイズより小さくせず、収まらない場合は展開表示で全文を読みます。";',
        '"ocr.translationNeedsExpansion" = "翻訳を展開して読む必要があります";',
    ],
    "mreader/ko.lproj/Localizable.strings": [
        '"ocr.minimumReadableTranslationFontSize" = "번역 최소 가독 글자 크기";',
        '"ocr.minimumReadableTranslationFontSizeValue" = "가독 하한: %d pt";',
        '"ocr.minimumReadableTranslationFontSizeDescription" = "이 크기보다 더 줄이지 않고, 공간이 부족하면 펼쳐서 전체 번역을 읽습니다.";',
        '"ocr.translationNeedsExpansion" = "번역을 펼쳐서 읽어야 합니다";',
    ],
}
for loc_path, lines in localizations.items():
    text = read(loc_path)
    missing = [line for line in lines if line.split('" = ')[0] not in text]
    if missing:
        text = text.rstrip() + "\n\n" + "\n".join(missing) + "\n"
        write(loc_path, text)

print("translation readability patch applied")
