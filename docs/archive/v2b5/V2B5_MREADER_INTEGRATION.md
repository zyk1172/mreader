# V2B5 mReader Integration

## Scope

本记录对应桌面副本 `/Users/zhengyunkai/Desktop/mreader`，不是正式 mReader
checkout。验证分支为 `codex/v2b5-mreader-integration`，生产默认仍为旧
`PanelDetector` Provider；本轮没有修改正式项目、训练、权重、校准、NMS、阈值或
`mReader` production default。

## Model

| Field | Value |
| --- | --- |
| Artifact source | `/Users/zhengyunkai/Documents/开发项目/正式项目/工具/manga-vision-training/exports/coreml/diagnostic/MangaVisionV2B5_FP32.mlpackage` |
| Bundled resource | `mreader/MangaVisionV2B5.mlpackage` |
| Architecture | `MangaVisionDetectorV2B5` |
| Precision | Core ML Full FP32 |
| Tree SHA256 | `ebde3f514e2fb84e48f73bd194041da671337f7b770e3baeae637ed8c5dba4c5` |
| Tree bytes | 5,908,245 |
| Input | `1x3x640x640` |
| Parameters | 1,390,954 |
| Classes | `0 frame`, `1 text`, `2 face`, `3 body`, `4 balloon` |
| Calibration | `v2b5-calibration-v1` |
| Score threshold | `0.05` |
| Max detections | `300` |
| NMS | frame `0.50`, text `0.55`, face `0.45`, body `0.55`, balloon `0.45` |

The copied package was re-hashed locally with the training repository's stable
`manga-vision-mlpackage-tree-v1` algorithm. The four package files and the resulting
tree hash match the frozen source artifact.

## Provider

| Role | Implementation | Model | Default |
| --- | --- | --- | --- |
| Old | `YOLOMangaVisionProvider` | `PanelDetector` segmentation export | Yes |
| New | `MangaVisionV2B5Provider` | `MangaVisionV2B5` FP32 ML Program | No |
| Diagnostic router | `MangaVisionProviderRouter` | `OLD`, `V2B5`, `COMPARE` in DEBUG | DEBUG only |

`MangaVisionService` now receives the router through the existing adaptive provider
boundary. In DEBUG, the selector can choose V2B5 or comparison mode. In a non-DEBUG
build the router is hard-wired to `.oldProduction`, so this change does not silently
switch the reader's production behavior.

The V2B5 actor caches one `MLModel` instance and uses `MLComputeUnits.all`. It returns
the existing `MangaPageAnalysis` domain type; Guided Panel, OCR, and translation code
do not receive Core ML tensor names or pyramid levels.

## Output Contract and Decoder

The contract is name-based and shape-checked. It does not sort Core ML feature names or
depend on dictionary enumeration order.

| Semantic | Core ML output | Level | Role | Shape | Stride |
| --- | --- | --- | --- | --- | --- |
| `p2_cls` | `conv2d_77` | P2 | classification | `[1,5,160,160]` | 4 |
| `p2_bbox` | `conv2d_78` | P2 | bbox | `[1,4,160,160]` | 4 |
| `p2_centerness` | `conv2d_79` | P2 | centerness | `[1,1,160,160]` | 4 |
| `p3_cls` | `conv2d_88` | P3 | classification | `[1,5,80,80]` | 8 |
| `p3_bbox` | `conv2d_89` | P3 | bbox | `[1,4,80,80]` | 8 |
| `p3_centerness` | `conv2d_90` | P3 | centerness | `[1,1,80,80]` | 8 |
| `p4_cls` | `conv2d_99` | P4 | classification | `[1,5,40,40]` | 16 |
| `p4_bbox` | `conv2d_100` | P4 | bbox | `[1,4,40,40]` | 16 |
| `p4_centerness` | `conv2d_101` | P4 | centerness | `[1,1,40,40]` | 16 |
| `p5_cls` | `conv2d_110` | P5 | classification | `[1,5,20,20]` | 32 |
| `p5_bbox` | `conv2d_111` | P5 | bbox | `[1,4,20,20]` | 32 |
| `p5_centerness` | `conv2d_112` | P5 | centerness | `[1,1,20,20]` | 32 |

Preprocessing is explicit RGB, white letterbox, 640 square, NCHW float32 normalized to
`0...1`; resized dimensions use the frozen round policy and padding uses floor. The
decoder restores source-page coordinates with the saved scale and padding. It uses
`sqrt(sigmoid(classification) * sigmoid(centerness))`, `softplus` bbox distances,
per-class frozen NMS, a global pre-NMS cap of `1200`, and a final cap of `300`.

The device run and the full regression run both validated the compiled model's input and
all 12 output shapes. The eight new `MangaVisionV2B5ProviderTests` passed, including
class index `4 -> balloon`, explicit output mapping, letterbox restoration, frozen NMS,
and a cross-class A/B comparator case.

The Swift test is a deterministic compact decoder contract fixture. It is not a new
training pipeline and does not use the Manga109-s test split. An independently stored
Python raw-tensor golden fixture was not added to this mReader copy; the prior training
repository Stage 1/2 Python-vs-Core-ML correctness evidence remains the reference.

## Capability Matrix

| Capability | Old PanelDetector | V2B5 |
| --- | ---: | ---: |
| Frame detection | Yes | Yes |
| Text detection | Yes | Yes |
| Face detection | No | Yes |
| Body detection | No | Yes |
| Balloon bbox | Yes | Yes |
| Balloon mask/contour | Yes | No |

V2B5 never fabricates a contour from a bbox. `MangaVisionRegion.contour` remains
optional and is `nil` for V2B5 regions.

## Balloon Mask Dependency

The audit found these boundaries:

| Consumer | Exact mask required? | V2B5 behavior | Fallback/handling |
| --- | --- | --- | --- |
| `PanelDetectionService` / `PanelReadingOrder` | No; contour is an optional shape refinement | Uses V2B5 frame bbox; contour-based overlap checks fall back to rectangle geometry | Existing rectangle fallback remains available |
| `MangaPageStructureGraph` | No; panel contour only refines point-in-panel | Uses bbox containment when contour is absent | No synthetic contour |
| `MangaVisionOCRGeometry` / OCR ROI | No; uses text and balloon normalized bboxes | V2B5 balloon bbox can become `bubbleBox`/layout boundary | Existing visual/VLM bubble remains authoritative |
| `MangaVisionAdaptiveInference` cache/remap | No; preserves optional contour | Carries `nil` contour faithfully | No mask substitution |
| Debug overlay | No | Draws available bbox and only draws contours when present | Visual difference is explicit |

This means bbox-only V2B5 is usable for frame, text, balloon grouping hints, face, and
body diagnostics. A future mask-only consumer must either retain the old provider as a
fallback or remain disabled; no such consumer was silently changed in this round.

## A/B Pages

- Source: ignored local copy of the verified `v2b5-coreml-val-samples` package.
- Pages: 40.
- Books: 9.
- Manifest split: `val`.
- `model_predictions_used`: `false`.
- Test images accessed: **NO**.
- Test inference: **NO**.
- The sample images are not staged or committed; only the test target's local ignored
  resource copy was used.

## Physical iPhone A/B

Device: iPhone 16 Pro, iOS 27.0 (build 24A437). The test completed with zero prediction,
output-contract, or crash failures. The comparator is diagnostic only; because the old
model has no face/body outputs, its aggregate match ratio is not an accuracy metric and
is not used to declare either model more accurate.

| Metric | Old | V2B5 |
| --- | ---: | ---: |
| Total detections | 2,048 | 4,681 |
| Same-class matched | 1,633 | 1,633 |
| Old-only | 415 | — |
| V2B5-only | — | 3,048 |
| Cross-class flips | 49 | 49 |

For the shared classes only (`frame`, `text`, `balloon`), the counts were:

| Class | Old | V2B5 | Same-class matched | Old-only | V2B5-only |
| --- | ---: | ---: | ---: | ---: | ---: |
| Frame | 511 | 528 | 446 | 65 | 82 |
| Text | 815 | 1,163 | 585 | 230 | 578 |
| Balloon | 722 | 891 | 602 | 120 | 289 |

V2B5 additionally produced 685 face and 1,414 body regions. The old provider produced
neither class. These differences are expected model-output differences, not a ground
truth evaluation.

### Downstream smoke

- Guided-panel semantic pages: `40/40` completed through
  `MangaSemanticAnalyzer`; no semantic construction failure.
- OCR ROI geometry pages: `40/40` completed through
  `MangaVisionTextROIPlanner`; all normalized ROI bounds remained within `0...1`.
- Face detections observed: `685`.
- Body detections observed: `1,414`.
- Full Reader UI gesture/scroll behavior was not run in this test; this is a provider
  and domain-consumer smoke, not a replacement for manual Reader review.
- The actual OCR engine was not invoked; ROI planning and bbox-based balloon geometry
  were exercised.

## Timing

All timings below are physical iPhone provider timings over 40 pages. Old Vision's
internal preprocessing is owned by `VNImageRequestHandler` and is attributed to its
model stage; V2B5 exposes preprocessing separately.

| Provider / stage | Mean ms | Median ms | P95 ms |
| --- | ---: | ---: | ---: |
| Old preprocess | 0.000 | 0.000 | 0.000 |
| Old model | 15.112 | 16.063 | 18.303 |
| Old postprocess/mask | 18,240.372 | 18,927.615 | 24,448.849 |
| Old total | 18,260.696 | 18,949.483 | 24,467.265 |
| V2B5 preprocess | 56.477 | 55.292 | 63.829 |
| V2B5 model | 29.352 | 29.293 | 31.923 |
| V2B5 postprocess/NMS | 267.799 | 258.394 | 334.033 |
| V2B5 total | 353.649 | 343.294 | 427.122 |

The earlier model-only device benchmark remains separate evidence (`18.757 ms` median
for the Full FP32 model). The provider measurement includes image preparation, output
materialization, decode, NMS, and domain conversion.

## Memory

Physical footprint measurements from the same A/B process:

- Before provider load: `45.580 MB`.
- After old provider warm-up: `103.674 MB`.
- After both providers warm-up: `300.533 MB`.
- The V2B5 addition while both providers are resident was approximately `196.859 MB`.
- A V2B5-only isolated footprint was not measured in this combined A/B run; the product
  build does not require both providers to remain resident in production mode.

## Stability and Tests

### Integration-specific evidence

- Physical A/B: **PASS**, 1 test, 0 failures, 815.333 seconds.
- V2B5 contract/provider tests: **8 passed**.
- Compiled model description contract: **PASS**.
- Prediction failures: `0`.
- Output contract failures: `0`.
- Crashes: `0`.

### Full DEBUG device regression

The non-A/B full suite reported `588` passed, `9` skipped, and `2` failures in `599`
result entries. The two failures are pre-existing `LocalResourceAccessPolicy` tests:

- `localResourceAccessPolicyStartsSecurityScopeOnlyForExternalURLs()`
- `RuntimeAccessPolicyTests.appOwnedPathDoesNotRequestSecurityScope()`

The working tree has no changes to `ComicManager.swift` or those tests, and the failure
is about iOS temporary-path ownership, not V2B5. Xcode's post-test diagnostic collector
also emitted an environment warning because its subprocess could not locate `devicectl`
in PATH; the test result itself was still collected.

## Git and Artifacts

- Branch: `codex/v2b5-mreader-integration`.
- Existing `PanelDetector` resource remains untouched.
- `mreader/MangaVisionV2B5.mlpackage` follows the repository's existing tracked Core ML
  package policy and is the only model artifact intended for commit.
- `mreaderTests/V2B5ValSamples/` is ignored and must not be committed.
- No Manga109-s test image, Manga109-s full dataset, checkpoint, or debug overlay is
  committed.
- No production default switch was made.

## Decision

**B. V2B5_INTEGRATION_PARTIAL — DOWNSTREAM COMPATIBILITY REVIEW NEEDED**

The provider, contract, real val-only page execution, bbox-only balloon semantics, and
timing evidence are in place. Production-switch review remains pending because the
current evidence is a semantic downstream smoke rather than a full Reader/OCR UI run,
the local branch has no independent Python raw-tensor golden fixture, and the full device
regression retains two unrelated existing path-policy failures.
