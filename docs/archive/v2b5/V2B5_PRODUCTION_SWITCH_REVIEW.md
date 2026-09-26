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

Phase B was executed only against the physical iPhone 16 Pro, using the desktop
copy `/Users/zhengyunkai/Desktop/mreader`. No simulator was started during this
phase, and the formal mReader checkout remained clean.

| Field | Result |
| --- | --- |
| Device | iPhone 16 Pro (`iPhone17,1`), `00008140-000A6D6A2143801C` |
| OS/build | iOS 27.0 / `24A437` |
| Architecture | `arm64e` |
| Deployment count | 2; first combined gate invocation, second UI-only retry |
| Low Power Mode | Off at start and end |
| Thermal | `nominal` at start, after benchmark, and after smoke |
| V2B5-only provider gate | PASS; 40/40 val-only pages |
| Strict output contract | PASS; 12-output contract |
| Model load count | 1 |
| Prediction / contract failures | 0 / 0 |
| Crashes / memory warning | 0 / 0 |
| Main-thread blocking | NO |

### V2B5-only memory

The run used only `MangaVisionV2B5Provider`; the OLD provider was not loaded.
The initial allocation rises during model warm-up and representative image/cache
work, then settles rather than growing monotonically through the final pages.

| Sample | Physical footprint |
| --- | ---: |
| M0 before model load | 57.033 MB |
| M1 after model load | 68.736 MB |
| M2 after first warm inference | 235.721 MB |
| M3 after representative pages | 308.159 MB |
| M4 after 40 pages | 306.409 MB |
| Sampled maximum | 369.299 MB |
| Model load count | 1 |
| Memory warning | No |

The final 10-page footprint was not monotonically increasing, and M4 was below
M3. The 40-page delta relative to the post-warm sample was `+70.688 MB`; this
is recorded as initial/cache allocation behavior, not a demonstrated unbounded
retention leak.

### Physical provider performance

All timings are release-like Swift `-O` measurements over the same 40 frozen
val-only pages. They are physical-device measurements, not simulator values.

| Stage | Mean ms | Median ms | P95 ms | Min ms | Max ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| Preprocess | 44.107 | 44.311 | 46.135 | 35.695 | 46.833 |
| Core ML model | 25.534 | 22.932 | 27.337 | 16.691 | 142.428 |
| Postprocess/NMS/domain conversion | 7.899 | 8.025 | 8.943 | 6.148 | 9.399 |
| Provider total | 77.559 | 74.889 | 78.378 | 67.352 | 190.127 |

Compared with the prior physical provider baseline:

| Stage | Before mean ms | After mean ms | Improvement |
| --- | ---: | ---: | ---: |
| Preprocess | 56.477 | 44.107 | 1.280x faster |
| Model | 29.352 | 25.534 | 1.149x faster |
| Postprocess | 267.799 | 7.899 | 33.903x faster |
| Total | 353.649 | 77.559 | 4.560x faster |

The prior postprocess and total figures are the pre-optimization physical
provider baseline recorded for this review. The large postprocess improvement is
the intended result of the optimized V2B5 path.

### Sustained run and thermal

| Measure | Result |
| --- | ---: |
| First 10 pages median total | 73.477 ms |
| Last 10 pages median total | 76.720 ms |
| Drift | 4.413% |
| Thermal start / after benchmark / end | nominal / nominal / nominal |

### Domain smoke on the physical device

The provider test exercised the physical-device Reader domain, Guided Panel
layout, and actual OCR services over five val-only pages:

| Area | Result |
| --- | --- |
| Reader semantic/domain pages | 5, PASS |
| Guided Panel domain pages | 5, PASS |
| OCR pages / raw blocks | 5 / 715, PASS |
| OCR failures / invalid ROI | 0 / 0 |
| Balloon contour | `nil` |
| Mask-required consumer | None exercised |

These are real physical-device service/domain calls. They are not a substitute
for the requested UI-runner interaction smoke.

### Physical Manual UI Smoke

The required manual UI smoke was completed on the physical iPhone using the
already-installed Debug app from `/Users/zhengyunkai/Desktop/mreader`. No new
deployment was performed (`additional deployments: 0`). The session was started
with the existing diagnostic launch arguments:

```text
-mreader-ui-testing -mreader-v2b5-provider
```

The diagnostic selector maps `-mreader-v2b5-provider` to the V2B5 provider for
that process. No UserDefaults value or Release default was changed; the
production default remains `OLD`.

| Area | Evidence | Result |
| --- | --- | --- |
| Reader | Fixture Reader pages 1–5; open, forward/back navigation, scroll attempt, dismiss, and reopen | PASS; no visible freeze; no crash |
| Guided Panel | Real local comic pages 338–342; enter, next panel, previous panel, cross-page transition, exit/re-enter | PASS; no visible detection issue or UI freeze |
| OCR UI | Real local comic pages 336, 337, 338; three UI-triggered requests with visible result overlays | PASS; 3/3 results, 0 UI failures, 0 invalid ROI |
| Balloon compatibility | `contour = nil` through the exercised Reader/Guided Panel/OCR UI paths | PASS; no mask-dependent UI failure |
| Responsiveness | Manual interaction during the above flows | No visible main-thread stall; no crash |

The Reader UI path was exercised over five pages, including dismiss/reopen. The
Guided Panel UI path was exercised over five real pages and visibly changed the
camera crop when moving between panels. OCR results were shown in the Reader UI
on all three exercised pages. No user manga screenshots or recordings were added
to the repository.

### UI runner limitation

The first consolidated `xcodebuild test` invocation completed the V2B5 physical
unit/provider gate, but could not install `mreaderUITests-Runner` because the
device had reached the free developer-profile app limit. After one app was
removed, the second and final allowed invocation installed the runner, but the
runner exited with code `74` before establishing the XCTest connection:

```text
Early unexpected exit, operation never finished bootstrapping
```

The UI test method therefore did not execute and emitted no UI smoke JSON. This
is classified as a test-infrastructure limitation, not a product failure,
because the same physical UI paths were subsequently completed manually using
the installed Debug app.

| UI item | Result |
| --- | --- |
| Reader open / swipe / dismiss | Manually verified: PASS |
| Guided Panel UI transitions | Manually verified: PASS |
| OCR UI entry / mapping | Manually verified: PASS |

No further device deployment was attempted after the two allowed invocations.

The physical Provider, domain, and manual UI results complete the requested
physical UI gate. The XCTest runner limitation remains recorded for future test
infrastructure work and does not block this product review. This still does not
change the production default or authorize an automatic production switch.

## Decision

**A. `V2B5_READY_FOR_PRODUCTION_SWITCH`**

The simulator Phase A and the physical V2B5-only Provider Gate passed, including
40-page inference, output contract, memory sampling, thermal sampling, optimized
postprocess timing, Reader/Guided Panel/OCR domain calls, and balloon nil-contour
compatibility. The final manual physical UI smoke also passed for Reader,
Guided Panel, and OCR with no crash, visible freeze, invalid ROI, or
mask-dependent UI failure. The XCTest runner code 74 is retained as
`TEST_INFRASTRUCTURE_LIMITATION`. Production remains on the OLD provider.

## Next Allowed Step

Await explicit approval for the separate production-switch and sealed Final Test
step. Do not switch the production default, remove OLD, run Final Test, access test
images, or modify the formal mReader checkout as part of this completed review.
