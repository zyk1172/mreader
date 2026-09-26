# V2B5 iPhone Device Performance Review

日期：2026-09-18

结论先行：在真实 iPhone 16 Pro 上，冻结的 Full FP32 V2B5 可以正常 load 和 prediction。`.all` 配置的中位数为 **18.757 ms**、P95 为 **19.487 ms**，100 次 prediction 失败数为 0，thermal 前后均为 `nominal`。MP5 `.all` 的中位数为 18.953 ms，几乎没有性能收益，因此本轮保留 Full FP32 的 correctness 优先级。

## Device

| Field | Value |
| --- | --- |
| Marketing name | iPhone 16 Pro |
| Model identifier | `iPhone17,1` |
| iOS | 27.0 (24A437) |
| CPU | arm64e, 6 cores |
| Reality | physical device |
| Low Power Mode | `false` |
| Initial thermal | `nominal` |

## Candidate

- Model: `MangaVisionDetectorV2B5`, Full FP32
- Checkpoint SHA256: `cb8947236e62bcf0fb516cd777886fce96f7cea52a29414d1408d0666edaf63f`
- Artifact: `exports/coreml/diagnostic/MangaVisionV2B5_FP32.mlpackage`
- Artifact tree SHA256: `ebde3f514e2fb84e48f73bd194041da671337f7b770e3baeae637ed8c5dba4c5`
- Artifact size: 5,908,245 bytes
- Input: `1×3×640×640`, Float32, deterministic seed `109`
- Timing scope: `model.prediction(...)` only; preprocessing, decoding and postprocess are excluded.
- Each configuration used a fresh test process, 10 warmups and 100 measured predictions.

## Full FP32 Compute Units

| Configured compute units | Load ms | Mean ms | Median ms | P95 ms | P99 ms | Sampled max footprint | Sampled max delta | Thermal |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `.all` | 155.820 | 18.760 | **18.757** | **19.487** | 20.126 | 205.314 MB | 150.375 MB | nominal → nominal |
| `.cpuAndNeuralEngine` | 153.312 | 38.257 | 38.141 | 39.643 | 40.124 | 73.768 MB | 22.797 MB | nominal → nominal |
| `.cpuAndGPU` | 96.797 | 17.882 | 17.886 | 18.462 | 18.851 | 209.627 MB | 159.016 MB | nominal → nominal |
| `.cpuOnly` | 78.959 | 39.622 | 39.505 | 41.010 | 41.762 | 65.689 MB | 14.688 MB | nominal → nominal |

`.cpuAndGPU` was slightly faster in this run than `.all`; these are configured allowed compute-unit sets, not proof of actual op placement. No ANE percentage is claimed.

## Variant Reference

All references below use `.all` and the same deterministic model-only input.

| Model | Size | Tree SHA256 | Load ms | Median ms | P95 ms | Sampled max footprint | Prediction failures |
| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: |
| Full FP32 | 5,908,245 B | `ebde3f51…` | 155.820 | **18.757** | **19.487** | 205.314 MB | 0 |
| MP5 P3 prefix FP32 | 4,098,956 B | `66d74830…` | 399.901 | 18.953 | 20.687 | 204.143 MB | 0 |
| FP16 baseline | 3,165,210 B | `4f8722d2…` | 683.394 | 3.282 | 3.403 | 101.018 MB | 0 |
| Old production PanelDetector | 21,061,392 B bundled resource | `45ba82ce…` | 1,110.940 | 4.707 | 4.846 | 108.814 MB | 0 |

The old PanelDetector is a latency/memory reference only. Its input is a 640×640 image pixel buffer and its outputs are `[1,300,38]` plus `[1,32,160,160]`; this is not a V2B5 output-contract comparison.

## Output Contract and Stability

Every V2B5 run validated 12 outputs:

- P2/P3/P4/P5 classification logits: 5 channels
- P2/P3/P4/P5 bbox: 4 channels
- P2/P3/P4/P5 centerness: 1 channel

The spatial shapes were P2 `160×160`, P3 `80×80`, P4 `40×40`, and P5 `20×20`. All seven selected physical-device benchmark tests passed, with zero prediction failures.

Application-side sampled physical footprint had a warmup allocation and then remained stable across the 100 measured predictions. This is not an Instruments instantaneous peak measurement.

## Sustained Short Run

Full FP32 `.all`:

- First 20 median: 18.803 ms
- Last 20 median: 18.628 ms
- Drift: −0.932%
- Thermal: `nominal` → `nominal`

## Correctness Scope

This report measures device load, model prediction latency, output-shape stability, sampled application footprint and thermal state. It does not rerun detection correctness.

The prior frozen correctness evidence remains: Full FP32 Core ML matched PyTorch on all 4,666 detections across the 40 val-only pages, with 100% class agreement, mean IoU 0.999999 and minimum IoU 0.999994.

## Test Split

- Manga109-s test images accessed: **NO**
- Test inference: **NO**
- Validation images accessed in this round: **NO**

## Recommendation

**A. FULL_FP32_DEVICE_ACCEPTABLE — READY FOR MREADER INTEGRATION**

This only clears the performance Gate. No mReader detector provider, PanelDetector resource, provider selection, UI flow or product default was changed in this round. The next authorized step is a separate mReader A/B integration review; this benchmark round is complete.
