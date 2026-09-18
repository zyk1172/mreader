# Manga Vision V2B5 Production Manifest

Status: frozen production candidate

## Model

- Model: `MangaVisionDetectorV2B5`
- Precision: Full FP32
- Artifact: `mreader/MangaVisionV2B5.mlpackage`
- Artifact tree SHA256: `ebde3f514e2fb84e48f73bd194041da671337f7b770e3baeae637ed8c5dba4c5`
- Artifact tree files: 4
- Artifact source bytes: 5,908,245
- Input: `1 × 3 × 640 × 640`
- Parameters: 1,390,954
- Classes: `frame`, `text`, `face`, `body`, `balloon`
- Class IDs: `0`, `1`, `2`, `3`, `4`

## Frozen calibration

- Revision: `v2b5-calibration-v1`
- Score threshold: `0.05`
- Maximum detections: `300`
- NMS: frame `0.50`, text `0.55`, face `0.45`, body `0.55`, balloon `0.45`

## Production routing

- Release production provider: V2B5 (`MangaVisionV2B5Provider`)
- Fallback provider: OLD (`YOLOMangaVisionProvider` / `PanelDetector`)
- DEBUG diagnostics: OLD, V2B5, and COMPARE remain available.
- Release default is selected by `MangaVisionProviderMode.productionDefault` and is asserted as V2B5 by the production regression test.
- OLD model resource and provider implementation remain in the app for rollback.

## Capability boundary

- Frame: supported
- Text: supported
- Face: supported
- Body: supported
- Balloon bounding box: supported
- Balloon mask/contour: unsupported; contour remains `nil`
- No exercised Reader, Guided Panel, or OCR consumer requires an exact balloon mask.

## Output contract

The production artifact exposes 12 named raw tensors across P2/P3/P4/P5. Each level has classification, bbox, and centerness outputs; classification has 5 channels, bbox has 4 channels, and centerness has 1 channel. Class ID 4 is balloon.

## Verification record

- Validated integration/review source: `origin/codex/v2b5-production-review` at `c9e1ee9`
- Physical production review decision: PASS
- Release App build: PASS (without testability override)
- Release-config build-for-testing: PASS; `ENABLE_TESTABILITY=YES` was used only for XCTest compilation because the test target uses `@testable import`.
- Unit tests: PASS; 598 passed, 11 skipped, 0 failed in the Release-config simulator run.
- Functional UI tests: PASS; 5 passed, 1 opt-in physical gate skipped.
- Production default provider test: PASS
- OLD rollback availability test: PASS
- Core ML resources in Release app: both `PanelDetector.mlmodelc` and `MangaVisionV2B5.mlmodelc` present.

The separate Xcode launch-screenshot test was not used as a production decision gate because Xcode 27's no-argument `testLaunch` remained in runner launch wait; the V2B5 functional UI class and production-default unit assertion passed.

## Attribution

MangaSegmentation attribution is recorded at [`docs/licensing/mangasegmentation-attribution.md`](licensing/mangasegmentation-attribution.md). The app does not package MangaSeg raw annotations or the raw dataset.

## Size record

- Existing OLD compiled model resource: 21,061,392 bytes
- V2B5 compiled model resource: 5,771,747 bytes
- Release app bundle after switch: 100,605,443 bytes
- OLD remains present; the measured model-resource increase from adding V2B5 is 5,771,747 bytes.

## Sealed-test boundary

- Validation: PASS
- Physical review: PASS
- Final test: NOT RUN
- Test split accessed: NO
- Test inference: NO
