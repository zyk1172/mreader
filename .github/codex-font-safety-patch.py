from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"expected exactly one match in {path}, found {count}")
    p.write_text(text.replace(old, new, 1))


replace_once(
    "mreader/OCRBubbleLayoutEngine.swift",
    '''    /// Bubble detection decides geometry, never typography. Every translation starts from
    /// the same reader-selected preferred size and may only shrink to fit its available region.
    static func requestedTranslationFontSize(
        hasReliableBubble: Bool,
        automaticFontSize: CGFloat,
        measuredTextFontSize: CGFloat
    ) -> CGFloat {
        _ = hasReliableBubble
        _ = automaticFontSize
        return CGFloat(
            ComicBook.clampedMeasuredTextTranslationFontSize(Double(measuredTextFontSize))
        )
    }
''',
    '''    /// Measured-text size remains the shared reader preference in normal cases. A reliable
    /// bubble also carries an OCR-derived automatic size; if the measured value is invalid or
    /// implausibly tiny relative to that bounded automatic estimate, discard it rather than
    /// allowing pathological OCR geometry to collapse the translation.
    static func requestedTranslationFontSize(
        hasReliableBubble: Bool,
        automaticFontSize: CGFloat,
        measuredTextFontSize: CGFloat
    ) -> CGFloat {
        let safeMeasuredTextSize: CGFloat
        if measuredTextFontSize.isFinite, measuredTextFontSize > 0 {
            safeMeasuredTextSize = CGFloat(
                ComicBook.clampedMeasuredTextTranslationFontSize(Double(measuredTextFontSize))
            )
        } else {
            safeMeasuredTextSize = CGFloat(ComicBook.defaultMeasuredTextTranslationFontSize)
        }

        guard hasReliableBubble,
              automaticFontSize.isFinite,
              automaticFontSize > 0 else {
            return safeMeasuredTextSize
        }

        let boundedAutomatic = min(
            max(automaticFontSize, 1),
            TranslationLayoutMetrics.absoluteFontSizeCap
        )
        let isPathologicalMeasurement =
            !measuredTextFontSize.isFinite ||
            measuredTextFontSize <= 0 ||
            measuredTextFontSize < boundedAutomatic * 0.2

        if isPathologicalMeasurement {
            return boundedAutomatic
        }
        return min(safeMeasuredTextSize, boundedAutomatic)
    }
'''
)

replace_once(
    "mreader/ReaderView.swift",
    '''        // Geometry and presentation are independent. Both real-bubble and measured-text
        // layouts start from the same reader-selected preferred size, then the layout engine
        // only shrinks when the available region cannot fit the translated text.
        let requestedFontSize = CGFloat(
            ComicBook.clampedMeasuredTextTranslationFontSize(
                comic?.measuredTextTranslationFontSize
                    ?? ComicBook.defaultMeasuredTextTranslationFontSize
            )
        )
''',
    '''        // Geometry and presentation are independent. Both paths normally start from the
        // reader-selected preferred size. Reliable bubbles additionally provide the OCR-derived
        // automatic estimate so the sizing policy can reject pathological geometry before layout.
        let configuredFontSize = CGFloat(
            ComicBook.clampedMeasuredTextTranslationFontSize(
                comic?.measuredTextTranslationFontSize
                    ?? ComicBook.defaultMeasuredTextTranslationFontSize
            )
        )
        let automaticFontSize = hasReliableBubble
            ? preferredTranslationFontSize(
                for: block,
                in: size,
                textRect: textRect,
                sizingMode: .bubble
            )
            : configuredFontSize
        let requestedFontSize = OCRBubbleLayoutEngine.requestedTranslationFontSize(
            hasReliableBubble: hasReliableBubble,
            automaticFontSize: automaticFontSize,
            measuredTextFontSize: configuredFontSize
        )
'''
)
