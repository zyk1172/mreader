# Manga Vision V2B5 Closeout

## Lifecycle

V1 → V2A → V2B → V2B5 5-class → Balloon transfer → frozen validation → Core ML FP32 → mixed precision review → Full FP32 selection → Python/Swift golden → Simulator → iPhone physical review → Production switch → Sealed Final Test → Mainline

## Final production identity

- Production: V2B5 (`MangaVisionV2B5Provider`)
- Fallback: OLD (`YOLOMangaVisionProvider` / `PanelDetector`)
- Precision: Full FP32
- Production freeze commit: `e47e0177c3d2080f2fe89d0d927505da1b138108`
- Core ML tree SHA256: `ebde3f514e2fb84e48f73bd194041da671337f7b770e3baeae637ed8c5dba4c5`
- Checkpoint SHA256: `cb8947236e62bcf0fb516cd777886fce96f7cea52a29414d1408d0666edaf63f`
- Calibration: `v2b5-calibration-v1`
- Calibration SHA256: `981693b9cac5a8e1be1e2f45d9042d5949d504a6c68c5514fabc4aa1a1c3056a`
- Training HEAD: `84b1aacee50926b95837f043b10bd5cab58da217`
- Final Test commit: `6d6f9118d026287da1167d4cf2d187ca1b4c1435`

## Final evaluation

- Dataset: `Manga109-s-v2026`
- Test pages/books: 991 / 9
- Final Test status: **COMPLETE**
- Test split: **OBSERVED**
- Test reruns: 0
- Full Overall AP50 / Recall: 0.6782244626867042 / 0.7908991446310768
- Halves Overall AP50 / Recall: 0.7370353503422589 / 0.8651302689924355
- Decision: `A. SEALED_FINAL_TEST_COMPLETE — PRODUCTION CANDIDATE CHARACTERIZED`
- Prediction archive metadata only: `reports/final/artifacts/v2b5-test-predictions.json.gz`, SHA256 `02f09135b7c9f6e5012423168e466d195293b6c9289859ad90f4656071ec8270`, 7272848 bytes.

The pre-test manifest remains a historical snapshot of the frozen-before-access state. `v2b5-sealed-test-manifest.json` is the finalized post-test lifecycle manifest, while `v2b5-sealed-final-test.json` is the source of truth for final metrics and completion evidence. The observed test split is not a new unbiased holdout for V2B5 or any V3 design influenced by it.

The pre-test snapshot intentionally records `test_opened=false` and `test_inference_started=false`; the finalized post-test state intentionally records `test_opened=true`, `test_inference_started=true`, and `status=COMPLETE`. These are temporal states, not conflicting evidence.

## Closeout verification

- Targeted golden/provider/production-default tests: 18 passed, 0 skipped, 0 failed.
- `mreaderTests`: 594 passed, 11 skipped, 0 failed, 605 total.
- Key `mreaderUITests`: 5 passed, 0 skipped, 0 failed.
- Release build: PASS; V2B5 and OLD compiled model resources are bundled.
- Final Test and physical performance evidence were not rerun.

## Closeout boundaries

- V2B5 model and calibration are frozen.
- Further V2B5 tuning is prohibited.
- The 991-page split is not used for further V2B5 tuning or as a future unbiased final test.
- Raw MangaSegmentation data, raw annotations, test images, checkpoint files, and prediction archives are not packaged in mReader.
- Attribution remains in `docs/licensing/mangasegmentation-attribution.md`.
- OLD and `PanelDetector` remain available for rollback.
- Documentation commit: `a399ac5a2ab917f53c2ade6b78a920c4520bd093`.
- Mainline merge commit: `8777456c08a6da050a133f633b74845dba6f496e`.

MANGA VISION V2B5 PRODUCTION COMPLETE
