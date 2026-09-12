from pathlib import Path

p = Path('mreader/OfflineTranslationModels.swift')
s = p.read_text()

def once(old: str, new: str, label: str):
    global s
    if old not in s:
        raise SystemExit(f'missing anchor: {label}')
    s = s.replace(old, new, 1)

once(
    '''    let textBox: OfflineTranslationRect\n    let bubbleBox: OfflineTranslationRect?\n    let textPolygon:''',
    '''    let textBox: OfflineTranslationRect\n    let bubbleBox: OfflineTranslationRect?\n    /// Independent safe layout region. Optional for backward compatibility with pre-F10 files.\n    let layoutSafeRegion: OfflineTranslationRect?\n    let textPolygon:''',
    'stored field'
)
once(
    '''        case id, sourceText, translation, translationLines, lines, textBox, bubbleBox\n        case textPolygon,''',
    '''        case id, sourceText, translation, translationLines, lines, textBox, bubbleBox, layoutSafeRegion\n        case textPolygon,''',
    'coding key'
)
once(
    '''        textBox: OfflineTranslationRect,\n        bubbleBox: OfflineTranslationRect? = nil,\n        textPolygon:''',
    '''        textBox: OfflineTranslationRect,\n        bubbleBox: OfflineTranslationRect? = nil,\n        layoutSafeRegion: OfflineTranslationRect? = nil,\n        textPolygon:''',
    'init parameter'
)
once(
    '''        self.textBox = textBox\n        self.bubbleBox = bubbleBox\n        self.textPolygon''',
    '''        self.textBox = textBox\n        self.bubbleBox = bubbleBox\n        self.layoutSafeRegion = layoutSafeRegion\n        self.textPolygon''',
    'init assignment'
)
once(
    '''        textBox = try container.decode(OfflineTranslationRect.self, forKey: .textBox)\n        bubbleBox = try container.decodeIfPresent(OfflineTranslationRect.self, forKey: .bubbleBox)\n        textPolygon''',
    '''        textBox = try container.decode(OfflineTranslationRect.self, forKey: .textBox)\n        bubbleBox = try container.decodeIfPresent(OfflineTranslationRect.self, forKey: .bubbleBox)\n        layoutSafeRegion = try container.decodeIfPresent(OfflineTranslationRect.self, forKey: .layoutSafeRegion)\n        textPolygon''',
    'decode'
)
once(
    '''        try container.encode(textBox, forKey: .textBox)\n        try container.encodeIfPresent(bubbleBox, forKey: .bubbleBox)\n        try container.encode(textPolygon''',
    '''        try container.encode(textBox, forKey: .textBox)\n        try container.encodeIfPresent(bubbleBox, forKey: .bubbleBox)\n        try container.encodeIfPresent(layoutSafeRegion, forKey: .layoutSafeRegion)\n        try container.encode(textPolygon''',
    'encode'
)
once(
    '''            textBox: OfflineTranslationRect(block.boundingBox),\n            bubbleBox: block.bubbleBox.map(OfflineTranslationRect.init),\n            textPolygon:''',
    '''            textBox: OfflineTranslationRect(block.boundingBox),\n            bubbleBox: block.bubbleBox.map(OfflineTranslationRect.init),\n            layoutSafeRegion: block.layoutSafeRegion.map(OfflineTranslationRect.init),\n            textPolygon:''',
    'TextBlock to DTO'
)
once(
    '''            textColorHex: textColorHex,\n            bubbleBox: bubbleBox?.cgRect,\n            polygon:''',
    '''            textColorHex: textColorHex,\n            bubbleBox: bubbleBox?.cgRect,\n            layoutSafeRegion: layoutSafeRegion?.cgRect,\n            polygon:''',
    'DTO to TextBlock'
)

p.write_text(s)

# Add a durability regression without duplicating the visual-policy tests.
p = Path('mreaderTests/TranslationComicIntegrationRegressionTests.swift')
s = p.read_text()
anchor = '''    @MainActor\n    func testVisionSliceBoundariesAreStableAcrossViewportAspect() {'''
if anchor not in s:
    raise SystemExit('missing test insertion anchor')
test = '''    func testOfflineBlockRoundTripPreservesIndependentLayoutSafeRegion() throws {\n        let source = TextBlock(\n            text: "原文",\n            boundingBox: CGRect(x: 0.20, y: 0.30, width: 0.12, height: 0.08),\n            translation: "译文",\n            confidence: 0.92,\n            ocrSource: "vision-model:dialogue",\n            bubbleBox: CGRect(x: 0.18, y: 0.28, width: 0.18, height: 0.14),\n            layoutSafeRegion: CGRect(x: 0.19, y: 0.29, width: 0.16, height: 0.12)\n        )\n        let stored = OfflineTranslatedBlock(block: source)\n        let data = try JSONEncoder().encode(stored)\n        let decoded = try JSONDecoder().decode(OfflineTranslatedBlock.self, from: data)\n        let restored = decoded.textBlock()\n\n        XCTAssertEqual(restored.bubbleBox, source.bubbleBox)\n        XCTAssertEqual(restored.layoutSafeRegion, source.layoutSafeRegion)\n    }\n\n'''
s = s.replace(anchor, test + anchor, 1)
p.write_text(s)
