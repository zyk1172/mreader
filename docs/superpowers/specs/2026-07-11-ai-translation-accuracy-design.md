# MReader AI Translation Accuracy Design

## Scope

This change improves only the accuracy of OCR-based translation, vision-based
translation, target-language selection, and translated bubble placement. It
does not change local OCR preprocessing, reader gestures, page loading, comic
storage, Komga synchronization, or reading progress.

## Problems

### OCR translation loses page-level context

The reader currently submits each OCR bubble as an independent concurrent
translation request. A textual page context is attached, but the model still
returns each result in isolation. Names, honorifics, pronouns, terminology, and
tone can therefore vary between bubbles on the same page.

### Vision translation combines too many tasks

One vision request currently performs text recognition, reading-order
reconstruction, translation, and precise geometry output. A model can produce
good prose but weak geometry, or good geometry but incomplete translation,
because all objectives compete in one response.

### Display collisions alter semantic grouping

The current display layout may combine independent translation blocks whenever
their proposed rectangles intersect. Screen-space overlap is a layout problem,
not evidence that two source bubbles are one sentence. This can merge unrelated
dialogue and move text away from its source.

### Target-language values are ambiguous

The settings contain both `中文` and `简体中文`. Display labels are also used as
request values, so localization and persisted configuration are coupled.

## Design

## Stable target-language model

Add a `TranslationTargetLanguage` value type with a stable raw identifier, a
localized display title, and an explicit model instruction. Supported targets:

- Simplified Chinese (`zh-Hans`)
- Traditional Chinese (`zh-Hant`)
- English (`en`)
- Japanese (`ja`)
- Korean (`ko`)
- French (`fr`)
- German (`de`)
- Spanish (`es`)
- Italian (`it`)
- Portuguese (`pt`)
- Russian (`ru`)
- Thai (`th`)
- Vietnamese (`vi`)
- Indonesian (`id`)
- Arabic (`ar`)

Persist the stable identifier. Migrate legacy values as follows:

- `中文` and `简体中文` -> `zh-Hans`
- `繁体中文` -> `zh-Hant`
- `英文` -> `en`
- `日文` -> `ja`
- `韩文` -> `ko`

Unknown legacy values fall back to Simplified Chinese without crashing. API
prompts receive both a human-readable language name and a BCP-47-like code,
plus an explicit instruction not to mix the source language into the result
unless the source contains an intentionally untranslated proper noun.

## OCR page translation pipeline

OCR recognition and segmentation remain local. After segmentation, the reader
sends all translatable bubbles on the current page in one structured request.
Each item contains:

- a stable request ID
- source text
- reading order
- normalized source rectangle
- estimated font scale and color when available
- nearby role-neutral page context

The model returns strict JSON keyed by the same IDs. The prompt requires:

- preserve names, titles, honorifics, relationships, emotion, and register
- use consistent terminology across the complete page
- reconstruct only fragments already grouped into the same source bubble
- never merge different IDs
- omit URLs, advertisements, watermarks, copyright text, and page numbers
- return only the requested target language
- preserve intentional sound effects when translation would damage meaning

The parser accepts results only for known IDs, removes duplicate IDs, rejects
empty results, and keeps original ordering. If the page response is malformed,
missing individual IDs, or rejected by an API-compatible provider, only the
missing items fall back to the existing per-bubble translation path. A single
bad item must not discard valid translations from the same response.

## Vision two-stage pipeline

The vision mode becomes two sequential stages.

### Stage 1: recognition and geometry

The first request sees the page image and returns only source-language data:

- stable item ID
- reconstructed source text
- reading order
- text box and text polygon
- source bubble box and bubble polygon
- confidence
- classification such as dialogue, narration, sound effect, URL, watermark,
  advertisement, copyright, or page number

It does not translate. Non-content classifications are filtered before stage 2.
Geometry is validated for finite normalized coordinates, minimum area, page
bounds, and plausible polygon shape. Invalid bubble geometry falls back to an
expanded validated text rectangle instead of being accepted blindly.

### Stage 2: page-level translation

The recognized items are sent to the same structured page translator used by
OCR mode. This provides consistent names and tone and ensures OCR and vision
translation use the same target-language contract. If stage 2 cannot parse a
page response, missing items use bounded per-item fallback. Stage 1 geometry is
retained throughout; translation cannot replace coordinates.

Image slicing remains compatible with the existing long-page behavior. Slice
coordinates are mapped back to full-page normalized coordinates before
deduplication and translation. Items in overlapping slice regions are resolved
by geometry and source-text similarity before assigning stable IDs.

## Translation result validation

Validation is deterministic and does not attempt to judge literary quality.
It rejects:

- empty translations
- explanations, Markdown fences, reasoning, or prompt echoes
- duplicate or unknown IDs
- responses that merely repeat the complete source text
- output dominated by a clearly different script when that conflicts with the
  selected target language

Script validation is a warning and retry signal, not a prohibition on proper
nouns. A failed page-level result may be retried through the next model in the
existing model pool. A provider rate-limit response continues to use the
existing round-robin failover policy.

## Bubble layout

Every translation block retains its source bubble ID. Independent source
bubbles are never merged solely because their display rectangles overlap.

Layout proceeds in reading order:

1. Map the validated source bubble rectangle into the displayed image.
2. Measure the translated text using the actual font, width constraint, line
   spacing, and requested translation lines.
3. Prefer a rectangle centered on and contained by the source bubble.
4. Expand locally when the source bubble is too small, while remaining inside
   the visible image bounds.
5. Resolve collisions by testing nearby positions and scoring overlap area,
   distance from the source anchor, boundary pressure, and connector length.
6. If no collision-free placement exists, choose the lowest-overlap candidate
   without merging semantic items or moving the bubble far across the page.

The display layer uses the model-provided line breaks only when they fit the
measured rectangle. Otherwise SwiftUI wraps the translation naturally. Dense
dialogue remains separate and readable. A grouped bubble is allowed only when
the OCR or vision semantic stage already assigned the fragments the same source
bubble ID.

## Components

- `TranslationTargetLanguage.swift`: stable language catalog and legacy value
  migration.
- `AITranslator.swift`: page request/response models, page-level translation,
  vision recognition stage, validation, and bounded fallback.
- `OCRBubbleLayoutEngine.swift`: measured candidate placement and collision
  scoring without semantic merging.
- `ReaderView.swift`: invokes the appropriate pipeline, maps returned IDs to
  blocks, and renders layout results.
- localization files: translated language labels and error descriptions.
- `mreaderTests.swift`: language migration, structured parsing, partial
  fallback, geometry validation, and collision-layout regression tests.

## Error handling

- A failed vision recognition request produces the existing visible translation
  error and leaves the page readable.
- A failed page-level translation preserves any valid returned items and falls
  back only for missing items.
- Invalid geometry never escapes the image bounds and never crashes layout.
- Cancellation on page change stops both stages and prevents stale results from
  appearing on a new page.
- The model name responsible for a malformed or wrong-language response is
  included in diagnostic logs without logging the API key.

## Verification

Automated tests cover:

- every legacy target-language migration
- unique and stable target-language identifiers
- page JSON parsing independent of response order
- partial response recovery and unknown-ID rejection
- target-script mismatch detection
- vision geometry validation and text-box fallback
- independent overlapping bubbles remaining independent
- measured bubbles staying inside visible image bounds
- collision placement remaining close to its source anchor

Manual tests on the `郑云凯` device cover mixed Japanese/Chinese/Korean pages,
vertical Japanese dialogue, dense neighboring bubbles, long pages, model-pool
fallback, page changes during translation, and every target-language option.
