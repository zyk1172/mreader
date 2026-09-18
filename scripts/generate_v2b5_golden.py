#!/usr/bin/env python3
"""Generate the tracked Python -> Swift V2B5 golden fixture.

This script is deliberately an inference-only bridge to the already frozen
training repository. It validates the checkpoint hash, loads the official
calibration and decoder, and writes JSON fixtures into this mReader checkout.
It never trains, exports, edits the training repository, or reads a test page.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

import torch
from PIL import Image


EXPECTED_CHECKPOINT_SHA256 = "cb8947236e62bcf0fb516cd777886fce96f7cea52a29414d1408d0666edaf63f"
EXPECTED_CLASSES = ["frame", "text", "face", "body", "balloon"]
EXPECTED_CALIBRATION_REVISION = "v2b5-calibration-v1"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def source_normalized_box(box: list[float], transformed: dict[str, object]) -> list[float]:
    scale = float(transformed["scale"])
    pad_left, pad_top = [float(value) for value in transformed["padding_xy"]]  # type: ignore[arg-type]
    width = float(transformed["original_width"])
    height = float(transformed["original_height"])
    x0, y0, x1, y1 = box
    result = [
        (x0 - pad_left) / max(width * scale, 1.0),
        (y0 - pad_top) / max(height * scale, 1.0),
        (x1 - pad_left) / max(width * scale, 1.0),
        (y1 - pad_top) / max(height * scale, 1.0),
    ]
    return [min(max(value, 0.0), 1.0) for value in result]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--training-repo",
        type=Path,
        default=Path("/Users/zhengyunkai/Documents/开发项目/正式项目/工具/manga-vision-training"),
    )
    parser.add_argument(
        "--sample-root",
        type=Path,
        default=Path("mreaderTests/V2B5ValSamples"),
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("mreaderTests/Fixtures/v2b5_golden"),
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    training_repo = args.training_repo.resolve()
    sample_root = args.sample_root.resolve()
    output_dir = args.output_dir.resolve()
    sys.path.insert(0, str(training_repo))
    sys.path.insert(0, str(training_repo / "src"))

    from manga_vision.calibration import load_calibration  # noqa: E402
    from manga_vision.detector import MangaVisionDetectorV2B5, decode_predictions  # noqa: E402
    from manga_vision.transforms import letterbox_image_target  # noqa: E402
    from scripts.verify_v2b5_export import (  # noqa: E402
        EXPECTED_PARAMETER_COUNT,
        INPUT_SHAPE,
        RawOutputWrapper,
        decode_with_frozen_calibration,
        file_sha256,
        strict_load_frozen_model,
        tuple_to_semantic,
    )

    checkpoint = training_repo / "checkpoints/coreml-smoke/v2b5-final-best.pt"
    actual_checkpoint_sha = file_sha256(checkpoint)
    if actual_checkpoint_sha != EXPECTED_CHECKPOINT_SHA256:
        raise SystemExit(
            f"checkpoint SHA mismatch: {actual_checkpoint_sha} != {EXPECTED_CHECKPOINT_SHA256}"
        )

    calibration_path = training_repo / "configs/manga109s_v2b5_calibration.yaml"
    calibration = load_calibration(calibration_path)
    if calibration["revision"] != EXPECTED_CALIBRATION_REVISION:
        raise SystemExit(f"calibration revision mismatch: {calibration['revision']}")

    sample_manifest = json.loads((sample_root / "manifest.json").read_text(encoding="utf-8"))
    if sample_manifest.get("split") != "val" or sample_manifest.get("model_predictions_used") is not False:
        raise SystemExit("sample package is not an audited val-only, prediction-free manifest")
    if sample_manifest.get("classes") != EXPECTED_CLASSES or sample_manifest.get("page_count") != 40:
        raise SystemExit("sample manifest does not match the frozen 40-page five-class package")

    # Reuse the official strict loader. The manifest is the frozen handoff
    # manifest in the training repo; this call only reads it and the checkpoint.
    frozen_manifest = json.loads(
        (training_repo / "reports/training/v2b5-final-candidate.json").read_text(encoding="utf-8")
    )
    model = MangaVisionDetectorV2B5()
    model, checkpoint_metadata, strict_load = strict_load_frozen_model(checkpoint, frozen_manifest)
    if strict_load["parameters"] != EXPECTED_PARAMETER_COUNT:
        raise SystemExit("unexpected parameter count")
    wrapper = RawOutputWrapper(model).eval()

    selected = next(
        page for page in sample_manifest["pages"]
        if page["book"] == "Donburakokko" and int(page["page_id"]) == 70
    )
    image_path = sample_root / f"{selected['book']}__{int(selected['page_id']):03d}.jpg"
    if not image_path.is_file():
        raise SystemExit(f"selected val-only image is missing: {image_path}")
    image_sha = sha256_file(image_path)
    if image_sha != selected["sha256"]:
        raise SystemExit(f"sample image SHA mismatch: {image_sha} != {selected['sha256']}")

    with Image.open(image_path) as image_source:
        image = image_source.convert("RGB")
        tensor, transformed = letterbox_image_target(
            image,
            {"boxes": torch.empty((0, 4), dtype=torch.float32)},
            INPUT_SHAPE[-1],
        )
    canonical = tensor.unsqueeze(0).contiguous()
    input_sha256 = hashlib.sha256(
        canonical[0].detach().cpu().numpy().tobytes(order="C")
    ).hexdigest()
    input_samples = {
        f"{x},{y}": [float(canonical[0, channel, y, x]) for channel in range(3)]
        for x, y in ((0, 0), (10, 10), (320, 320), (639, 639), (100, 500), (500, 100))
    }
    with torch.inference_mode():
        raw = tuple_to_semantic(wrapper(canonical))
        decoded = decode_with_frozen_calibration(raw, calibration)[0]

    expected_detections = []
    for box, score, label in zip(decoded["boxes"], decoded["scores"], decoded["labels"]):
        class_id = int(label)
        expected_detections.append({
            "class_id": class_id,
            "class": EXPECTED_CLASSES[class_id],
            "score": float(score),
            "bbox": source_normalized_box([float(value) for value in box], transformed),
        })

    output_dir.mkdir(parents=True, exist_ok=True)
    real_fixture = {
        "format": "mreader-v2b5-python-swift-golden-v1",
        "backend": "PyTorch frozen V2B5",
        "checkpoint_sha256": actual_checkpoint_sha,
        "epoch": 10,
        "parameters": EXPECTED_PARAMETER_COUNT,
        "calibration_revision": EXPECTED_CALIBRATION_REVISION,
        "classes": EXPECTED_CLASSES,
        "input_shape": list(INPUT_SHAPE),
        "source_dataset": sample_manifest["source_dataset"],
        "split": "val",
        "page": {
            "book": selected["book"],
            "page_id": int(selected["page_id"]),
            "filename": selected["filename"],
            "bundled_resource": image_path.name,
            "sha256": image_sha,
            "width": int(selected["width"]),
            "height": int(selected["height"]),
        },
        "letterbox": {
            "scale": float(transformed["scale"]),
            "padding_xy": [int(value) for value in transformed["padding_xy"]],
        },
        "input_sha256": input_sha256,
        "input_samples": input_samples,
        "checkpoint_metadata": checkpoint_metadata,
        "strict_load": strict_load,
        "detections": expected_detections,
    }
    (output_dir / "v2b5_real_val.json").write_text(
        json.dumps(real_fixture, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    synthetic_fixture = {
        "format": "mreader-v2b5-python-swift-golden-v1",
        "kind": "synthetic-contract",
        "input_seed": 109,
        "input_shape": list(INPUT_SHAPE),
        "classes": EXPECTED_CLASSES,
        "calibration_revision": EXPECTED_CALIBRATION_REVISION,
        "score_threshold": float(calibration["score_threshold"]),
        "max_detections": int(calibration["max_detections"]),
        "nms_iou_by_class": calibration["nms_iou_by_class"],
        "raw_output_contract": [
            {
                "tensor": f"p{level}_{role}",
                "shape": [1, channels, size, size],
                "semantic": semantic,
            }
            for level, size in ((2, 160), (3, 80), (4, 40), (5, 20))
            for role, channels, semantic in (
                ("cls", 5, "classification logits"),
                ("bbox", 4, "bbox regression"),
                ("centerness", 1, "centerness logits"),
            )
        ],
        "swift_assertion": "class index 4 remains balloon and bbox decoder uses the shared frozen calibration",
    }
    (output_dir / "v2b5_synthetic.json").write_text(
        json.dumps(synthetic_fixture, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(json.dumps({
        "status": "PASS",
        "output_dir": str(output_dir),
        "real_fixture": str(output_dir / "v2b5_real_val.json"),
        "synthetic_fixture": str(output_dir / "v2b5_synthetic.json"),
        "detections": len(expected_detections),
        "checkpoint_sha256": actual_checkpoint_sha,
        "test_images_accessed": False,
        "test_inference": False,
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
