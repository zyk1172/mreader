# Manga Vision V2B5 Production Manifest

Status: `PRODUCTION_FROZEN`

## Production identity

- Model status: `PRODUCTION_FROZEN`
- Production provider: V2B5 (`MangaVisionV2B5Provider`)
- Fallback provider: OLD (`YOLOMangaVisionProvider` / `PanelDetector`)
- Precision: Full FP32
- Production freeze commit: `e47e0177c3d2080f2fe89d0d927505da1b138108`
- Training HEAD: `84b1aacee50926b95837f043b10bd5cab58da217`
- Final Test commit: `6d6f9118d026287da1167d4cf2d187ca1b4c1435`

## Model

- Model: `MangaVisionDetectorV2B5`
- Artifact: `mreader/MangaVisionV2B5.mlpackage`
- Artifact tree SHA256: `ebde3f514e2fb84e48f73bd194041da671337f7b770e3baeae637ed8c5dba4c5`
- Hash method: `manga-vision-mlpackage-tree-v1`
- Artifact tree files: 4
- Artifact source bytes: 5,908,245
- Input: `1 × 3 × 640 × 640`
- Parameters: 1,390,954
- Classes: `frame`, `text`, `face`, `body`, `balloon`

## Frozen calibration

- Revision: `v2b5-calibration-v1`
- Calibration SHA256: `981693b9cac5a8e1be1e2f45d9042d5949d504a6c68c5514fabc4aa1a1c3056a`
- Score threshold: `0.05`
- Maximum detections: `300`
- NMS: frame `0.5`, text `0.55`, face `0.45`, body `0.55`, balloon `0.45`

## Production routing

- Release default: V2B5.
- OLD remains available for rollback through `YOLOMangaVisionProvider` / `PanelDetector`.
- DEBUG diagnostics remain `OLD`, `V2B5`, and `COMPARE`.
- No provider, decoder, model, calibration, threshold, or NMS change is part of this closeout.

## Final Test provenance and temporal state

- Dataset: `Manga109-s-v2026`
- Test books/pages: 9 / 991
- Test first accessed: `2026-09-18T21:12:35.219445+00:00`
- Pre-test manifest: `v2b5-sealed-test-manifest.md`, type `historical_snapshot`, `test_opened=false`, `test_inference_started=false`.
- Finalized machine-readable manifest: `v2b5-sealed-test-manifest.json`, `test_opened=true`, `test_inference_started=true`, status `COMPLETE`.
- Final Test metrics and completion source of truth: `v2b5-sealed-final-test.json`, cross-checked against `v2b5-sealed-final-test.md` and the finalized manifest.
- The pre-test snapshot proves the candidate was sealed before the one-time evaluation; it is not a post-test status override.
- Final Test split status: `OBSERVED`.
- This split must not be described as `SEALED`, `UNTOUCHED`, `UNSEEN`, or a new unbiased final test for V2B5.
- Further V2B5 tuning is prohibited. A future V3 influenced by this result needs a new unseen holdout.

## Final Test results

### Full

| Metric | Handoff JSON value |
|---|---:|
| Overall AP50 | 0.6782244626867042 |
| Recall | 0.7908991446310768 |
| Frame AP50 | 0.8349989744904774 |
| Text AP50 | 0.8979732750106517 |
| Face AP50 | 0.5267405485067185 |
| Body AP50 | 0.4370370710255367 |
| Balloon AP50 | 0.6943724444001369 |
| Small Text Recall | 0.921413813459268 |
| Small Face Recall | 0.6494562348220885 |
| Small Balloon Recall | 0.7994930291508239 |

### Halves

| Metric | Handoff JSON value |
|---|---:|
| Overall AP50 | 0.7370353503422589 |
| Recall | 0.8651302689924355 |
| Frame AP50 | 0.8543537986219041 |
| Text AP50 | 0.9154698256193994 |
| Face AP50 | 0.5886050841499622 |
| Body AP50 | 0.5149155928447241 |
| Balloon AP50 | 0.8118324504753045 |
| Small Text Recall | 0.9449035812672176 |
| Small Face Recall | 0.7537829658452226 |
| Small Balloon Recall | 0.8857266062958171 |

### Test counts

| View | Class | GT | Predictions |
|---|---|---:|---:|
| Full | frame | 9754 | 11307 |
| Full | text | 13777 | 21902 |
| Full | face | 10565 | 16074 |
| Full | body | 13888 | 35630 |
| Full | balloon | 10700 | 16340 |
| Halves | frame | 5272 | 7695 |
| Halves | text | 7535 | 16869 |
| Halves | face | 5734 | 13842 |
| Halves | body | 7560 | 31684 |
| Halves | balloon | 5796 | 12005 |

### Generalization

| Metric | Val Full | Test Full | Delta |
|---|---:|---:|---:|
| Overall AP50 | 0.6948779832527893 | 0.6782244626867042 | -0.016653520566085045 |
| Recall | 0.811031180709381 | 0.7908991446310768 | -0.02013203607830416 |
| Frame AP50 | 0.8977698457198735 | 0.8349989744904774 | -0.06277087122939606 |
| Text AP50 | 0.9120237722442343 | 0.8979732750106517 | -0.014050497233582537 |
| Face AP50 | 0.49925031964659405 | 0.5267405485067185 | 0.02749022886012442 |
| Body AP50 | 0.4508051845602917 | 0.4370370710255367 | -0.013768113534755044 |
| Balloon AP50 | 0.7145407940929528 | 0.6943724444001369 | -0.02016834969281589 |
| Small Text Recall | 0.9380718336483932 | 0.921413813459268 | -0.01665802018912521 |
| Small Face Recall | 0.6054226826848892 | 0.6494562348220885 | 0.04403355213719928 |
| Small Balloon Recall | 0.8288047115513318 | 0.7994930291508239 | -0.029311682400507966 |

| Metric | Val Halves | Test Halves | Delta |
|---|---:|---:|---:|
| Overall AP50 | 0.7288729339261761 | 0.7370353503422589 | 0.00816241641608273 |
| Recall | 0.8599168466691841 | 0.8651302689924355 | 0.005213422323251393 |
| Frame AP50 | 0.8994947975801204 | 0.8543537986219041 | -0.04514099895821633 |
| Text AP50 | 0.9275000309700616 | 0.9154698256193994 | -0.012030205350662238 |
| Face AP50 | 0.5213848485787692 | 0.5886050841499622 | 0.06722023557119294 |
| Body AP50 | 0.5012841652104951 | 0.5149155928447241 | 0.013631427634228976 |
| Balloon AP50 | 0.7947008272914342 | 0.8118324504753045 | 0.017131623183870293 |
| Small Text Recall | 0.9586484312148029 | 0.9449035812672176 | -0.013744849947585291 |
| Small Face Recall | 0.6658216178843052 | 0.7537829658452226 | 0.08796134796091748 |
| Small Balloon Recall | 0.8594415522953147 | 0.8857266062958171 | 0.026285054000502406 |

## Protocol

- Val preflight: **PASS**
- Train overlap: 0
- Val overlap: 0
- Checkpoint changed: **NO**
- Calibration changed: **NO**
- Evaluator changed: **NO**
- NMS sweep: **NO**
- Score sweep: **NO**
- Checkpoint comparison: **NO**
- Manual test-page selection: **NO**
- Manual test-image inspection: **NO**
- Model comparison on test: **NO**
- Test reruns: 0
- Decision: `A. SEALED_FINAL_TEST_COMPLETE — PRODUCTION CANDIDATE CHARACTERIZED`

## Closeout verification

- Handoff ZIP integrity: PASS; expected size 10,703 bytes and expected SHA256 matched.
- Handoff payload checksums: PASS; 6 of 6 payload entries verified.
- Targeted golden/provider/production-default tests: PASS; 18 passed, 0 skipped, 0 failed.
- `mreaderTests`: PASS; 594 passed, 11 skipped, 0 failed, 605 total.
- Key `mreaderUITests`: PASS; 5 passed, 0 skipped, 0 failed.
- Release build: PASS; `Release`, generic iOS destination.
- Release bundle: `MangaVisionV2B5.mlmodelc` and `PanelDetector.mlmodelc` both present.
- Production default: PASS; V2B5.
- OLD rollback availability: PASS.
- Final Test rerun during this closeout: NO.
- Physical benchmark, thermal benchmark, and manual physical UI rerun: NO; prior frozen evidence remains authoritative.

## Prediction archive metadata

- Path: `reports/final/artifacts/v2b5-test-predictions.json.gz`
- SHA256: `02f09135b7c9f6e5012423168e466d195293b6c9289859ad90f4656071ec8270`
- Size: 7272848 bytes
- The prediction archive itself is not copied into mReader.

## Future V3 research notes

These are future-work notes only and do not authorize V2B5 changes.

### Full-view Frame

- Val: 0.8977698457198735
- Test: 0.8349989744904774
- Delta: -0.06277087122939606

### Body duplicate/extras

| View | GT | Predictions | Duplicated GT | Duplicate ratio | Extras |
|---|---:|---:|---:|---:|---:|
| Full | 13888 | 35630 | 3466 | 0.3717288717288717 | 26306 |
| Halves | 7560 | 31684 | 2801 | 0.4705190660171342 | 25731 |

No new PASS threshold is introduced by this report.

## Attribution

- Required attribution: [`docs/licensing/mangasegmentation-attribution.md`](licensing/mangasegmentation-attribution.md)
- Raw MangaSegmentation annotations and Manga109-s images are not packaged as app resources.

## Mainline

- Production switch branch: `codex/v2b5-production-switch`
- Documentation commit: `a399ac5a2ab917f53c2ade6b78a920c4520bd093`
- Main merge commit: `8777456c08a6da050a133f633b74845dba6f496e`
