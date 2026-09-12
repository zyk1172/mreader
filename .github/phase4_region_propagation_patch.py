from pathlib import Path

# Preserve the new region semantic when AITranslator rebuilds TextBlock values.
p = Path('mreader/AITranslator.swift')
s = p.read_text()
old = '''                    textColorHex: original.textColorHex,\n                    bubbleBox: bubbleGeometry.bubbleBox,\n                    polygon: original.polygon,'''
new = '''                    textColorHex: original.textColorHex,\n                    bubbleBox: bubbleGeometry.bubbleBox,\n                    layoutSafeRegion: original.layoutSafeRegion ?? bubbleGeometry.bubbleBox,\n                    polygon: original.polygon,'''
if old not in s:
    raise SystemExit('missing visual verification propagation anchor')
s = s.replace(old, new, 1)
old = '''                        textColorHex: block.textColorHex,\n                        bubbleBox: block.bubbleBox,\n                        polygon: block.polygon,'''
new = '''                        textColorHex: block.textColorHex,\n                        bubbleBox: block.bubbleBox,\n                        layoutSafeRegion: block.layoutSafeRegion,\n                        polygon: block.polygon,'''
if old not in s:
    raise SystemExit('missing page recovery propagation anchor')
s = s.replace(old, new, 1)
p.write_text(s)

# Preserve/merge the safe region when OCR observations become line/bubble units.
p = Path('mreader/MangaTextSegmenter.swift')
s = p.read_text()
anchor = '''        if let bubbleRegion {\n            selectedBubble = (bubbleRegion.rect, bubbleRegion.polygon)\n        } else {\n            selectedBubble = selectedVisualBubble(\n                from: ordered,\n                containing: bounds\n            )\n        }\n\n        return TextBlock('''
replacement = '''        if let bubbleRegion {\n            selectedBubble = (bubbleRegion.rect, bubbleRegion.polygon)\n        } else {\n            selectedBubble = selectedVisualBubble(\n                from: ordered,\n                containing: bounds\n            )\n        }\n\n        let safeCandidates = ordered.compactMap(\\.layoutSafeRegion)\n        let proposedSafeRegion: CGRect? = safeCandidates.isEmpty\n            ? nil\n            : safeCandidates.dropFirst().reduce(safeCandidates[0]) { $0.union($1) }\n        let mergedSafeRegion = TranslationRegionPolicy.resolvedLayoutSafeRegion(\n            sourceTextRegion: bounds,\n            proposedSafeRegion: proposedSafeRegion,\n            detectedBubble: selectedBubble?.box,\n            pageBounds: CGRect(x: 0, y: 0, width: 1, height: 1)\n        ) ?? selectedBubble?.box\n\n        return TextBlock('''
if anchor not in s:
    raise SystemExit('missing segmenter selected-bubble anchor')
s = s.replace(anchor, replacement, 1)
old = '''            textColorHex: ordered.compactMap(\\.textColorHex).first,\n            bubbleBox: selectedBubble?.box,\n            polygon: ordered.flatMap(\\.polygon),'''
new = '''            textColorHex: ordered.compactMap(\\.textColorHex).first,\n            bubbleBox: selectedBubble?.box,\n            layoutSafeRegion: mergedSafeRegion,\n            polygon: ordered.flatMap(\\.polygon),'''
if old not in s:
    raise SystemExit('missing segmenter TextBlock anchor')
s = s.replace(old, new, 1)
p.write_text(s)

# Regression: even a single vision observation is rebuilt twice by the segmenter,
# so this catches accidental loss during line and bubble canonicalization.
p = Path('mreaderTests/TranslationComicIntegrationRegressionTests.swift')
s = p.read_text()
anchor = '''    func testOfflineBlockRoundTripPreservesIndependentLayoutSafeRegion() throws {'''
if anchor not in s:
    raise SystemExit('missing regression insertion anchor')
test = '''    func testSegmentationPreservesIndependentLayoutSafeRegion() {\n        let safe = CGRect(x: 0.18, y: 0.20, width: 0.30, height: 0.20)\n        let bubble = CGRect(x: 0.16, y: 0.18, width: 0.34, height: 0.24)\n        let block = TextBlock(\n            text: "こんにちは",\n            boundingBox: CGRect(x: 0.22, y: 0.24, width: 0.18, height: 0.08),\n            confidence: 0.95,\n            ocrSource: "vision-recognition:dialogue",\n            bubbleBox: bubble,\n            layoutSafeRegion: safe,\n            textOrientation: .horizontal,\n            layoutRole: .dialogue\n        )\n\n        let result = MangaTextSegmenter.segment([block], isRightToLeft: false)\n        let unit = result.bubbles.first\n\n        XCTAssertEqual(unit?.bubbleBox, bubble)\n        XCTAssertEqual(unit?.layoutSafeRegion, safe)\n    }\n\n'''
s = s.replace(anchor, test + anchor, 1)
p.write_text(s)
