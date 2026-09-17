# Manga Vision post-remediation regression findings

This follow-up validates the combined behavior of remediation PRs #75–#78 after they landed together on `main`.

## Confirmed integration regressions

### 1. Adaptive merge bypassed the revisioned calibration profile

PR #78 made `MangaVisionCalibrationProfile.bundled` the revisioned source of detector filtering and same-class deduplication. The base YOLO provider used it, but the adaptive full-page/tile composer introduced in PR #76 still carried its earlier hard-coded IoU/containment thresholds.

Impact: ordinary pages and adaptive long pages could deduplicate the same semantic class differently, while the manifest claimed one calibration revision.

Fix: `MangaVisionAnalysisComposer.merge` now delegates every region type to `MangaVisionCalibrationProfile.bundled`.

### 2. Regression inference budget disagreed with the adaptive planner

The adaptive planner permits one baseline pass plus at most six refinement tiles. PR #78 independently gated inference count at 4.0 passes/page, while its 24-case stability test exercised the base YOLO provider at one pass/case. The mismatch therefore stayed hidden.

Impact: a legitimate extreme long page could require up to seven bounded passes yet violate the nominal release policy once real adaptive inference counts were supplied.

Fix: the planner now owns `maximumInferencePassCount`; the release gate imports that hard limit. Metrics retain mean passes/page for reporting and additionally record the maximum observed single-page count so a cheap average cannot hide a page that exceeds the contract.

### 3. Service observability counted page analyses rather than adaptive model passes

`MangaVisionService` incremented its existing `inferenceCount` once when an uncached page analysis committed. That was accurate before adaptive inference, but after PR #76 one page can perform a baseline plus multiple tile passes.

Impact: production diagnostics could report one inference for an extreme long page that actually invoked the model seven times, hiding the cost that the PR #78 regression policy is intended to control.

Fix: the existing service analysis counter is preserved for compatibility, while `AdaptiveMangaVisionProvider` now records actual model-pass attempts and `MangaVisionPerformanceSnapshot` exposes them separately as `modelInferencePassCount`.

## Cross-PR regression coverage

`MangaVisionPostRemediationIntegrationTests` verifies:

- adaptive merging produces the same deduplication result as the revisioned calibration profile for geometries chosen to distinguish the old copied thresholds;
- the planner and release gate share one pass-budget contract;
- the maximum legal adaptive pass count is accepted;
- one pass above the planner budget is rejected;
- a low corpus average cannot hide a single over-budget page;
- a Service -> Adaptive long-page run reports one committed page analysis while exposing all seven actual model passes.

This follow-up does not change model weights, OCR recognition policy, translation behavior, reading order, tiling geometry, scheduler ordering, or the thermal/Low Power policy.
