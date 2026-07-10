# AI Translation Accuracy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Improve OCR and vision translation accuracy through page-level context, stable target languages, validated two-stage vision processing, and source-anchored non-overlapping bubbles.

**Architecture:** Introduce a stable target-language catalog and a structured page translation contract shared by OCR and vision modes. Vision first recognizes source text and geometry, then sends the recognized page through the same translator. Reader layout preserves semantic bubble identity and resolves only visual collisions.

**Tech Stack:** Swift 6, SwiftUI, UIKit text measurement, Vision, URLSession, XCTest, Xcode 27 Beta.

## Global Constraints

- Do not change reader gestures, page loading, storage, Komga synchronization, or reading-progress behavior.
- Preserve the existing OpenAI-compatible Base URL, API key, model pool, cancellation, and rate-limit failover behavior.
- Never merge independent source bubbles solely because their display rectangles overlap.
- Verify the final app on the physical iOS device named `郑云凯`.

---

### Task 1: Stable Target Languages

**Files:**
- Create: `mreader/TranslationTargetLanguage.swift`
- Modify: `mreader/ReaderView.swift`
- Modify: `mreader/Base.lproj/Localizable.strings`
- Modify: `mreader/zh-Hans.lproj/Localizable.strings`
- Modify: `mreader/en.lproj/Localizable.strings`
- Modify: `mreader/ja.lproj/Localizable.strings`
- Modify: `mreader/ko.lproj/Localizable.strings`
- Test: `mreaderTests/mreaderTests.swift`

**Interfaces:**
- Produces: `TranslationTargetLanguage`, `TranslationTargetLanguage.migrateLegacyValue(_:)`, `modelInstruction`.
- Consumes: existing `translation_target_language` AppStorage value.

- [ ] **Step 1: Write failing migration and uniqueness tests**

```swift
@Test func legacyChineseTargetMigratesWithoutDuplicateOption() {
    #expect(TranslationTargetLanguage.migrateLegacyValue("中文") == .simplifiedChinese)
    #expect(TranslationTargetLanguage.migrateLegacyValue("简体中文") == .simplifiedChinese)
    #expect(Set(TranslationTargetLanguage.allCases.map(\.rawValue)).count == TranslationTargetLanguage.allCases.count)
}
```

- [ ] **Step 2: Run the test build and verify the missing-type failure**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild build-for-testing -project mreader.xcodeproj -scheme mreader -destination 'platform=iOS Simulator,id=36299868-0969-4FDF-8CB8-4761F8D4C4A7' -only-testing:mreaderTests`

Expected: compile failure because `TranslationTargetLanguage` does not exist.

- [ ] **Step 3: Implement the language catalog and legacy migration**

Create a `CaseIterable`, `Identifiable`, `Sendable` enum containing `zh-Hans`, `zh-Hant`, `en`, `ja`, `ko`, `fr`, `de`, `es`, `it`, `pt`, `ru`, `th`, `vi`, `id`, and `ar`. Each case supplies a localized title and a model instruction containing the language name and code.

- [ ] **Step 4: Replace the duplicate Picker values and migrate AppStorage on reader appearance**

Use stable raw identifiers as tags. Convert legacy persisted labels once and retain `zh-Hans` as the safe fallback.

- [ ] **Step 5: Build tests and verify Task 1 compiles**

Run the build-for-testing command from Step 2. Expected: `TEST BUILD SUCCEEDED`.

### Task 2: Structured Page Translation

**Files:**
- Create: `mreader/AIPageTranslation.swift`
- Modify: `mreader/AITranslator.swift`
- Test: `mreaderTests/mreaderTests.swift`

**Interfaces:**
- Produces: `AIPageTranslationItem`, `AIPageTranslationResult`, `AITranslator.translatePage(...)`.
- Consumes: `TextBlock`, model pool configuration, `TranslationTargetLanguage.modelInstruction`.

- [ ] **Step 1: Write failing parser tests**

Test unordered IDs, unknown IDs, duplicate IDs, partial responses, Markdown-fenced JSON, and wrong-language validation. Assert valid known items survive when another item is malformed.

- [ ] **Step 2: Run build-for-testing and verify missing page translation symbols**

Run the Task 1 build command. Expected: compile failure for the new page translation types.

- [ ] **Step 3: Implement request DTOs and deterministic response parsing**

Use stable string IDs derived from each block UUID. Parse only known IDs, retain request order, discard duplicate IDs after the first valid result, and return missing IDs separately for bounded fallback.

- [ ] **Step 4: Implement one page-level model request**

Send source text, order, normalized bounds, font scale, color, and page context as strict JSON. Require consistent names, honorifics, terminology, and target language. Keep the existing model pool sequence and cancellation checks.

- [ ] **Step 5: Add target-script mismatch diagnostics**

Detect output dominated by an incompatible script for the selected language. Treat it as a retryable malformed-model result while allowing proper nouns and mixed punctuation.

- [ ] **Step 6: Verify parser and request compilation**

Run build-for-testing. Expected: `TEST BUILD SUCCEEDED`.

### Task 3: Two-Stage Vision Translation

**Files:**
- Modify: `mreader/AITranslator.swift`
- Modify: `mreader/AIPageTranslation.swift`
- Test: `mreaderTests/mreaderTests.swift`

**Interfaces:**
- Produces: `AITranslator.recognizeVisionPage(...)`, validated geometry, and `translateVisionPage(...)` backed by stage 1 plus `translatePage`.
- Consumes: existing image resizing, slicing, model pool, and page-coordinate mapping.

- [ ] **Step 1: Write failing vision geometry tests**

Cover finite normalized boxes, out-of-range clamping, zero-area rejection, invalid bubble-box fallback to expanded text box, and filtered URL/advertisement classifications.

- [ ] **Step 2: Run build-for-testing and confirm failures target geometry validation**

- [ ] **Step 3: Split the vision prompt and parser into recognition-only stage**

Stage 1 returns source text, order, classification, text geometry, bubble geometry, and confidence. It must not return or choose translations.

- [ ] **Step 4: Feed valid recognition items into `translatePage`**

Preserve stage-1 IDs and geometry. Map translated strings back by ID. Missing page results use existing per-item translation without replacing geometry.

- [ ] **Step 5: Preserve long-image slicing and deduplicate overlap regions**

Map slice boxes to full-page normalized coordinates before resolving duplicates by source-text similarity and geometry overlap.

- [ ] **Step 6: Build and verify all vision tests compile**

Run build-for-testing. Expected: `TEST BUILD SUCCEEDED`.

### Task 4: Source-Anchored Bubble Layout

**Files:**
- Modify: `mreader/OCRBubbleLayoutEngine.swift`
- Modify: `mreader/ReaderView.swift`
- Test: `mreaderTests/mreaderTests.swift`

**Interfaces:**
- Produces: measured bubble rectangles with semantic IDs preserved.
- Consumes: source bubble rectangle, translated text, font, line spacing, image bounds, and occupied rectangles.

- [ ] **Step 1: Write failing layout regression tests**

Assert two overlapping independent bubbles remain two items, rectangles stay inside image bounds, nearby placement minimizes anchor distance, and dense text does not produce a zero-size or offscreen rectangle.

- [ ] **Step 2: Run build-for-testing and verify current semantic merge test fails**

- [ ] **Step 3: Replace character-count approximation with actual text measurement**

Use UIKit bounding-rect measurement with the same font and line spacing used by SwiftUI. Clamp the measured size to the displayed image bounds.

- [ ] **Step 4: Remove display-overlap semantic merging**

Delete the `denseGroups` merge based only on intersecting rectangles. Group only blocks that already share an upstream semantic bubble ID.

- [ ] **Step 5: Improve collision scoring**

Score overlap area, anchor distance, image-bound pressure, and displacement direction. Choose the lowest-overlap candidate while keeping every independent bubble.

- [ ] **Step 6: Build and verify layout tests compile**

Run build-for-testing. Expected: `TEST BUILD SUCCEEDED`.

### Task 5: Reader Integration and Physical-Device Verification

**Files:**
- Modify: `mreader/ReaderView.swift`
- Modify: localization files listed in Task 1
- Test: `mreaderTests/mreaderTests.swift`

**Interfaces:**
- Consumes: stable target language, `translatePage`, two-stage vision translation, and measured layout.
- Produces: final OCR/vision translation UI behavior.

- [ ] **Step 1: Update OCR mode to translate all page bubbles in one request**

Apply valid results immediately, fall back only missing IDs, and guard every state update by current page URL and task cancellation.

- [ ] **Step 2: Update vision mode to use the two-stage pipeline**

Keep loading and error behavior unchanged. Do not allow an old page request to update a new page.

- [ ] **Step 3: Add localized labels and actionable translation errors**

Add names for every target language and messages for malformed structured output, wrong target language, and missing IDs.

- [ ] **Step 4: Run source checks and full build-for-testing**

Run:

```bash
git diff --check
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild build-for-testing -project mreader.xcodeproj -scheme mreader -destination 'platform=iOS Simulator,id=36299868-0969-4FDF-8CB8-4761F8D4C4A7' -only-testing:mreaderTests
```

Expected: no whitespace errors and `TEST BUILD SUCCEEDED`.

- [ ] **Step 5: Run unit tests when the Xcode Beta runner is available**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild test-without-building -project mreader.xcodeproj -scheme mreader -destination 'platform=iOS Simulator,id=36299868-0969-4FDF-8CB8-4761F8D4C4A7' -only-testing:mreaderTests -parallel-testing-enabled NO -maximum-parallel-testing-workers 1`

Expected: zero test failures. If the Xcode 27 Beta runner fails to materialize, report that separately from compilation status.

- [ ] **Step 6: Build, install, and launch on `郑云凯`**

Run an iOS device build using destination ID `00008140-000A6D6A2143801C`, install the resulting app with `devicectl`, launch bundle ID `zhengyk.mreader`, and confirm the process remains running.

- [ ] **Step 7: Review final diff for scope**

Confirm no reader gesture, page-loading, storage, Komga, or progress code changed as part of this implementation.
