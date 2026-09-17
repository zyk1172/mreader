from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    file = Path(path)
    text = file.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"expected exactly one match in {path}, found {count}")
    file.write_text(text.replace(old, new, 1))


reader = "mreader/ReaderView.swift"

replace_once(
    reader,
    '''                    Picker("ocr.colorStyle".localized, selection: $translationColorStyleRaw) {
                        ForEach(TranslationColorStyle.allCases, id: \.rawValue) { style in
                            Text(style.title).tag(style.rawValue)
                        }
                    }
                    .disabled(!comic.isAITranslationEnabled)
''',
    '''                    Picker("ocr.colorStyle".localized, selection: $translationColorStyleRaw) {
                        ForEach(TranslationColorStyle.allCases, id: \.rawValue) { style in
                            Text(style.title).tag(style.rawValue)
                        }
                    }
                    .disabled(!comic.isAITranslationEnabled || comic.prefersInPlaceTranslation)
'''
)

replace_once(
    reader,
    '''                        Toggle("ocr.inPlaceTranslation".localized, isOn: Binding(
                            get: { comic.prefersInPlaceTranslation },
                            set: { newValue in updateComic { $0.prefersInPlaceTranslation = newValue } }
                        ))
                        .disabled(!comic.isAITranslationEnabled)
                        Text("ocr.inPlaceTranslationDescription".localized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
''',
    '''                        Picker("ocr.inPlaceTranslation".localized, selection: Binding(
                            get: { comic.prefersInPlaceTranslation },
                            set: { newValue in updateComic { $0.prefersInPlaceTranslation = newValue } }
                        )) {
                            Text("ocr.presentationStyle.colorful".localized).tag(false)
                            Text("ocr.presentationStyle.neutral".localized).tag(true)
                        }
                        .pickerStyle(.segmented)
                        .disabled(!comic.isAITranslationEnabled)
                        Text("ocr.inPlaceTranslationDescription".localized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
'''
)

replace_once(
    reader,
    '''        let automaticFontSize = hasReliableBubble
            ? preferredTranslationFontSize(
                for: block,
                in: size,
                textRect: textRect,
                sizingMode: .bubble
            )
            : 1
        let requestedFontSize = OCRBubbleLayoutEngine.requestedTranslationFontSize(
            hasReliableBubble: hasReliableBubble,
            automaticFontSize: automaticFontSize,
            measuredTextFontSize: measuredTextTranslationFontSize
        )
''',
    '''        // Geometry and presentation are independent. Both real-bubble and measured-text
        // layouts start from the same reader-selected preferred size, then the layout engine
        // only shrinks when the available region cannot fit the translated text.
        let requestedFontSize = CGFloat(
            ComicBook.clampedMeasuredTextTranslationFontSize(
                comic?.measuredTextTranslationFontSize
                    ?? ComicBook.defaultMeasuredTextTranslationFontSize
            )
        )
'''
)

replace_once(
    "mreader/OCRBubbleLayoutEngine.swift",
    '''    /// 有可靠气泡时沿用 OCR 几何字号；没有可靠气泡时，OCR 框不参与字号决策，
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
''',
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
'''
)

replace_once(
    "mreader/ComicBook.swift",
    '''    /// measuredText 表面使用的译文字号；这是显示参数，不参与 OCR/翻译缓存。
    /// 属性名保留旧版 Codable 字段名，以兼容已有阅读设置。
''',
    '''    /// 所有译文表面共享的首选字号；空间不足时布局引擎只向下缩小。
    /// 属性名保留旧版 Codable 字段名，以兼容已有阅读设置。
'''
)

replace_once(
    "mreader/ComicBook.swift",
    '''    /// Opt-in, non-destructive original-position rendering for reliable dialogue bubbles.
    /// The image itself is never modified; disabling this immediately restores the artwork.
''',
    '''    /// Translation presentation choice persisted with the comic. `true` selects the neutral
    /// white-surface/black-text style; `false` keeps the original colorful presentation.
'''
)
