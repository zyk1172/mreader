# V4 Primary3 candidate / physical-device validation

This branch is a **test harness**, not a production model switch.

It exists because raw `MLModel.prediction` timing alone is insufficient for
the V4 training experiment. A candidate can have acceptable raw inference
latency while regressing in preprocessing, decoder/NMS cost, coordinate
restoration, or the business-level output consumed by Guided Panel/OCR.

## What changed

`V2B5DevicePerformanceTests` now contains an end-to-end physical-device case
that runs the real:

```
CGImage
  -> MangaVisionV2B5Preprocessor
  -> Core ML
  -> raw output contract
  -> MangaVisionV2B5Decoder / class-aware NMS
  -> MangaPageAnalysis
```

It uses two checked-in manga fixtures and records preprocessing latency, Core
ML latency, postprocess/decode latency, total page latency, cold model load,
physical footprint, thermal state, five per-class detection counts,
repeated-count determinism, and runtime load count.

The `mreaderDeviceBench` scheme now explicitly enables the benchmark
environment. Normal `mreader` simulator CI remains unchanged; the physical
test skips there.

## Candidate validation command

```bash
bash scripts/run_v4_primary3_candidate_validation.sh \
  /absolute/path/to/MangaVisionPrimary3V4.mlpackage \
  <physical-device-id>
```

Get a device ID with:

```bash
xcrun xctrace list devices
```

The script temporarily stages the candidate at the existing
`MangaVisionV2B5.mlpackage` resource path so the exact existing Swift output
contract is exercised. It always restores the original package with a shell
trap and does not commit model bytes.

Before device execution it runs `MangaVisionRegressionGateTests` in the
simulator. This catches input/output tensor incompatibility and the existing
24-case scale-stability contract before signing/installing on a phone.

## What this does not prove

The physical-device benchmark is a runtime/correctness-contract test, not an
accuracy benchmark. Stable counts do not mean the boxes are correct.

A candidate is not eligible for a production switch until all of these are
separately true:

1. Primary3 offline metrics pass the frame/text/balloon candidate gate.
2. Python and Swift decoding are compared on the **same candidate** and fixed
   non-test pages (box IoU and score tolerance), rather than reusing the old
   V2B5 golden as if it were candidate ground truth.
3. Simulator regression/contract tests pass with the candidate staged.
4. Physical-device end-to-end timing, memory and thermal drift are acceptable.
5. Guided Panel and OCR ROI smoke tests run against representative real pages.

## Why the old golden cannot be reused as candidate truth

`mreaderTests/Fixtures/v2b5_golden` verifies the frozen V2B5 artifact. A new
V4 checkpoint is expected to change detections. Comparing V4 to those
detections as an accuracy gate would punish legitimate improvements. Generate
a new Python golden from the exact V4 checkpoint/export and use it only for
Python-vs-Swift equivalence.

## GitHub limitation

The repository's hosted iOS CI uses simulators. It has no attached physical
iPhone, so a GitHub-hosted run cannot honestly be reported as a physical-device
test. The device stage above must run on a Mac with the target iPhone connected
(or on a future self-hosted macOS runner with that device attached).
