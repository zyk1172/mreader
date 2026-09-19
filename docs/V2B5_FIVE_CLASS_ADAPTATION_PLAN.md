# Manga Vision V2B5 Five-Class Adaptation Plan

## Baseline

This branch is the five-class development baseline after removing the active
legacy `PanelDetector` model and the OLD/COMPARE runtime selectors. The active
provider is `MangaVisionV2B5Provider`; its class order is fixed as:

| Model class | Domain type | Current contract |
| --- | --- | --- |
| 0 | `panel` (`frame`) | supported |
| 1 | `text` | supported |
| 2 | `face` | supported |
| 3 | `body` | supported |
| 4 | `balloon` | supported |

V2B5 is bounding-box-only. `MangaVisionRegion.contour` remains `nil`, and
`supportsBalloonMask` remains `false`. This is an output capability decision,
not a detection-result heuristic.

The geometric `VisionRectanglePanelDetector` used by
`PanelDetectionService` is a non-model reader-resilience path. It does not
load `PanelDetector` and is kept separate from the removed OLD model fallback.

## Existing consumers

### A. Frame / panel

`MangaPageAnalysis.panels` is consumed by:

- `PanelDetectionService`, which converts the page analysis into
  `DetectedPanel` values and maintains reader layout/cache behavior;
- `MangaSemanticAnalysis` and `MangaPageStructureGraph`, which assign semantic
  regions to panels and provide secondary reading-order evidence;
- `PanelReadingOrder`, Guided Panel focus, viewport, motion, and debug overlay
  paths.

Panel geometry is therefore a compatibility-sensitive input. Changes to panel
post-processing, cache identity, or reading order must be isolated from the
translation/OCR adaptation work.

### B. Text

`MangaPageAnalysis.texts` is consumed by `MangaVisionOCRIntegration` as a
layout-safe-region hint. `MangaVisionTextROIPlanner` turns the regions into
OCR ROIs; `OCRPreprocessor` and `OCRRuntimeService` then run recognition and
produce the existing `TextBlock` contract. Text detections do not themselves
create a physical speech bubble.

### C. Balloon

`MangaPageAnalysis.balloons` is consumed by
`MangaVisionOCRIntegration.applyingDetectedGeometry` and
`bestBalloon(...)`. A usable balloon can become a `TextBlock.bubbleBox`, which
defines a translation-unit boundary. `MangaPageStructureGraph` also groups
balloon rectangles by panel and uses them as narrative anchors for ambiguous
reading order. Existing VLM/visual bubble geometry remains authoritative.

### D. Face

No production OCR or translation consumer currently treats `faces` as an input
to its result. The domain layer preserves face regions, and
`MangaSemanticAnalysis.personCandidates(...)` can pair them with bodies. The
current production use is therefore a preserved semantic capability and an
available future association input, not an enabled speaker assignment.

### E. Body

No production OCR or translation consumer currently treats `bodies` as an
input to its result. Bodies survive `MangaPageAnalysis` and the semantic
person-candidate layer, where they can be paired with faces. No body-driven
translation, Guided Panel, or speaker behavior is enabled by this baseline.

The audit found no production capability inference based on `faces.isEmpty` or
`bodies.isEmpty`. Empty detections must continue to mean “no region detected
on this page”, not “the provider does not support this class”.

## Batch 1: semantic Guided Panel viewport

The first five-class product adaptation deliberately keeps navigation frame-led.

- `frame` remains the only Guided Panel navigation target and continues to own panel count,
  panel index, reading order, page-boundary transitions and fallback behavior.
- `text + balloon` may tighten the camera viewport only after a large panel has already been
  selected. They do not create additional reading stops.
- `face + body` are weak auxiliary evidence only. They cannot create a focus rect, alter
  reading order or create a navigation target.
- A body detection is ignored for viewport assistance unless it is paired with a sufficiently
  confident face. Even then only the upper-body region may protect nearby character context
  from cropping.
- A distant face is not allowed to recenter the camera. Person evidence can only make a bounded
  expansion around an existing text/balloon-driven focus.
- Small panels keep their original whole-panel framing; semantic tightening is reserved for
  large panels where extra zoom can improve readability without fragmenting the page.
- The semantic focus rect is generated while `PanelDetectionService` already owns the shared
  `MangaPageAnalysis`, persisted with the panel layout cache, and consumed by Reader rendering.
  No extra Core ML inference is introduced on tap, page turn or cache hit.

This batch intentionally does not change OCR recognition policy, translation grouping,
speaker assignment, model calibration, NMS, adaptive inference planning or the five-class
model artifact.

## Current translation path

The current path is:

```text
MangaVisionV2B5Provider
  -> MangaVisionService / adaptive page analysis
  -> MangaVisionOCRIntegration + MangaVisionTextROIPlanner
  -> OCRPreprocessor / OCRRuntimeService
  -> TextBlock geometry and MangaTextSegmenter bubble grouping
  -> AITranslationPageCoordinator / TranslationComicIntegration
  -> AITranslator and the existing translation cache/rendering path
```

The important boundaries are:

- V2B5 supplies geometry only; OCR supplies recognized text and confidence.
- `text` supplies a safe placement/recognition hint.
- `balloon` supplies physical bubble ownership and translation grouping when
  the geometry passes the existing validation rules.
- `face` and `body` are not silently injected into OCR prompts or translation
  units in this branch.

## Future insertion points

Face/body adaptation should enter after `MangaPageAnalysis` conversion and
before any future speaker/character association layer. The likely sequence is:

1. Preserve face/body regions in `MangaPageAnalysis` and semantic conversion.
2. Associate regions with panels using `MangaPageStructureGraph` or a new
   semantic association component.
3. Produce ranked, explainable person candidates rather than authoritative
   identities.
4. Add optional speaker/character context to OCR/translation requests only
   after ownership and confidence rules are independently tested.

Potential improvements to evaluate in later work:

- speaker association from balloon-to-face/body spatial evidence;
- character association across panels/pages;
- bubble ownership when multiple people share a panel;
- panel-local context for OCR and translation prompts;
- reading order using semantic anchors without overriding clear geometry;
- translation context that includes stable panel/person references.

## Do-not-break boundaries

The following are intentionally unchanged in this baseline:

- the five-field `MangaPageAnalysis` schema and cache identity behavior;
- existing panel detection cache and geometric safety fallback;
- the OCR ROI full-page fallback when text detections are empty;
- existing visual/VLM bubble precedence;
- translation-unit grouping and translation cache revisions;
- the V2B5 checkpoint, calibration, thresholds, NMS, and model artifact;
- the sealed Manga109-s Final Test evidence and its OBSERVED split status.

This branch does not rewrite translation, OCR, Guided Panel, speaker
assignment, or character recognition. Those changes require separate focused
commits with their own fixtures and regression evidence.

## Archive and licensing boundary

The `v2b5-fallback-archive` tag preserves the last complete app state that
contained the legacy OLD `PanelDetector` fallback. The legacy compiled model is
not carried into this active branch. Historical model/license notes remain
available for provenance; they are not active release resources. The current
MangaSeg attribution document is retained and is not changed by this baseline.
