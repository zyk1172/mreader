from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"missing anchor: {label}")
    return text.replace(old, new, 1)

# 1) Product display policy: in-place is opt-in, sound effects stay annotation-first.
p = Path('mreader/TranslationComicIntegration.swift')
s = p.read_text()
s = replace_once(
    s,
    '''    static func mode(
        contentRole: TranslationContentRole,
        hasReliableDetectedBubble: Bool
    ) -> TranslationDisplayMode {
        switch contentRole {
        case .dialogue where hasReliableDetectedBubble:
            return .inPlace
        case .soundEffect:
            return .annotation
        case .dialogue, .narration, .other:
            return .assistOverlay
        }
    }''',
    '''    static func mode(
        contentRole: TranslationContentRole,
        hasReliableDetectedBubble: Bool,
        prefersInPlace: Bool
    ) -> TranslationDisplayMode {
        switch contentRole {
        case .dialogue where hasReliableDetectedBubble && prefersInPlace:
            return .inPlace
        case .soundEffect:
            return .annotation
        case .dialogue, .narration, .other:
            return .assistOverlay
        }
    }
}

nonisolated enum TranslationRegionPolicy {
    /// A model-provided safe region is placement evidence, never bubble evidence.
    /// It must stay on-page and overlap the source text; reliable bubble content
    /// is additionally intersected with the physical bubble so in-place text
    /// cannot escape the actual balloon.
    static func resolvedLayoutSafeRegion(
        sourceTextRegion: CGRect,
        proposedSafeRegion: CGRect?,
        detectedBubble: CGRect?,
        pageBounds: CGRect
    ) -> CGRect? {
        guard !pageBounds.isNull, pageBounds.width > 0, pageBounds.height > 0 else { return nil }
        guard let proposedSafeRegion else { return nil }
        let safe = proposedSafeRegion.standardized.intersection(pageBounds.standardized)
        guard !safe.isNull, safe.width > 0, safe.height > 0,
              safe.intersects(sourceTextRegion.standardized) else { return nil }
        guard let detectedBubble else { return safe }
        let bubble = detectedBubble.standardized.intersection(pageBounds.standardized)
        guard !bubble.isNull, bubble.width > 0, bubble.height > 0 else { return safe }
        let constrained = safe.intersection(bubble)
        guard !constrained.isNull, constrained.width > 0, constrained.height > 0,
              constrained.intersects(sourceTextRegion.standardized) else { return nil }
        return constrained
    }''',
    'display and region policy',
)
p.write_text(s)

# 2) Persist an opt-in original-position display preference per comic.
p = Path('mreader/ComicBook.swift')
s = p.read_text()
s = replace_once(
    s,
    '''    var minimumReadableTranslationFontSize: Double

    var measuredTextTranslationFontSize: Double {''',
    '''    var minimumReadableTranslationFontSize: Double
    /// Opt-in, non-destructive original-position rendering for reliable dialogue bubbles.
    /// The image itself is never modified; disabling this immediately restores the artwork.
    var prefersInPlaceTranslation: Bool

    var measuredTextTranslationFontSize: Double {''',
    'ComicBook property',
)
s = replace_once(
    s,
    '''borderlessTranslationFontSize: Double = ComicBook.defaultBorderlessTranslationFontSize, minimumReadableTranslationFontSize: Double = ComicBook.defaultMinimumReadableTranslationFontSize, aiTranslationModeRaw:''',
    '''borderlessTranslationFontSize: Double = ComicBook.defaultBorderlessTranslationFontSize, minimumReadableTranslationFontSize: Double = ComicBook.defaultMinimumReadableTranslationFontSize, prefersInPlaceTranslation: Bool = false, aiTranslationModeRaw:''',
    'ComicBook init parameter',
)
s = replace_once(
    s,
    '''        self.minimumReadableTranslationFontSize = ComicBook.clampedMinimumReadableTranslationFontSize(minimumReadableTranslationFontSize)
        self.aiTranslationModeRaw = aiTranslationModeRaw''',
    '''        self.minimumReadableTranslationFontSize = ComicBook.clampedMinimumReadableTranslationFontSize(minimumReadableTranslationFontSize)
        self.prefersInPlaceTranslation = prefersInPlaceTranslation
        self.aiTranslationModeRaw = aiTranslationModeRaw''',
    'ComicBook init assignment',
)
s = replace_once(
    s,
    '''        minimumReadableTranslationFontSize = ComicBook.clampedMinimumReadableTranslationFontSize(
            try container.decodeIfPresent(Double.self, forKey: .minimumReadableTranslationFontSize)
                ?? ComicBook.defaultMinimumReadableTranslationFontSize
        )
        aiTranslationModeRaw =''',
    '''        minimumReadableTranslationFontSize = ComicBook.clampedMinimumReadableTranslationFontSize(
            try container.decodeIfPresent(Double.self, forKey: .minimumReadableTranslationFontSize)
                ?? ComicBook.defaultMinimumReadableTranslationFontSize
        )
        prefersInPlaceTranslation = try container.decodeIfPresent(Bool.self, forKey: .prefersInPlaceTranslation) ?? false
        aiTranslationModeRaw =''',
    'ComicBook decode',
)
p.write_text(s)

# 3) Reader geometry consumes layoutSafeRegion separately from physical bubble.
p = Path('mreader/ReaderView.swift')
s = p.read_text()
s = replace_once(
    s,
    '''            layoutRole: block.layoutRole,
            surfaceStyle: geometry.surfaceStyle,
            layoutStatus: geometry.choice.layout.status''',
    '''            layoutRole: block.layoutRole,
            contentRole: block.translationContentRole,
            displayMode: geometry.displayMode,
            surfaceStyle: geometry.surfaceStyle,
            layoutStatus: geometry.choice.layout.status''',
    'layout item construction',
)
s = replace_once(
    s,
    '''        translationOrientation: TextOrientation,
        surfaceStyle: TranslationSurfaceStyle,
        choice: OCRBubbleLayoutEngine.TranslationLayoutChoice''',
    '''        translationOrientation: TextOrientation,
        displayMode: TranslationDisplayMode,
        surfaceStyle: TranslationSurfaceStyle,
        choice: OCRBubbleLayoutEngine.TranslationLayoutChoice''',
    'geometry tuple result',
)
s = replace_once(
    s,
    '''        let hasReliableBubble = usableBubbleBounds != nil
        let surfaceStyle = TranslationSurfacePolicy.surfaceStyle(
            hasReliableBubble: hasReliableBubble
        )
        let fallbackBounds: CGRect''',
    '''        let hasReliableBubble = usableBubbleBounds != nil
        let displayMode = TranslationDisplayPolicy.mode(
            contentRole: block.translationContentRole,
            hasReliableDetectedBubble: hasReliableBubble,
            prefersInPlace: comic?.prefersInPlaceTranslation ?? false
        )
        let surfaceStyle = TranslationSurfacePolicy.surfaceStyle(
            hasReliableBubble: hasReliableBubble
        )
        let mappedSafeRegion = block.effectiveLayoutSafeRegion.map {
            OCRCoordinateMapper.displayRect(forNormalizedPageRect: $0, using: transform)
        }
        let resolvedSafeRegion = TranslationRegionPolicy.resolvedLayoutSafeRegion(
            sourceTextRegion: textRect,
            proposedSafeRegion: mappedSafeRegion,
            detectedBubble: usableBubbleBounds,
            pageBounds: imageBounds
        )
        let fallbackBounds: CGRect''',
    'display policy and safe region',
)
s = replace_once(
    s,
    '''        let allowedBounds = usableBubbleBounds ?? fallbackBounds
        let layoutBounds = OCRBubbleLayoutEngine.boundedTranslationBounds(''',
    '''        let allowedBounds = resolvedSafeRegion ?? usableBubbleBounds ?? fallbackBounds
        let layoutBounds = OCRBubbleLayoutEngine.boundedTranslationBounds(''',
    'allowed bounds source',
)
s = replace_once(
    s,
    '''            translationOrientation: translationOrientation,
            surfaceStyle: surfaceStyle,
            choice: choice''',
    '''            translationOrientation: translationOrientation,
            displayMode: displayMode,
            surfaceStyle: surfaceStyle,
            choice: choice''',
    'geometry return display mode',
)

# Carry semantic display fields through collision pass and OCR helper construction.
s = replace_once(
    s,
    '''                layoutRole: item.layoutRole,
                surfaceStyle: item.surfaceStyle,
                layoutStatus: layoutStatus''',
    '''                layoutRole: item.layoutRole,
                contentRole: item.contentRole,
                displayMode: item.displayMode,
                surfaceStyle: item.surfaceStyle,
                layoutStatus: layoutStatus''',
    'collision item semantic fields',
)
s = replace_once(
    s,
    '''                layoutRole: block.layoutRole,
                // OCR 放大本身就是要盖住原文字，属于有意绘制的白底卡片。
                surfaceStyle: .detectedBubble,
                layoutStatus: .fitted''',
    '''                layoutRole: block.layoutRole,
                contentRole: block.translationContentRole,
                displayMode: .assistOverlay,
                // OCR 放大本身就是要盖住原文字，属于有意绘制的白底卡片。
                surfaceStyle: .detectedBubble,
                layoutStatus: .fitted''',
    'OCR item semantic fields',
)

# Overlay renderer receives the mode; text renderer can make SFX annotation lighter.
s = replace_once(
    s,
    '''                    TranslationSurfaceRenderer(
                        layoutSize: item.rect.size,
                        surfaceStyle: item.surfaceStyle
                    )''',
    '''                    TranslationSurfaceRenderer(
                        layoutSize: item.rect.size,
                        surfaceStyle: item.surfaceStyle,
                        displayMode: item.displayMode
                    )''',
    'surface renderer call',
)
s = replace_once(
    s,
    '''                        textOrientation: item.textOrientation,
                        layoutStatus: item.layoutStatus
                    )''',
    '''                        textOrientation: item.textOrientation,
                        displayMode: item.displayMode,
                        layoutStatus: item.layoutStatus
                    )''',
    'text renderer call',
)
s = replace_once(
    s,
    '''    let textOrientation: TextOrientation
    let layoutRole: TranslationLayoutRole
    /// 有可靠漫画气泡时为 detectedBubble；否则为 measuredText。两种表面都绘制''',
    '''    let textOrientation: TextOrientation
    let layoutRole: TranslationLayoutRole
    let contentRole: TranslationContentRole
    let displayMode: TranslationDisplayMode
    /// 有可靠漫画气泡时为 detectedBubble；否则为 measuredText。两种表面都绘制''',
    'TranslationLayoutItem semantic fields',
)

# Renderer strategies: assist keeps the card, in-place becomes a quiet reversible cover,
# annotation avoids a large card over artwork.
s = replace_once(
    s,
    '''private struct TranslationSurfaceRenderer: View {
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
}''',
    '''private struct TranslationSurfaceRenderer: View {
    let layoutSize: CGSize
    let surfaceStyle: TranslationSurfaceStyle
    let displayMode: TranslationDisplayMode

    @ViewBuilder
    var body: some View {
        switch displayMode {
        case .inPlace:
            RoundedRectangle(cornerRadius: max(surfaceStyle.cornerRadius * 0.55, 3), style: .continuous)
                .fill(Color.white.opacity(0.94))
                .frame(width: layoutSize.width, height: layoutSize.height)
        case .assistOverlay:
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
        case .annotation:
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(.thinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white.opacity(0.30))
                }
                .frame(width: layoutSize.width, height: layoutSize.height)
        }
    }
}''',
    'surface renderer implementation',
)
s = replace_once(
    s,
    '''    let style: TranslationColorStyle
    let textOrientation: TextOrientation
    let layoutStatus: OCRBubbleLayoutEngine.TranslationLayoutStatus''',
    '''    let style: TranslationColorStyle
    let textOrientation: TextOrientation
    let displayMode: TranslationDisplayMode
    let layoutStatus: OCRBubbleLayoutEngine.TranslationLayoutStatus''',
    'text renderer display mode property',
)
s = replace_once(
    s,
    '''                    color: style.coreTextColor,
                    textOrientation: textOrientation,''',
    '''                    color: displayMode == .inPlace ? UIColor.label : style.coreTextColor,
                    textOrientation: textOrientation,''',
    'in-place text color',
)
p.write_text(s)

# 4) Localizations + simple settings toggle near the existing readable-floor control.
for loc in ['Base.lproj', 'zh-Hans.lproj', 'en.lproj', 'ja.lproj', 'ko.lproj']:
    p = Path('mreader') / loc / 'Localizable.strings'
    s = p.read_text()
    if '"ocr.inPlaceTranslation"' not in s:
        if loc == 'zh-Hans.lproj':
            add = '\n"ocr.inPlaceTranslation" = "原位译文";\n"ocr.inPlaceTranslationDescription" = "仅对可靠对白气泡启用可随时关闭的原位覆盖；拟声词仍保留原艺术字并使用注释。";\n'
        elif loc == 'ja.lproj':
            add = '\n"ocr.inPlaceTranslation" = "インプレース翻訳";\n"ocr.inPlaceTranslationDescription" = "信頼できる吹き出しだけを可逆なインプレース表示にし、効果音の原画は保持します。";\n'
        elif loc == 'ko.lproj':
            add = '\n"ocr.inPlaceTranslation" = "원위치 번역";\n"ocr.inPlaceTranslationDescription" = "신뢰할 수 있는 대사 말풍선만 되돌릴 수 있는 원위치 표시를 사용하고 효과음 원화는 유지합니다.";\n'
        else:
            add = '\n"ocr.inPlaceTranslation" = "In-place translation";\n"ocr.inPlaceTranslationDescription" = "Use reversible in-place coverage only for reliable dialogue bubbles; sound effects keep their original artwork and use annotations.";\n'
        p.write_text(s.rstrip() + add)

# Reader settings anchor is intentionally narrow and placed immediately after the readable-floor description.
p = Path('mreader/ReaderView.swift')
s = p.read_text()
anchor = '''                            Text("ocr.minimumReadableTranslationFontSizeDescription".localized)
                                .font(.caption)
                                .foregroundStyle(.secondary)'''
if anchor not in s:
    raise SystemExit('missing anchor: reader readable-floor description')
insert = anchor + '''

                            Toggle("ocr.inPlaceTranslation".localized, isOn: Binding(
                                get: { comic?.prefersInPlaceTranslation ?? false },
                                set: { newValue in
                                    comic?.prefersInPlaceTranslation = newValue
                                    persistReaderComicSettings()
                                }
                            ))
                            Text("ocr.inPlaceTranslationDescription".localized)
                                .font(.caption)
                                .foregroundStyle(.secondary)'''
s = s.replace(anchor, insert, 1)
p.write_text(s)
