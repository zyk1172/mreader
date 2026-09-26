# Manga Vision V2B5 Final Evaluation

## Production Identity

- mReader production freeze commit: `e47e0177c3d2080f2fe89d0d927505da1b138108`
- Model: `MangaVisionDetectorV2B5`
- Core ML artifact tree SHA256: `ebde3f514e2fb84e48f73bd194041da671337f7b770e3baeae637ed8c5dba4c5`
- Checkpoint SHA256: `cb8947236e62bcf0fb516cd777886fce96f7cea52a29414d1408d0666edaf63f`
- Calibration: `v2b5-calibration-v1`
- Calibration SHA256: `981693b9cac5a8e1be1e2f45d9042d5949d504a6c68c5514fabc4aa1a1c3056a`
- Training HEAD: `84b1aacee50926b95837f043b10bd5cab58da217`
- Final Test commit: `6d6f9118d026287da1167d4cf2d187ca1b4c1435`
- Production provider: V2B5 (`MangaVisionV2B5Provider`)
- Fallback: OLD (`YOLOMangaVisionProvider` / `PanelDetector`)
- Precision: Full FP32

## Protocol

- Dataset: `Manga109-s-v2026`
- Test books: 9
- Test pages: 991
- Train overlap: 0
- Val overlap: 0
- Val preflight: **PASS**
- Test reruns: 0
- Checkpoint changed: **NO**
- Calibration changed: **NO**
- Evaluator changed: **NO**
- NMS sweep: **NO**
- Score sweep: **NO**
- Checkpoint comparison: **NO**
- Manual test-page selection: **NO**
- Manual test-image inspection: **NO**
- Final Test status: **COMPLETE**
- Test split status: **OBSERVED**

The pre-test manifest is retained as a historical snapshot proving the candidate was frozen before the one-time final evaluation. The finalized JSON records the post-test state. The split is now observed and must not be called sealed, untouched, unseen, or unbiased for future V2B5 work.

## Manifest timing

The two manifest states are intentional evidence from different points in the one-time evaluation:

| State | Source | Type/status | `test_opened` | `test_inference_started` |
|---|---|---|---:|---:|
| Pre-test | `v2b5-sealed-test-manifest.md` | `historical_snapshot` | false | false |
| Finalized post-test | `v2b5-sealed-test-manifest.json` | `COMPLETE` | true | true |

The pre-test snapshot proves the candidate was sealed before test access. The finalized manifest records the post-test lifecycle state, while `v2b5-sealed-final-test.json` is the source of truth for final metrics and completion evidence. These documents are not expected to equal each other on temporal fields, and the difference is not a protocol violation.

## Full Results

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

### Full counts

| Class | GT | Predictions |
|---|---:|---:|
| frame | 9754 | 11307 |
| text | 13777 | 21902 |
| face | 10565 | 16074 |
| body | 13888 | 35630 |
| balloon | 10700 | 16340 |

## Halves Results

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

### Halves counts

| Class | GT | Predictions |
|---|---:|---:|
| frame | 5272 | 7695 |
| text | 7535 | 16869 |
| face | 5734 | 13842 |
| body | 7560 | 31684 |
| balloon | 5796 | 12005 |

## Generalization

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

## Interpretation

- Full Overall AP50: `0.6782244626867042`; six-decimal summary: **0.678224**.
- Full Recall: `0.7908991446310768`; six-decimal summary: **0.790899**.
- Full relative to frozen validation: AP50 **-0.016654**, Recall **-0.020132**.
- Halves Overall AP50: `0.7370353503422589`; six-decimal summary: **0.737035**.
- Halves Recall: `0.8651302689924355`; six-decimal summary: **0.865130**.
- Halves relative to frozen validation: AP50 **+0.008162**, Recall **+0.005213**.
- These results characterize the frozen production candidate. They do not create a new PASS threshold and do not authorize further V2B5 tuning.

## Prediction Evidence

- Path: `reports/final/artifacts/v2b5-test-predictions.json.gz`
- SHA256: `02f09135b7c9f6e5012423168e466d195293b6c9289859ad90f4656071ec8270`
- Size: 7272848 bytes
- Only this metadata is archived in mReader; the prediction archive is not copied.

## Future V3 Research Notes

These notes are future work only. They do not change V2B5.

### Full-view Frame

- Val: 0.8977698457198735
- Test: 0.8349989744904774
- Delta: -0.06277087122939606

### Body duplicate/extras

| View | GT | Predictions | Duplicated GT | Duplicate ratio | Extras |
|---|---:|---:|---:|---:|---:|
| Full | 13888 | 35630 | 3466 | 0.3717288717288717 | 26306 |
| Halves | 7560 | 31684 | 2801 | 0.4705190660171342 | 25731 |

For V3, any design influenced by this observed split requires a new unseen holdout.

## Decision

A. SEALED_FINAL_TEST_COMPLETE — PRODUCTION CANDIDATE CHARACTERIZED

## Closeout verification

- Handoff payload: 6/6 checksums verified.
- Targeted golden/provider/production-default tests: 18 passed, 0 skipped, 0 failed.
- `mreaderTests`: 594 passed, 11 skipped, 0 failed, 605 total.
- Key `mreaderUITests`: 5 passed, 0 skipped, 0 failed.
- Release build: PASS; V2B5 and OLD compiled model resources both bundled.
- Final Test, test-image inspection, and physical benchmark reruns: not performed.
