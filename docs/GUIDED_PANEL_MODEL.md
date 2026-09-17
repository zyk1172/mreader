# Guided Panel / Manga Vision Core ML model

The bundled `mreader/PanelDetector.mlpackage` is an FP16 Core ML export of `ShadowB/Manga109-panel-balloon-text-yolov26-segmentation` (`best.pt`).

- Upstream model: https://huggingface.co/ShadowB/Manga109-panel-balloon-text-yolov26-segmentation
- Upstream checkpoint SHA-256: `0b4376e426fa96af3976afa6a2602421dacf2dec96ef87b4a44f5e8d4971cb6f`
- Architecture: YOLO26s instance segmentation
- Classes: `frame`, `text`, `balloon`
- App export: Core ML ML Program, static 640x640 image input, batch 1, FP16, NMS-free/end-to-end detection output plus segmentation output
- Runtime model ID: `manga109-yolo26s-seg-coreml-fp16-640-v2-manga-vision`
- Upstream model repository declares MIT. Dataset and Ultralytics terms remain independently applicable; review them before redistribution/commercial release.

The original PyTorch checkpoint is not bundled in the app. Xcode compiles the `.mlpackage` into `PanelDetector.mlmodelc` for the application bundle.

## Runtime semantics

Manga Vision consumes all three bundled semantic classes. The model is a shared page-analysis layer rather than a Guided Panel-only detector:

- `frame` -> `MangaRegionType.panel`, consumed by Guided Panel and page-structure analysis.
- `text` -> `MangaRegionType.text`, used as an OCR ROI/performance hint. OCR recall is independently protected by the ROI coverage guard, so a detector miss does not automatically become an OCR miss.
- `balloon` -> `MangaRegionType.balloon`, used for physical speech-balloon geometry and text grouping/layout hints.

Business code receives only normalized top-left page coordinates through `MangaPageAnalysis`; raw class IDs, model-input coordinates, tensor layouts, and mask decoding remain inside `YOLOMangaVisionProvider`.

## Versioned output contract

`MangaVisionOutputContract` is the executable boundary for the bundled Core ML artifact. The current revision requires:

- one 640x640 image input;
- a supported rank-3 detection tensor in either `[1, instances, features]` or `[1, features, instances]` form;
- at least one compatible rank-4 segmentation tensor;
- effective semantic labels covering `panel`, `text`, and `balloon`.

The provider validates this contract when the compiled model is loaded and throws `MangaVisionProviderError.unsupportedOutput` if the export drifts. Guided Panel then follows its existing Vision-rectangle/full-page fallback path rather than interpreting an unknown tensor layout.

`MangaVisionOutputContract.revision` is part of `MangaVisionModelManifest.cacheIdentity`. Changing the accepted model interface therefore invalidates old Manga Vision cache entries automatically.

## Versioned calibration

`MangaVisionCalibrationProfile.bundled` is the single production source for confidence filtering and same-class deduplication parameters. The current profile keeps confidence thresholds at:

| Semantic class | Confidence | NMS IoU | Containment |
| --- | ---: | ---: | ---: |
| panel/frame | 0.24 | 0.50 | 0.92 |
| text | 0.18 | 0.55 | 0.88 |
| balloon | 0.20 | 0.58 | 0.90 |
| face (forward-compatible) | 0.20 | 0.45 | 0.90 |
| body (forward-compatible) | 0.20 | 0.55 | 0.90 |

The bundled checkpoint currently exports only `frame/text/balloon`; face/body values are retained for compatible future checkpoints. The profile revision is also part of the cache identity, so threshold changes cannot reuse stale detector results.

## Regression and quality gate

`MangaVisionRegressionGateTests` performs two different kinds of checks and keeps them deliberately separate:

1. **Artifact/contract gate**: loads the real compiled `PanelDetector.mlmodelc`, validates its input/output contract, and executes real inference.
2. **24-case runtime stability corpus**: two pinned repository image fixtures are rendered at twelve deterministic source resolutions each and passed through the real bundled model. The gate verifies normalized geometry and compares each image family against its 1.0x baseline using Panel/Text/Balloon stability recall.

The 24 cases are listed in `mreaderTests/Fixtures/manga_vision_regression_corpus.json`. They are regression inputs, not 24 independently human-annotated pages.

`MangaVisionRegressionMetrics` exposes the release metrics required for a future fully verified accuracy corpus:

- panel recall;
- text recall;
- balloon recall;
- final OCR recall;
- fallback rate;
- inference count per page.

The release gate does **not** convert missing ground-truth labels into a fake pass or failure. Recall dimensions are gated only when verified expected regions exist. Existing translation/OCR gold files that remain `candidate` are not represented as human-verified accuracy truth.

The default release thresholds are panel recall >= 0.80, text recall >= 0.75, balloon recall >= 0.70, final OCR recall >= 0.80, fallback rate <= 0.20, and inference count/page <= 4.0. Changing these thresholds should be treated as a reviewed quality-policy change rather than a test workaround.
