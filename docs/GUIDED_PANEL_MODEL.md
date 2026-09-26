# Guided Panel / Manga Vision Core ML model

The bundled detector is **Koharu YOLO26s-seg**, exported to `mreader/KoharuYOLO26S.mlpackage`
and compiled by Xcode into `KoharuYOLO26S.mlmodelc`.

Model identity, the SAFETENSORS → Core ML export pipeline, the FP32 precision rationale,
the raw tensor contract, and the mask decoder are documented in
[`KOHARU_YOLO26S_INTEGRATION.md`](KOHARU_YOLO26S_INTEGRATION.md). This file covers how the
rest of the app consumes that output.

## Runtime semantics

Manga Vision is a shared page-analysis layer, not a Guided Panel-only detector. All four
bundled semantic classes are consumed:

- `frame` → `MangaRegionType.panel`, used by Guided Panel and page-structure analysis.
- `dialogue_text` → `MangaRegionType.text`, used as an OCR ROI/performance hint. OCR recall
  is independently protected by the ROI coverage guard, so a detector miss does not
  automatically become an OCR miss.
- `balloon` → `MangaRegionType.balloon`, used for physical speech-balloon geometry,
  text grouping, and the reader's bubble-shaped translation surfaces.
- `onomatopoeia_text` → `MangaRegionType.onomatopoeia`, kept separate from translatable
  dialogue. Effect lettering never creates or expands a Guided Panel focus.

Business code receives only normalized top-left page coordinates and optional
mask-derived contours through `MangaPageAnalysis`; raw class indices, model-input
coordinates, tensor layouts, and mask arithmetic stay inside `MangaVisionKoharuProvider`.

For Guided Panel, `frame` is the navigation authority. text/balloon detections may
disambiguate reading order or conservatively recover a missing hole when multiple independent
signals agree. SFX may help reject a near-identical cross-class alias, but it never synthesizes
a panel or moves the camera. None of the semantic classes is a direct navigation target.
Camera framing centers the selected frame itself and adds bounded outward context so slightly
inset frame regression does not crop the printed panel border.

The provider never fabricates a contour. When a mask is rejected (too few active pixels,
degenerate outline), `MangaVisionRegion.contour` is `nil` and consumers fall back to
rectangle geometry.

## Versioned output contract

`MangaVisionKoharuOutputContract` is the executable boundary for the bundled Core ML
artifact. The current revision requires:

- one `1280x1280` RGB image input, matching the compiled `MLImageConstraint`;
- a `detections` multi-array of shape `[1, 300, 38]`;
- a `protos` multi-array of shape `[1, 32, 320, 320]`;
- no unexpected outputs.

`MangaVisionKoharuProvider` validates this contract when the compiled model is loaded and
throws `MangaVisionKoharuError.invalidContract` if the export drifts. Guided Panel does
not substitute the legacy Vision rectangle detector on this Koharu branch: an unavailable
or unusable frame result is exposed as a transient full-page fallback instead of being
silently replaced by a second detector.

`MangaVisionKoharuOutputContract.revision` is part of `MangaVisionModelManifest.cacheIdentity`,
so changing the accepted model interface automatically invalidates old Manga Vision cache
entries. `MangaPageAnalysis.schemaVersion` (currently 5) is checked independently when a
cached analysis is read.

## Versioned calibration

`MangaVisionCalibrationProfile.bundled` is the single production source for confidence
filtering and same-class de-duplication. The same profile is used by the base provider and
when adaptive full-page/tile results are merged.

`MangaVisionKoharuProvider` applies the profile's per-class de-duplication to its own
output, because the end-to-end head can still emit two rows for one instance. The adaptive
merge applies the same profile, so de-duplication has exactly one source of truth. The
decoder performs no de-duplication of its own.

| Semantic class | Confidence | Merge IoU | Containment |
| --- | ---: | ---: | ---: |
| panel/frame | 0.25 | 0.68 | 0.96 |
| text/dialogue_text | 0.25 | 0.58 | 0.88 |
| balloon | 0.25 | 0.62 | 0.90 |
| onomatopoeia/onomatopoeia_text | 0.25 | 0.58 | 0.88 |

The confidence column is the checkpoint's own recommended operating point. The IoU column
is **not** a detector NMS parameter: the bundled head is end-to-end and NMS-free, so it only
governs de-duplicating overlapping rows and merging a full-page pass with overlapping
refinement tiles. The profile revision is part of the cache identity, so threshold changes
cannot reuse stale detector results.

## Regression and quality gate

`MangaVisionRegressionGateTests` performs four deliberately separate checks:

1. **Calibration/contract gate**: asserts the revisioned profile, the frozen class order, and
   the raw output shapes.
2. **Artifact gate**: loads the real compiled `KoharuYOLO26S.mlmodelc`, validates its
   input/output contract, and executes real inference.
3. **24-case runtime stability corpus**: two pinned repository image fixtures are rendered at
   twelve deterministic source resolutions each and passed through the real bundled model. The
   gate verifies normalized geometry and compares each image family against its 1.0x baseline
   using panel/balloon stability recall.
4. **Release policy gate**: asserts `MangaVisionRegressionGate.release` still carries the
   reviewed accuracy thresholds, so the stability corpus cannot silently re-tune them.

The 24 cases are listed in `mreaderTests/Fixtures/manga_vision_regression_corpus.json`. They
are regression inputs, not 24 independently human-annotated pages. The corpus has **no
verified labels** — its expected set is the model's own 1.0x output — so it gates on a
recorded stability floor (balloon >= 0.95, panel >= 0.70; measured 1.000 and 0.750) rather
than on the accuracy release gate. The release gate is reserved for a corpus with verified
expected regions.

`MangaVisionRegressionMetrics` exposes the release metrics required for a future fully
verified accuracy corpus:

- panel recall;
- text recall;
- balloon recall;
- final OCR recall;
- fallback rate;
- average inference count per page;
- maximum inference count observed on any page.

The release gate does **not** convert missing ground-truth labels into a fake pass or
failure. Recall dimensions are gated only when verified expected regions exist. Existing
translation/OCR gold files that remain `candidate` are not represented as human-verified
accuracy truth.

The adaptive inference budget is owned by `MangaVisionInferencePlanner`: one full-page
baseline plus at most six refinement tiles, so a single page may legitimately perform up to
seven model passes. The release gate imports that planner-owned hard limit instead of
maintaining another numeric copy. It gates the **maximum observed single-page count**, while
the average remains a reporting metric; therefore a cheap corpus average cannot hide a page
that exceeded the planner contract.

The default release thresholds are panel recall >= 0.80, text recall >= 0.75, balloon recall
>= 0.70, final OCR recall >= 0.80, fallback rate <= 0.20, and maximum model passes on any
page <= `MangaVisionInferencePlanner.maximumInferencePassCount` (currently 7). Changing these
thresholds or the planner budget should be treated as a reviewed quality-policy change
rather than a test workaround.
