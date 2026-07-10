# MReader OCR Accuracy and Shelf Card Sizing Design

Date: 2026-07-10

## Scope

This change improves the existing manga OCR pipeline for mixed Chinese, Japanese, and Korean content. Accuracy is preferred over latency, with an acceptable per-page OCR time of roughly two to five seconds. Apple Vision remains the default on-device recognizer. When the user has explicitly enabled it, only low-confidence cropped regions may be sent to the configured visual model for verification.

The same change also restores the iPhone bookshelf to a two-column large-card layout, with roughly four comic or series cards visible in the primary viewport. It does not redesign the bookshelf or change iPad and Mac adaptive column behavior.

Out of scope:

- Changes to the translation provider, API key, model pool, or Komga synchronization.
- A text EPUB reader.
- Replacing Apple Vision with a cloud-first OCR service.
- Unrelated ReaderView gesture, progress, or paging changes.

## Current Problems and Root Causes

The current implementation already performs original, enhanced, and optional inverted Vision requests, but later stages make the result unreliable:

1. Multiple recognition languages are submitted together without a language-specific pass strategy, which weakens recognition for mixed horizontal and vertical manga text.
2. OCR variants are deduplicated mainly by proximity and confidence. They do not build a consensus from multiple candidate strings.
3. Text fragments are grouped with a greedy merge. A merged union rectangle can continue absorbing nearby fragments, so separate speech bubbles can become one sentence.
4. Estimated font size is approximate, while sampled colors are compared as exact hex strings. Anti-aliasing and textured backgrounds therefore produce inconsistent grouping decisions.
5. OCR boxes use normalized page coordinates, but the overlay multiplies them by the whole SwiftUI view. Under aspect-fit letterboxing, the view bounds and visible image bounds differ, so bubbles are displaced.
6. The overlay and grouping responsibilities are embedded in `AITranslator` and `ReaderView`, making recognition defects difficult to isolate and test.

## Architecture

The new pipeline is:

1. Decode the highest practical source image.
2. Normalize image orientation.
3. Split unusually tall pages into overlapping regions.
4. Produce original, enhanced, and locally inverted recognition variants.
5. Run language-specific Apple Vision passes.
6. Resolve competing OCR candidates into canonical text blocks.
7. Cluster blocks into text lines and vertical columns.
8. Group lines into bounded speech-bubble units.
9. Optionally verify only uncertain cropped regions with the visual model.
10. Map normalized page coordinates into the image's actual displayed rectangle.
11. Render OCR magnification, translation, and debug overlays.

Component responsibilities:

- `OCRPreprocessor`: high-resolution decoding, orientation normalization, slicing, enhancement, and Vision requests.
- `OCRCandidateResolver`: candidate consensus, confidence scoring, language plausibility, and variant deduplication.
- `MangaTextSegmenter`: horizontal-line clustering, vertical-column clustering, speech-bubble grouping, and reading order.
- `OCRCoordinateMapper`: conversions among source pixels, slice coordinates, normalized page coordinates, and SwiftUI display coordinates.
- `AITranslator`: receives stable bubble-level text and translates it. It no longer owns low-level OCR grouping rules.
- `ReaderView`: renders results and debugging information. It does not decide sentence boundaries.

All stored OCR geometry uses normalized coordinates with the original page's top-left corner as the origin. Display conversion happens only at render time.

## Recognition Strategy

The recognizer runs targeted language combinations instead of relying on one request containing every language:

- Chinese and Korean horizontal pass: Simplified Chinese, Traditional Chinese, Korean, and English.
- Japanese pass: Japanese and English.
- Vertical candidate pass: Japanese-first recognition for regions whose geometry indicates vertical text.

Each Vision observation may retain up to three candidates. Candidate scoring includes:

- Vision confidence.
- Agreement between original, enhanced, and inverted variants.
- Plausibility for Chinese, Japanese, Korean, Latin, punctuation, and numeric content.
- Replacement-character and symbol noise penalties.
- Geometric compatibility with nearby text.
- Confidence consistency across overlapping slices.

Black-background and mixed-background text must not depend on a whole-slice darkness decision alone. Local contrast around a candidate region determines whether an inverted retry is useful.

## Segmentation and Sentence Reconstruction

Segmentation has three explicit stages.

### Text Line and Column Clustering

Horizontal text is clustered using baseline distance, vertical overlap, font-size similarity, and horizontal gap. Vertical text is clustered using column-center distance, horizontal overlap, column width, and vertical gap.

Thresholds are derived from the median estimated glyph size in the local neighborhood. They are not fixed page-normalized constants, which is essential for long webtoon pages.

### Speech-Bubble Grouping

The system builds an adjacency graph between stable lines or columns. It does not repeatedly enlarge a union rectangle and search for more fragments.

Two nodes may belong to one bubble only when:

- Their writing direction is compatible.
- Their estimated font sizes differ by no more than approximately 25 percent.
- Their text colors are perceptually similar within a tolerance, rather than exact hex equality.
- Their gap is small relative to glyph size.
- Their combined bounds remain locally compact.
- No strong blank-space or intervening-text boundary separates them.

Separate blocks remain separate when their font size, color, writing direction, or local spacing strongly differs. This rule has priority over language-model reconstruction.

### Reading Order and Joining

- Chinese horizontal text is ordered top-to-bottom and then according to the comic's configured page direction.
- Japanese vertical columns are ordered right-to-left inside a bubble, with characters read top-to-bottom.
- Korean and Latin horizontal text preserve word spacing.
- Chinese and Japanese fragments join without arbitrary spaces unless punctuation or explicit whitespace requires them.

The resulting model is one `TextBlock` per speech bubble or independent caption. Original child fragments remain available for diagnostics.

## Optional Visual Verification

Visual verification is disabled unless the user enables it. It is used only for:

- Low-confidence text.
- Strong disagreement among recognition variants.
- Suspected garbled output.
- Ambiguous ordering inside a proposed bubble.

Only a crop around the uncertain text is uploaded, with approximately 15 percent contextual padding. The request includes the crop's source rectangle and reading direction. The response may correct text, writing direction, and local geometry but may not merge content outside the crop. Returned coordinates are validated and mapped back to normalized full-page coordinates.

Failure, refusal, timeout, or malformed output leaves the local OCR result intact and marks it as unverified. It must not remove an otherwise usable local result.

## Coordinate Mapping and Overlay Layout

`OCRCoordinateMapper` calculates the actual visible image rectangle for each fit mode:

- `fitScreen`, `fitHeight`, and `original`: aspect-fit rectangle inside the reader container.
- `fitWidth`: container width with height derived from the source aspect ratio.
- Zoom and pan: the same transform is applied to the image and all OCR overlays.
- Tall-page slices: slice coordinates first map to the complete source page, then to the displayed image rectangle.

Letterbox and pillarbox areas are excluded from image-coordinate scaling. This fixes displaced overlays in landscape and on pages whose aspect ratio differs from the device.

Bubble placement uses the source bubble as its anchor. Candidate placements are evaluated over the source location and nearby top, bottom, left, and right positions. A collision score combines rectangle intersection area and distance from the source. Results are clamped to the visible image rectangle and screen safety margins.

If space is limited, text size may decrease to a readable floor. A bubble must not be pushed far away merely to avoid an overlap.

## OCR Debugging

OCR debugging displays four stages:

- Yellow: raw Vision observations, source variant, text, and confidence.
- Blue: candidate-resolved text lines or vertical columns.
- Green: final bubble groups, reading order, and reconstructed text.
- Red: filtered or low-confidence regions with a specific reason.

Logs include page size, slice count, language pass, raw candidate count, resolved count, bubble count, rejected count, and visual-verification status. Logs must not contain API keys or full remote URLs with credentials.

## Bookshelf Card Sizing

On iPhone, the bookshelf uses two equal-width columns. The available content width is divided between those columns after applying compact horizontal margins and one fixed inter-column gap. A primary viewport should show approximately two rows, or four comic or series cards.

Comic and series cards share:

- The same fixed cell width.
- The same cover aspect ratio and cover frame.
- The same title baseline and maximum line count.
- The same progress-bar position.
- The same metadata row height.
- The same total card height.

Series cover stacking remains inside the fixed cover frame and does not reduce the main cover size or expand the hit area. Vertical spacing is reduced from the current layout while maintaining bottom Tab Bar safe-area clearance.

iPad and Mac retain adaptive multi-column layouts. The iPhone rule does not force two columns on larger devices.

## Data and Compatibility

No `ComicBook` migration is required. OCR intermediate results may be represented by new internal structs but are not persisted as comic source data. Existing OCR settings, translation settings, and cached reading progress remain compatible.

The local file, ZIP, PDF, EPUB, OPDS, and Komga page loaders keep their current behavior. They feed page image data into the same OCR pipeline.

## Error Handling

- An image decode failure reports that the original page could not be prepared for OCR.
- A failed recognition variant does not cancel successful variants.
- If every local pass fails, the reader displays a specific OCR failure and no overlay.
- Visual verification failures fall back to local OCR.
- Invalid or out-of-range coordinates are discarded before rendering.
- Cancellation caused by a page change prevents old OCR results from being applied to the new page.

## Testing and Acceptance

Unit tests cover:

- Candidate consensus across original and enhanced variants.
- Fuzzy duplicate removal without removing nearby distinct text.
- Horizontal fragments of one sentence merging correctly.
- Adjacent speech bubbles remaining separate.
- Font-size and color differences preventing a merge.
- Japanese vertical-column ordering.
- Korean and Latin spacing.
- Slice-to-page coordinate mapping.
- Aspect-fit, fit-width, landscape-letterbox, zoom, and pan mapping.
- Collision placement staying within the visible image rectangle.
- Visual-verification crop coordinates mapping back to the full page.

Integration and simulator checks cover:

- Chinese horizontal, Japanese vertical, and Korean horizontal sample pages.
- White-on-black text and complex panel backgrounds.
- Local image folders, ZIP, PDF, EPUB, and a Komga page.
- OCR debug colors and reasons.
- Page changes cancelling stale OCR work.
- iPhone bookshelf showing two large columns and approximately four cards in the main viewport.
- Series and comics having identical grid alignment.
- iPad and Mac using additional adaptive columns.

The existing horizontal paging, continuous scrolling, reading progress, translation model pool, and media-source synchronization must continue to pass their current tests.
