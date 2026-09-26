# Koharu YOLO26s-seg integration

The bundled comic-page detector is **Koharu YOLO26s-seg**, an instance-segmentation
model that replaces the retired `MangaVisionV2B5` FP32 detector and the older
Vision-based `PanelDetector`.

## Model identity

| Field | Value |
| --- | --- |
| Bundled resource | `mreader/KoharuYOLO26S.mlpackage` |
| Compiled artifact | `KoharuYOLO26S.mlmodelc` |
| Runtime model ID | `manga-vision-koharu-yolo26s-coreml-fp32-1280` |
| Provider | `MangaVisionKoharuProvider` |
| Router mode | `KoharuYOLO26S` (`MangaVisionProviderMode.productionDefault`) |
| Architecture | YOLO26s segmentation, end-to-end NMS-free head |
| Parameters | 11,437,172 |
| Precision | Core ML ML Program, **full FP32** |
| Input | `image`, RGB image, `1280x1280` |
| Outputs | `detections [1, 300, 38]`, `protos [1, 32, 320, 320]` |
| Upstream source | [mayocream/koharu-yolo26s](https://huggingface.co/mayocream/koharu-yolo26s) |
| Pinned revision | `aa7b56752bc91337e0af1e44ad08b4022c9a975b` |
| Source files | `models/koharu-yolo26s/` (`model.safetensors` + `SHA256SUMS` + `SOURCE.md`) |
| Export manifest | `models/koharu-yolo26s/coreml-export-manifest.json` |

Terminology: the checkpoint's raw class names are `frame`, `dialogue_text`,
`balloon`, `onomatopoeia_text`. The app-side domain names are
`MangaRegionType.panel`, `.text`, `.balloon`, `.onomatopoeia`.

## Classes

| Model index | Checkpoint name | Domain type | Consumer |
| ---: | --- | --- | --- |
| 0 | `frame` | `.panel` | Guided Panel, page structure |
| 1 | `dialogue_text` | `.text` | OCR ROI planning |
| 2 | `balloon` | `.balloon` | Balloon geometry, text grouping, translation surfaces |
| 3 | `onomatopoeia_text` | `.onomatopoeia` | Art-lettering separation, translation context |

## What changed from the retired five-class contract

`MangaPageAnalysis.schemaVersion` is now **5**. Older entries are rejected by the
cache reader, so no page can mix retired person-class structure with the active
model's output.

**Removed.** The retired detector's `face` and `body` classes, and everything built
on them:

- `MangaRegionType.face`, `MangaRegionType.body`
- `MangaPageAnalysis.faces`, `.bodies`
- `MangaPersonCandidate`, `MangaSpeakerCandidate`, `MangaSemanticText`
- `MangaSemanticAnalyzer.personCandidates(for:persons:)` and `speakerCandidates`
- `GuidedPanelSemanticViewportPlanner`'s person-assisted focus expansion
- the translation context's `speakerHints`
- `MangaVisionHardCaseAffectedArea.face/.body`,
  `MangaVisionHardCaseIssueType.wrongPerson/.multipleFacesConfused/…`,
  `MangaVisionHardCaseProductImpact.personAssociation`,
  and the debug overlay's face/body/relation layers

Locally captured hard-case records that still carry retired raw values decode
leniently (`face`/`body` → `.other`, person issue types → `.unspecifiedVisualError`,
`person_association` → `.none`) instead of failing the whole store.

**Added.**

- `MangaRegionType.onomatopoeia` and `MangaPageAnalysis.onomatopoeias`.
  `MangaPanelAnalysis.onomatopoeias` and `MangaSemanticPage.unassignedOnomatopoeias`
  keep sound-effect lettering separate from translatable dialogue. Effect regions are
  surfaced in the translation context as artwork, and they never create or expand a
  Guided Panel focus.
- **Real instance masks.** The segmentation head supplies a contour for every region
  it keeps, so `MangaVisionRegion.contour` is populated again. `PanelReadingOrder`,
  `MangaPageStructureGraph`, balloon geometry, and the reader's bubble surfaces all
  consume it; `MangaVisionProviderCapabilities.supportsRegionMask` is true.
- **NMS-free decoding.** The end-to-end head ranks and de-duplicates its own output,
  so `MangaVisionKoharuDecoder` applies no IoU NMS. `MangaVisionClassCalibration`'s
  per-class threshold is therefore a *merge* threshold (used when a long page is
  analysed as a full-page pass plus overlapping refinement tiles), not a detector NMS
  parameter. It is named `iouThreshold` accordingly.

## Input contract

`MangaVisionKoharuPreprocessor` reproduces the ultralytics `LetterBox` transform the
checkpoint was trained with:

- aspect-preserving resize onto a `1280x1280` canvas, `scaleup` allowed;
- centered padding filled with **gray 114**, not white — a white border reads as page
  art to the model;
- padding origins use the ultralytics `round(d - 0.1)` policy;
- no mean/std normalization; the model carries the only scaling step (`1/255`);
- the resize reproduces OpenCV `INTER_LINEAR` (half-pixel sample centers, two taps,
  11-bit fixed-point accumulator with round-half-up). Core Graphics'
  platform-dependent kernel is deliberately avoided because it changes borderline
  detections.

When the source is already bounded to the model input size — which the adaptive layer
guarantees — the resize is an identity and is skipped.

## Output contract and decoding

```
detections : [1, 300, 38] per row [x1, y1, x2, y2, confidence, classIndex, coefficient x 32]
             boxes and confidences are already final: confidence is sigmoided and
             classIndex is argmaxed. Boxes are in model-input pixels (0...1280).
protos     : [1, 32, 320, 320] mask prototypes at 1/4 of the input resolution.
```

Decoding:

1. Keep rows with `confidence >= 0.25` (the checkpoint's own recommended operating
   point).
2. Map each box through the saved letterbox `(value - padding) / gain` transform into
   page-normalized coordinates.
3. Evaluate the instance mask **only inside the detection's own box**, in prototype
   space. `mask = sigmoid(coefficients · protos)`.
4. Threshold the mask at 0.5 and distil a row-extent outline: sample rows across the
   mask, take the left edge walking down and the right edge walking back up, and cap
   the ring at `MangaVisionContour.maximumPointCount` (32). A mask is rejected when it
   has fewer than 12 active pixels or fewer than two usable rows.

## Why the export is FP32

A plain `compute_precision=FLOAT16` conversion silently corrupts the end-to-end head.
The head selects detections with `topk` over ~33,600 anchor slots and then gathers with
those indices; FP16 cannot represent integers above 2048 exactly, so the index math
degrades. Measured on `sample_shirohage_manga.jpg`:

| Conversion | detections max abs diff | top-3 confidences |
| --- | ---: | --- |
| FP32 | `8.5e-4` | `0.9148 / 0.8887 / 0.5591` |
| FP16 | `1.1e+3` | `0.8882 / 0.2332 / 0.0804` |

FP32 reproduces PyTorch exactly, so the package ships FP32 — the same choice the
retired detector made. Consequence: the artifact is ~40 MB and the neural engine
cannot host FP32, so `MLModelConfiguration.computeUnits = .all` lets the runtime fall
back to the GPU.

## Reproducing the artifact

```bash
pip install 'ultralytics==8.4.43' coremltools onnx onnx2torch safetensors opencv-python
python3 scripts/export_koharu_yolo26s_coreml.py
```

The script verifies every pinned source against `models/koharu-yolo26s/SHA256SUMS`
(fail closed), strict-loads the state dict, asserts the `(detections, protos)` shapes,
exports SafeTensors → TorchScript → ONNX → Core ML FP32, and gates the result on a
PyTorch-vs-Core-ML parity check over two real page fixtures before writing the package
and `models/koharu-yolo26s/coreml-export-manifest.json`.

The path is indirect because Core ML cannot consume ONNX directly in coremltools 9 and
the native ultralytics graph trips the TorchScript frontend on a tensor-to-`int` cast.
The ONNX graph is the stable interchange format and was verified to match PyTorch to
`5e-4`.

## Model weight policy

The Core ML weights ship inside `mreader/KoharuYOLO26S.mlpackage`. The retired
private-weight mechanism (scheme pre-action, `scripts/materialize_private_model_weight.sh`,
`scripts/bootstrap_private_model_access.sh`, CI materialization steps, and the matching
`.gitignore` rule) has been removed: the upstream `model.safetensors` is already tracked
in this repository, so keeping the derived Core ML weights private would add CI
complexity without protecting anything.

`mreaderTests/Fixtures/koharu/` mirrors the pinned `config.json`, `export-manifest.json`,
and `coreml-export-manifest.json` so the contract tests can assert the frozen class order
without reaching outside the test bundle.

## Known limits

- **Adaptive pre-scale.** `AdaptiveMangaVisionProvider` bounds the source to the model
  input size with Core Graphics before the provider letterboxes it. The provider's own
  OpenCV-faithful resize therefore usually runs as an identity, but the CGContext
  pre-downscale is still not kernel-identical to the training pipeline. The export
  parity harness validates the model contract, not that pre-scale.
- **Memory.** `protos` is `[1, 32, 320, 320]` float32 (13 MB); the mask decode allocates
  only per-detection box regions, never the full prototype plane.
- **Scale stability.** Measured over the 24-case corpus (`sample_shirohage_manga.jpg` at
  0.45x-1.00x, and `manga_page_publicdomainq.png`): balloon recall 1.000, panel recall
  0.750, no fallback, one model pass per page. Text recall is not gateable because the
  1.0x baseline contains no `dialogue_text` on either fixture. The single panel loss is
  `sample_shirohage_manga.jpg`'s large right-hand panel, which drops below the 0.25
  confidence floor once the source is scaled past roughly 0.70x. That is a recorded
  property of this checkpoint, so `MangaVisionRegressionGateTests` gates the corpus on a
  stability floor instead of the release accuracy gate — which requires human-verified
  labels this corpus does not have.

## De-duplication

The end-to-end head is trained to emit one row per instance, but that is a learned
property rather than a guarantee. On `sample_shirohage_manga.jpg` the raw output contains
two `frame` rows describing the same panel at IoU ~0.97 (confidences 0.56 and 0.33).

`MangaVisionKoharuProvider` therefore applies
`MangaVisionCalibrationProfile.bundled.deduplicated(_:type:)` per class before returning,
so the revisioned calibration profile is the single source of truth for same-class
de-duplication on both the base path and the adaptive merge path. The decoder itself
stays a pure tensor-to-region translation and performs no de-duplication.
