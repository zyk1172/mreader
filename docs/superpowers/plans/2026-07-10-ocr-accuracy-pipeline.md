# OCR Accuracy Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace MReader's greedy manga OCR grouping and view-bound coordinate math with a tested, accuracy-first local OCR pipeline for mixed Chinese, Japanese, and Korean pages, plus optional low-confidence crop verification.

**Architecture:** `OCRPreprocessor` produces language-aware raw candidates, `OCRCandidateResolver` fuses variant results, `MangaTextSegmenter` creates stable bubble-level text, and `OCRCoordinateMapper` converts page coordinates into the actual displayed image rectangle. `ReaderView` consumes an `OCRPipelineResult`; `AITranslator` translates resolved bubbles and optionally verifies only uncertain crops.

**Tech Stack:** Swift 6, SwiftUI, Apple Vision, Core Image, ImageIO, Swift Testing, OpenAI-compatible multimodal chat completions.

## Global Constraints

- Prefer recognition accuracy over latency; approximately two to five seconds per page is acceptable.
- Support mixed Simplified Chinese, Traditional Chinese, Japanese, Korean, and English manga text.
- Apple Vision remains the default on-device OCR engine.
- Cloud verification is optional and uploads only low-confidence cropped regions, never the whole page through this path.
- Preserve existing local, ZIP, PDF, EPUB, OPDS, and Komga page-loading behavior.
- Do not modify reading progress, page gestures, model-pool selection, or media-source synchronization.
- Preserve user-authored uncommitted changes in the working tree.

---

### Task 1: Coordinate Mapping

**Files:**
- Create: `mreader/OCRCoordinateMapper.swift`
- Test: `mreaderTests/mreaderTests.swift`

**Interfaces:**
- Produces `OCRImageFitMode`, `OCRDisplayTransform`, `OCRCoordinateMapper.displayTransform`, `displayRect`, and `normalizedPageRect`.
- Consumed by Tasks 4 and 6.

- [ ] **Step 1: Write failing aspect-fit and slice-coordinate tests**

```swift
@Test func ocrCoordinateMapperUsesVisibleAspectFitRect() {
    let transform = OCRCoordinateMapper.displayTransform(
        sourcePixelSize: CGSize(width: 1000, height: 2000),
        containerSize: CGSize(width: 1000, height: 1000),
        fitMode: .fitScreen
    )
    #expect(transform.imageRect == CGRect(x: 250, y: 0, width: 500, height: 1000))
    #expect(OCRCoordinateMapper.displayRect(
        forNormalizedPageRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1),
        using: transform
    ) == CGRect(x: 300, y: 200, width: 150, height: 100))
}

@Test func ocrCoordinateMapperRestoresSliceCoordinates() {
    let mapped = OCRCoordinateMapper.normalizedPageRect(
        forSliceRect: CGRect(x: 0.2, y: 0.5, width: 0.4, height: 0.2),
        sourceRect: CGRect(x: 0, y: 0.4, width: 1, height: 0.3)
    )
    #expect(mapped == CGRect(x: 0.2, y: 0.55, width: 0.4, height: 0.06))
}
```

- [ ] **Step 2: Run tests and verify RED**

Run the common unit-test command at the end of this plan. Expected: FAIL because `OCRCoordinateMapper` does not exist.

- [ ] **Step 3: Implement pure coordinate transforms**

```swift
enum OCRImageFitMode: Sendable { case fitScreen, fitWidth, fitHeight, original }

struct OCRDisplayTransform: Sendable, Equatable {
    let imageRect: CGRect
}

enum OCRCoordinateMapper {
    nonisolated static func displayTransform(
        sourcePixelSize: CGSize,
        containerSize: CGSize,
        fitMode: OCRImageFitMode,
        zoomScale: CGFloat = 1,
        panOffset: CGSize = .zero
    ) -> OCRDisplayTransform

    nonisolated static func displayRect(
        forNormalizedPageRect rect: CGRect,
        using transform: OCRDisplayTransform
    ) -> CGRect

    nonisolated static func normalizedPageRect(
        forSliceRect rect: CGRect,
        sourceRect: CGRect
    ) -> CGRect
}
```

Use aspect fit for `fitScreen`, `fitHeight`, and `original`; use full container width for `fitWidth`. Apply zoom and pan after fitting.

- [ ] **Step 4: Run tests and verify GREEN**

Expected: coordinate tests PASS.

- [ ] **Step 5: Commit**

```bash
git add mreader/OCRCoordinateMapper.swift mreaderTests/mreaderTests.swift
git commit -m "feat: add OCR coordinate mapping"
```

### Task 2: Multi-Variant Candidate Resolution

**Files:**
- Create: `mreader/OCRCandidateResolver.swift`
- Modify: `mreader/AITranslator.swift`
- Test: `mreaderTests/mreaderTests.swift`

**Interfaces:**
- Consumes raw `[TextBlock]` from `OCRPreprocessor`.
- Produces `OCRCandidateResolution` and `OCRCandidateResolver.resolve(_:isRightToLeft:)`.
- Consumed by Task 4.

- [ ] **Step 1: Write failing consensus and nearby-distinct tests**

```swift
@Test func ocrCandidateResolverPrefersVariantConsensus() {
    let box = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.05)
    let result = OCRCandidateResolver.resolve([
        TextBlock(text: "你回来了", boundingBox: box, confidence: 0.82, ocrSource: "original"),
        TextBlock(text: "你回来了", boundingBox: box.offsetBy(dx: 0.002, dy: 0), confidence: 0.78, ocrSource: "enhanced"),
        TextBlock(text: "你问来了", boundingBox: box, confidence: 0.86, ocrSource: "inverted")
    ], isRightToLeft: false)
    #expect(result.resolvedBlocks.count == 1)
    #expect(result.resolvedBlocks[0].text == "你回来了")
}
```

Add a second test where two different phrases are close but have insufficient overlap; both must remain.

- [ ] **Step 2: Run tests and verify RED**

Expected: FAIL because `OCRCandidateResolver` does not exist.

- [ ] **Step 3: Implement candidate clustering and scoring**

```swift
struct OCRCandidateResolution: Sendable {
    let resolvedBlocks: [TextBlock]
    let rejectedBlocks: [TextBlock]
}

enum OCRCandidateResolver {
    nonisolated static func resolve(
        _ candidates: [TextBlock],
        isRightToLeft: Bool
    ) -> OCRCandidateResolution

    nonisolated static func colorsAreCompatible(
        _ lhs: String?, _ rhs: String?, maximumDistance: Double = 42
    ) -> Bool
}
```

Cluster only when overlap-over-smaller-area is at least `0.45` or geometry is nearly identical. Score using confidence, variant agreement, character plausibility, and symbol-noise penalties. Do not use center proximity alone.

- [ ] **Step 4: Run tests and verify GREEN**

Expected: consensus and distinct-text tests PASS.

- [ ] **Step 5: Commit**

```bash
git add mreader/OCRCandidateResolver.swift mreader/AITranslator.swift mreaderTests/mreaderTests.swift
git commit -m "feat: resolve OCR candidates by consensus"
```

### Task 3: Manga Text Segmentation

**Files:**
- Create: `mreader/MangaTextSegmenter.swift`
- Modify: `mreader/AITranslator.swift`
- Test: `mreaderTests/mreaderTests.swift`

**Interfaces:**
- Consumes resolved `[TextBlock]` from Task 2.
- Produces `MangaTextSegmentation` and `MangaTextSegmenter.segment(_:isRightToLeft:)`.
- Consumed by Tasks 4 and 6.

- [ ] **Step 1: Write failing segmentation tests**

Test horizontal same-style fragments, gap separation, font-size ratio above `1.25`, perceptually different colors, Japanese vertical right-to-left ordering, Korean/Latin spacing, and prevention of transitive three-bubble merging.

```swift
@Test func mangaSegmenterDoesNotTransitivelyMergeThreeBubbles() {
    let blocks = [
        TextBlock(text: "第一句", boundingBox: CGRect(x: 0.05, y: 0.10, width: 0.20, height: 0.04), estimatedFontScale: 0.04),
        TextBlock(text: "第二句", boundingBox: CGRect(x: 0.27, y: 0.10, width: 0.20, height: 0.04), estimatedFontScale: 0.04),
        TextBlock(text: "第三句", boundingBox: CGRect(x: 0.49, y: 0.10, width: 0.20, height: 0.04), estimatedFontScale: 0.04)
    ]
    #expect(MangaTextSegmenter.segment(blocks, isRightToLeft: false).bubbles.count >= 2)
}
```

- [ ] **Step 2: Run tests and verify RED**

Expected: FAIL because `MangaTextSegmenter` does not exist.

- [ ] **Step 3: Implement fixed-graph segmentation**

```swift
struct MangaTextSegmentation: Sendable {
    let lines: [TextBlock]
    let bubbles: [TextBlock]
}

enum MangaTextSegmenter {
    nonisolated static func segment(
        _ blocks: [TextBlock], isRightToLeft: Bool
    ) -> MangaTextSegmentation
}
```

Create line or column nodes first. Derive thresholds from local median glyph size. Add graph edges only for compatible direction, font size, perceptual color, gap, and compact union bounds. Form components from the fixed graph; never compare a growing union box to new blocks.

- [ ] **Step 4: Remove the old greedy merge**

Keep `AITranslator.groupedMangaTextBlocks` as a temporary forwarding wrapper to `MangaTextSegmenter.segment(...).bubbles`, then delete `shouldMerge` and its chain-merging implementation.

- [ ] **Step 5: Run tests and verify GREEN**

Expected: existing and new grouping tests PASS.

- [ ] **Step 6: Commit**

```bash
git add mreader/MangaTextSegmenter.swift mreader/AITranslator.swift mreaderTests/mreaderTests.swift
git commit -m "feat: segment manga OCR into stable bubbles"
```

### Task 4: Language-Aware OCR Pipeline

**Files:**
- Create: `mreader/MangaOCRPipeline.swift`
- Modify: `mreader/OCRPreprocessor.swift`
- Modify: `mreader/AITranslator.swift`
- Test: `mreaderTests/mreaderTests.swift`

**Interfaces:**
- Produces `OCRPipelineResult` and `MangaOCRPipeline.recognize(in:options:)`.
- Consumes Tasks 2 and 3.
- Consumed by Tasks 5 and 6.

- [ ] **Step 1: Write failing language-pass and staged-result tests**

```swift
@Test func ocrLanguagePassesSeparateJapaneseFromChineseKorean() {
    let passes = OCRPreprocessor.languagePassesForDiagnostics()
    #expect(passes.contains(["zh-Hans", "zh-Hant", "ko-KR", "en-US"]))
    #expect(passes.contains(["ja-JP", "en-US"]))
}
```

Add a staged-result test that preserves raw, resolved, line, bubble, and rejected blocks.

- [ ] **Step 2: Run tests and verify RED**

Expected: FAIL because staged APIs do not exist.

- [ ] **Step 3: Make the preprocessor emit raw candidates**

Normalize orientation before cropping. Run original and enhanced variants for each slice and targeted language pass. Add local inverted retries for dark candidate regions. Retain up to three Vision candidates with source and language metadata. Preserve overlapping `2600px` slices for pages taller than `3600px`.

- [ ] **Step 4: Implement the pipeline**

```swift
struct OCRPipelineResult: Sendable {
    let rawBlocks: [TextBlock]
    let resolvedBlocks: [TextBlock]
    let lineBlocks: [TextBlock]
    let bubbleBlocks: [TextBlock]
    let rejectedBlocks: [TextBlock]
}

enum MangaOCRPipeline {
    nonisolated static func recognize(
        in image: UIImage,
        options: OCRPreprocessor.Options
    ) async throws -> OCRPipelineResult
}
```

Keep `AITranslator.recognizeText` as a compatibility wrapper returning `bubbleBlocks` until Task 6.

- [ ] **Step 5: Run tests and verify GREEN**

Expected: language and stage tests PASS.

- [ ] **Step 6: Commit**

```bash
git add mreader/MangaOCRPipeline.swift mreader/OCRPreprocessor.swift mreader/AITranslator.swift mreaderTests/mreaderTests.swift
git commit -m "feat: add language-aware manga OCR pipeline"
```

### Task 5: Optional Low-Confidence Visual Verification

**Files:**
- Modify: `mreader/AITranslator.swift`
- Modify: `mreader/ReaderView.swift`
- Modify: `mreader/ContentView.swift`
- Test: `mreaderTests/mreaderTests.swift`

**Interfaces:**
- Produces `OCRVerificationRegion` and `AITranslator.visualVerifyOCRRegions`.
- Consumes `OCRPipelineResult` and existing OpenAI-compatible credentials/model selection.

- [ ] **Step 1: Write failing crop-selection and mapping tests**

```swift
@Test func visualOCRVerificationSelectsOnlyUncertainBlocks() {
    let blocks = [
        TextBlock(text: "清楚", boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05), confidence: 0.91),
        TextBlock(text: "�??", boundingBox: CGRect(x: 0.5, y: 0.2, width: 0.2, height: 0.05), confidence: 0.41)
    ]
    #expect(AITranslator.visualVerificationRegionsForDiagnostics(blocks).count == 1)
}
```

Also test 15-percent crop padding, page-edge clamping, and local-to-page coordinate restoration.

- [ ] **Step 2: Run tests and verify RED**

Expected: FAIL because verification APIs do not exist.

- [ ] **Step 3: Implement bounded crop verification**

Use an OCR-specific multimodal prompt requesting corrected text, direction, and local box only. Limit a page to the three least reliable regions per action. Reuse sequential model failover. Validate returned coordinates before full-page mapping. Failure preserves the local block.

- [ ] **Step 4: Add explicit opt-in setting**

Add `@AppStorage("ocr_visual_verification_enabled")`, default `false`, and a reader settings toggle named `低置信度视觉复核` explaining that cropped text may be sent to the configured third-party API.

- [ ] **Step 5: Run tests and verify GREEN**

Expected: crop selection, mapping, and fallback tests PASS.

- [ ] **Step 6: Commit**

```bash
git add mreader/AITranslator.swift mreader/ReaderView.swift mreader/ContentView.swift mreaderTests/mreaderTests.swift
git commit -m "feat: verify uncertain OCR crops visually"
```

### Task 6: Reader Integration and Debug Stages

**Files:**
- Modify: `mreader/ReaderView.swift`
- Modify: `mreader/AITranslator.swift`
- Test: `mreaderTests/mreaderTests.swift`

**Interfaces:**
- Consumes `OCRPipelineResult` and `OCRCoordinateMapper`.
- Replaces flat recognized-block cache with a staged result cache.
- Preserves existing translation and OCR-magnification entry points.

- [ ] **Step 1: Write failing bubble-placement and stale-page tests**

Extract a pure layout calculation and test that bubbles stay inside `imageRect`, avoid overlaps when a nearby candidate is available, and remain near their source. Add a generation-token test proving an old URL result cannot replace the current page.

- [ ] **Step 2: Run tests and verify RED**

Expected: FAIL because Reader still uses whole-view coordinates and a flat cache.

- [ ] **Step 3: Wire the staged pipeline into `LocalImageView`**

Cache by page URL, reading direction, and minimum text height. Translation and OCR magnification both consume `bubbleBlocks`. Preserve rejected items for debugging. Cancel and discard stale page results.

- [ ] **Step 4: Replace view-bound coordinate multiplication**

Calculate `OCRDisplayTransform` from original image size, overlay container, fit mode, zoom, and pan. Use it for translation bubbles, magnification, and debug boxes. Clamp to `imageRect`, not the full screen.

- [ ] **Step 5: Add four-stage debugging**

Render raw observations yellow, resolved lines blue, final bubbles green, and rejected or uncertain regions red. Labels include confidence, source pass, reading order, and rejection reason. Disable hit testing on all debug layers.

- [ ] **Step 6: Run tests and verify GREEN**

Expected: all OCR and existing reader-progress tests PASS.

- [ ] **Step 7: Commit**

```bash
git add mreader/ReaderView.swift mreader/AITranslator.swift mreaderTests/mreaderTests.swift
git commit -m "fix: align OCR bubbles with displayed pages"
```

### Task 7: Regression Verification

**Files:**
- Modify only if verification exposes an OCR-scoped defect.

- [ ] **Step 1: Run all unit tests**

Use the common unit-test command. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 2: Build the app**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild build \
  -project mreader.xcodeproj -scheme mreader \
  -destination 'platform=iOS Simulator,id=36299868-0969-4FDF-8CB8-4761F8D4C4A7'
```

Expected: `** BUILD SUCCEEDED **` with no new OCR-related warnings.

- [ ] **Step 3: Simulator smoke test**

Install and launch on iPhone 17 simulator `36299868-0969-4FDF-8CB8-4761F8D4C4A7`. Confirm the process remains running for at least 10 seconds.

- [ ] **Step 4: Manual OCR acceptance**

Use Chinese horizontal, Japanese vertical, and Korean horizontal pages. Verify stage boxes, aspect-fit alignment, black-background text, no cross-bubble merges, and optional low-confidence crop verification. Repeat with one local page and one Komga page.

- [ ] **Step 5: Scope and whitespace check**

```bash
git diff --check
git status --short
```

Confirm no reading-progress, gesture, page-loader, or media-source code changed beyond the listed OCR integration points.

## Common Unit-Test Command

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild test \
  -project mreader.xcodeproj -scheme mreader \
  -destination 'platform=iOS Simulator,id=36299868-0969-4FDF-8CB8-4761F8D4C4A7' \
  -only-testing:mreaderTests
```
