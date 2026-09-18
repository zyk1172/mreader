# V2B5 mReader Production Switch Review

## Scope

本轮只在桌面副本 `/Users/zhengyunkai/Desktop/mreader` 上进行，分支为
`codex/v2b5-production-review`。本轮是 SIMULATOR-FIRST 阶段：验证冻结的 V2B5
Provider、真实 val-only 页面、Reader、Guided Panel 和实际 OCR 路径；没有切换
production default，没有修改正式 mReader checkout，也没有运行 Final Test。

本轮没有训练、修改 checkpoint、修改 architecture、修改 frozen calibration、修改
NMS/score threshold/max detections，也没有访问 Manga109-s test split。

## Environment

| Field | Value |
| --- | --- |
| Xcode | `/Applications/Xcode-beta.app` |
| Simulator | `测试` |
| Runtime | iOS 26.5 |
| UDID | `A301890E-55DE-46F4-8917-8C96742C30C6` |
| Architecture | arm64 simulator build |
| Concurrent simulators | 1; only the target simulator was booted |
| Optimization gate | `SWIFT_OPTIMIZATION_LEVEL=-O` |

测试结束时目标模拟器已按本轮资源边界关闭；另一台同名模拟器一直保持
Shutdown，未启动第二台模拟器。

## Model and Artifact

| Field | Value |
| --- | --- |
| Model | `MangaVisionDetectorV2B5` |
| Bundled artifact | `mreader/MangaVisionV2B5.mlpackage` |
| Precision | Full FP32 Core ML ML Program |
| Stable tree SHA256 | `ebde3f514e2fb84e48f73bd194041da671337f7b770e3baeae637ed8c5dba4c5` |
| Tree size | 5,908,245 bytes |
| Input | `1x3x640x640` |
| Parameters | 1,390,954 |
| Classes | `0 frame`, `1 text`, `2 face`, `3 body`, `4 balloon` |
| Calibration | `v2b5-calibration-v1` |
| Score threshold | `0.05` |
| Max detections | `300` |
| NMS | frame `0.50`, text `0.55`, face `0.45`, body `0.55`, balloon `0.45` |

The bundled package is the frozen Full FP32 artifact. The Swift decoder keeps the
name-based 12-tensor contract, restores source-page coordinates, applies the frozen
calibration, and preserves `nil` contours for V2B5 regions.

## Provider Policy

- Release builds remain hard-wired to `OLD` / the existing `PanelDetector` provider.
- V2B5 is selectable only in DEBUG through `-mreader-v2b5-provider`.
- The review used `MangaVisionProviderMode.setForDiagnostics(.v2b5)` inside the
  opt-in simulator review test and always restored `.oldProduction` with `defer`.
- No V2B5 mode was persisted in `UserDefaults` after the review.
- The formal mReader checkout was not opened or modified.
- The production switch was not applied and the old provider was not removed.

## Simulator Review

### Python to Swift golden

The fixture was generated from the formal training-repository inference path using the
frozen checkpoint and frozen calibration. It contains no model weights or images and is
stored at `mreaderTests/Fixtures/v2b5_golden/`.

| Check | Result |
| --- | --- |
| Synthetic contract | PASS |
| Real page | `Donburakokko` page `070`, val-only |
| Python detections | 83 |
| Swift detection equivalence | PASS; matched boxes IoU > 0.99 and score difference < 0.02 |
| Six raw input sample values | PASS |
| Contour contract | PASS; `nil` |

The Python input SHA and Swift input SHA are intentionally not bit-identical because
the Python fixture uses Pillow JPEG decoding while the app uses ImageIO. The fixture
therefore compares the decoded sample values within tolerance and the final detections,
not a false byte-for-byte JPEG decode identity.

### Real val-only sample package

| Field | Value |
| --- | --- |
| Package | `v2b5-coreml-val-samples` |
| Source dataset | `Manga109-s-v2026` |
| Split | `val` |
| Pages | 40 |
| Books | 9 |
| `model_predictions_used` | `false` |
| Test images accessed | NO |
| Test inference | NO |

The local sample directory is ignored and contains the Windows-frozen val-only sample
pack. No sample was re-selected during this review.

### Reader, Guided Panel, OCR

The optimized opt-in simulator review passed over the same 40 pages:

| Coverage | Result |
| --- | ---: |
| Semantic page analyses | 40 |
| Panel detection pages | 40 |
| Balloon regions | 874 |
| Contours | `nil` for every V2B5 region and panel |
| OCR pages | 10 |
| OCR raw blocks | 1,420 |
| OCR ROI pages | 10 |

The UI tests also passed the reader fixture flow, progress/offline translation entry,
Guided Panel controls, and OCR controls while running the V2B5 DEBUG provider. This
confirms the actual reader path and OCR runtime path, not only a direct detector call.

### Functional and regression tests

| Test scope | Result |
| --- | --- |
| Golden/provider targeted tests | 10 passed, 0 failed |
| V2B5 simulator val-only review | 1 passed, 0 failed |
| Full `mreaderTests.xctest` | 152 executed, 10 skipped, 0 failed |
| Full `mreaderUITests.xctest` | 37 executed, 0 failed |
| Full Xcode test invocation | `** TEST SUCCEEDED **` |
| V2B5-related failures | 0 |

The 10 unit-test skips are existing environment/data-gated skips; no test was converted
into a pass by copying the test split or by weakening a V2B5 assertion.

### Simulator timing

These measurements are from the optimized arm64 iOS 26.5 simulator run over all 40
val-only pages. They are useful for regression comparison only and are not iPhone ANE,
GPU, thermal, or production-device measurements.

| Stage | Mean ms | Median ms | P95 ms | Min ms | Max ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| Preprocess | 56.1079 | 55.5321 | 60.7182 | 53.1385 | 62.3486 |
| Core ML model | 109.1803 | 107.2509 | 118.3938 | 104.1156 | 135.1613 |
| Postprocess/NMS | 7.8153 | 7.8271 | 8.7239 | 6.6024 | 9.1041 |
| End-to-end | 178.9121 | 170.3956 | 186.4295 | 166.7525 | 425.2863 |

The initial unoptimized Swift preprocessing probe was approximately 3.6 seconds per
page and was a diagnostic implementation state, not a comparable release benchmark.
The final gate uses the optimized implementation and confirms that postprocess/NMS is
now single-digit milliseconds on the simulator.

### Non-failing diagnostics

Core ML emitted the known iOS simulator warning about the unavailable/incompatible
MPSGraph backend (`Espresso compiled without MPSGraph engine`). Tesseract emitted font
construction noise for some OCR diagnostic paths. Neither produced a test failure or
changed the PASS result; these logs are not evidence of iPhone hardware performance.

## Physical Final Verification

Phase B was not run in this simulator-first round.

| Field | Result |
| --- | --- |
| iPhone deployment count in this review | 0 |
| iPhone V2B5 latency | Not measured in this round |
| iPhone V2B5-only memory | Not measured in this round |
| iPhone thermal/stability | Not measured in this round |
| Physical Reader/Guided Panel/OCR smoke | Not run in this round |

The simulator evidence authorizes a later, single-device performance review; it does
not establish the final iPhone Gate and does not authorize a production switch by
itself.

## Decision

**B. `V2B5_PRODUCTION_REVIEW_PARTIAL`**

The complete simulator Phase A passed: golden, Reader, Guided Panel, actual OCR,
balloon bbox compatibility, optimized output path, and the full simulator regression
all passed with zero failures. The overall production-switch review remains partial
because the explicitly required one-time physical iPhone final verification has not
been performed. Production remains on the OLD provider.

## Next Allowed Step

After explicit approval, perform one consolidated iPhone 16 Pro deployment/review for
device latency, V2B5-only memory, thermal/stability, and Reader/Guided Panel/OCR smoke.
Do not run Final Test or access test images as part of that review.
