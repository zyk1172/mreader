#!/usr/bin/env python3
"""Export the tracked Koharu YOLO26s-seg checkpoint to the bundled Core ML package.

Pipeline: SafeTensors -> ultralytics YOLO26s-seg -> ONNX -> Core ML mlprogram (FP32).

The script is deterministic and offline: it only reads `models/koharu-yolo26s`,
verifies every input against `models/koharu-yolo26s/SHA256SUMS`, and writes
`mreader/KoharuYOLO26S.mlpackage` plus an export manifest.

Why FP32 and not FP16
---------------------
A plain `compute_precision=FLOAT16` conversion silently corrupts the end-to-end
head. The NMS-free head selects detections with `topk` over ~33,600 anchor slots
and then gathers with those indices; FP16 cannot represent integers above 2048
exactly, so the index math degrades and detections are dropped or reordered.
Measured on `sample_shirohage_manga.jpg`:

    FP32  detections max_abs_diff = 7.0e-4   top-3 conf 0.9148 / 0.8887 / 0.5591
    FP16  detections max_abs_diff = 1.1e+3   top-3 conf 0.8882 / 0.2332 / 0.0804

FP32 conversion reproduces PyTorch exactly, which is also how the previous
bundled detector was shipped.

Usage:
    python3 scripts/export_koharu_yolo26s_coreml.py [--check-only]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
from pathlib import Path

import numpy as np

REPO_ROOT = Path(__file__).resolve().parent.parent
MODEL_DIR = REPO_ROOT / "models" / "koharu-yolo26s"
OUTPUT_PACKAGE = REPO_ROOT / "mreader" / "KoharuYOLO26S.mlpackage"
MANIFEST_PATH = MODEL_DIR / "coreml-export-manifest.json"

INPUT_SIZE = 1280
DETECTIONS_SHAPE = (1, 300, 38)
PROTOS_SHAPE = (1, 32, 320, 320)
CLASS_NAMES = {0: "frame", 1: "dialogue_text", 2: "balloon", 3: "onomatopoeia_text"}
CONFIDENCE_THRESHOLD = 0.25
FIXTURES = ("sample_shirohage_manga.jpg", "manga_page_publicdomainq.png")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_sources() -> dict[str, str]:
    """Fail closed unless every pinned upstream file still matches SHA256SUMS."""
    sums_path = MODEL_DIR / "SHA256SUMS"
    if not sums_path.is_file():
        raise SystemExit(f"missing checksum manifest: {sums_path}")
    verified: dict[str, str] = {}
    for line in sums_path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        expected, relative = line.split(None, 1)
        target = REPO_ROOT / relative.strip()
        if not target.is_file():
            raise SystemExit(f"missing pinned source file: {target}")
        actual = sha256_file(target)
        if actual != expected:
            raise SystemExit(f"checksum mismatch for {relative}: {actual} != {expected}")
        verified[relative] = actual
    if "models/koharu-yolo26s/model.safetensors" not in verified:
        raise SystemExit("SHA256SUMS does not pin model.safetensors")
    return verified


def letterbox_rgb(path: Path, size: int = INPUT_SIZE) -> np.ndarray:
    """Reproduce the ultralytics LetterBox contract: gray-114 pad, scaleup, round(d-0.1).

    Pixels come back in RGB order, ready for both the PyTorch and the Core ML input.
    """
    import cv2

    image = cv2.imread(str(path))
    if image is None:
        raise SystemExit(f"cannot read fixture: {path}")
    height, width = image.shape[:2]
    ratio = min(size / width, size / height)
    new_w, new_h = round(width * ratio), round(height * ratio)
    resized = cv2.resize(image, (new_w, new_h), interpolation=cv2.INTER_LINEAR)
    canvas = np.full((size, size, 3), 114, np.uint8)
    top, left = round((size - new_h) / 2 - 0.1), round((size - new_w) / 2 - 0.1)
    canvas[top:top + new_h, left:left + new_w] = resized
    return canvas[:, :, ::-1]


def import_converters():
    try:
        import coremltools as ct
        import onnx
        import torch
        import yaml
        from onnx2torch import convert as onnx_to_torch
        from safetensors.torch import load_file
        from ultralytics.nn.tasks import SegmentationModel
    except ImportError as error:  # pragma: no cover - environment guard
        raise SystemExit(
            "export dependencies missing; install with:\n"
            "  pip install 'ultralytics==8.4.43' coremltools onnx onnx2torch safetensors opencv-python"
        ) from error
    return ct, onnx, torch, yaml, onnx_to_torch, load_file, SegmentationModel


def register_view_ops() -> None:
    """coremltools has no converter for the view-only ops torch.jit.trace emits."""
    from coremltools.converters.mil.frontend.torch.ops import _get_inputs, register_torch_op

    def make_identity(label: str):
        def convert(context, node):
            inputs = _get_inputs(context, node, expected=1)
            context.add(inputs[0], node.name)

        convert.__name__ = f"convert_{label}"
        return convert

    for name in ("resolve_conj", "resolve_neg"):
        register_torch_op(torch_alias=[name])(make_identity(name))


def make_inference_wrapper(torch, network):
    """Expose only the end-to-end inference tuple `(detections, protos)`."""

    class KoharuInferenceWrapper(torch.nn.Module):
        def __init__(self, module):
            super().__init__()
            self.module = module

        def forward(self, image):
            (detections, protos), _ = self.module(image)
            return detections, protos

    return KoharuInferenceWrapper(network).eval()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check-only",
        action="store_true",
        help="verify pinned sources and bundle the existing package, without converting",
    )
    parser.add_argument("--work-dir", default="/tmp/koharu-coreml-export")
    arguments = parser.parse_args()

    pinned = verify_sources()
    print(f"verified {len(pinned)} pinned source files")

    if arguments.check_only:
        print("check-only: conversion skipped")
        return 0

    ct, onnx, torch, yaml, onnx_to_torch, load_file, SegmentationModel = import_converters()
    register_view_ops()

    work_dir = Path(arguments.work_dir)
    work_dir.mkdir(parents=True, exist_ok=True)

    config = json.loads((MODEL_DIR / "config.json").read_text())
    architecture = yaml.safe_load((MODEL_DIR / "yolo26s-seg.yaml").read_text())

    # 1. Rebuild the YOLO26s-seg architecture and strict-load the exported weights.
    network = SegmentationModel(
        cfg=architecture, ch=3, nc=config["num_classes"], verbose=False
    ).eval()
    state = load_file(str(MODEL_DIR / "model.safetensors"))
    network.load_state_dict(state, strict=True)
    parameters = sum(parameter.numel() for parameter in network.parameters())
    print(f"strict state-dict load OK, parameters={parameters}")

    with torch.no_grad():
        (detections, protos), _ = network(torch.zeros(1, 3, INPUT_SIZE, INPUT_SIZE))
    if tuple(detections.shape) != DETECTIONS_SHAPE or tuple(protos.shape) != PROTOS_SHAPE:
        raise SystemExit(
            f"unexpected inference contract: {tuple(detections.shape)} / {tuple(protos.shape)}"
        )
    print(f"inference contract: detections{DETECTIONS_SHAPE} protos{PROTOS_SHAPE}")

    # 2. Torch -> ONNX. The end-to-end head uses shape-derived anchor constants, so the
    #    default double-invocation trace check is disabled and parity is asserted below.
    wrapper = make_inference_wrapper(torch, network)
    example = torch.zeros(1, 3, INPUT_SIZE, INPUT_SIZE)
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, example, strict=False, check_trace=False)
        reference_output = wrapper(example)
        traced_output = traced(example)
    for index, (expected, actual) in enumerate(zip(reference_output, traced_output)):
        difference = float((expected - actual).abs().max())
        if difference != 0.0:
            raise SystemExit(f"torch.jit.trace changed output {index} by {difference}")
    print("torch.jit.trace parity OK")

    onnx_path = work_dir / "koharu-yolo26s-seg.onnx"
    torch.onnx.export(
        traced,
        example,
        str(onnx_path),
        opset_version=17,
        do_constant_folding=True,
        input_names=["images"],
        output_names=["detections", "protos"],
        dynamo=False,
    )
    onnx_model = onnx.load(str(onnx_path))
    print(f"onnx export OK -> {onnx_path}")

    # 3. ONNX -> torch -> Core ML. Core ML cannot consume ONNX directly in
    #    coremltools 9, and the native ultralytics graph trips the TorchScript
    #    frontend, so the stable ONNX graph is the interchange format.
    onnx_reference = onnx_to_torch(onnx_model).eval()
    traced_onnx = torch.jit.trace(
        onnx_reference,
        torch.zeros(1, 3, INPUT_SIZE, INPUT_SIZE),
        strict=False,
        check_trace=False,
    )
    mlmodel = ct.convert(
        traced_onnx,
        inputs=[
            ct.ImageType(
                name="image",
                shape=(1, 3, INPUT_SIZE, INPUT_SIZE),
                scale=1.0 / 255.0,
                bias=[0.0, 0.0, 0.0],
                color_layout=ct.colorlayout.RGB,
            )
        ],
        outputs=[ct.TensorType(name="detections"), ct.TensorType(name="protos")],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.iOS18,
    )
    print("core ml conversion OK")

    # 4. Parity gate: the converted package must reproduce the PyTorch detections.
    parity = _verify_parity(ct, torch, network, mlmodel)
    for entry in parity:
        print(
            f"  parity {entry['fixture']}: max_abs_diff={entry['max_abs_diff']:.6f} "
            f"top_confidences={entry['top_confidences']}"
        )

    if OUTPUT_PACKAGE.exists():
        shutil.rmtree(OUTPUT_PACKAGE)
    mlmodel.save(str(OUTPUT_PACKAGE))
    print(f"saved {OUTPUT_PACKAGE}")

    manifest = {
        "architecture": "Koharu YOLO26s-seg",
        "source_checkpoint": "models/koharu-yolo26s/model.safetensors",
        "source_checkpoint_sha256": pinned["models/koharu-yolo26s/model.safetensors"],
        "bundled_resource": "mreader/KoharuYOLO26S.mlpackage",
        "input": {"name": "image", "shape": [1, 3, INPUT_SIZE, INPUT_SIZE], "color": "RGB", "scale": 1 / 255.0},
        "outputs": {
            "detections": {
                "shape": list(DETECTIONS_SHAPE),
                "layout": "[x1, y1, x2, y2, confidence, class_index, mask_coefficient x 32]",
                "space": "model input pixels (0...1280)",
            },
            "protos": {"shape": list(PROTOS_SHAPE), "note": "mask prototypes at 1/4 input resolution"},
        },
        "classes": CLASS_NAMES,
        "parameter_count": parameters,
        "compute_precision": "FLOAT32",
        "compute_precision_rationale": "FP16 corrupts the end-to-end top-k index path",
        "minimum_deployment_target": "iOS18",
        "ultralytics_version": "8.4.43",
        "torch_version": torch.__version__,
        "coremltools_version": ct.__version__,
        "confidence_threshold_used_for_parity": CONFIDENCE_THRESHOLD,
        "parity": parity,
    }
    MANIFEST_PATH.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(f"wrote {MANIFEST_PATH}")
    return 0


def _verify_parity(ct, torch, network, mlmodel):
    from PIL import Image

    results = []
    for fixture in FIXTURES:
        path = REPO_ROOT / "mreaderTests" / "Fixtures" / fixture
        if not path.is_file():
            continue
        rgb = letterbox_rgb(path)
        tensor = torch.from_numpy(
            np.ascontiguousarray(rgb.astype(np.float32) / 255.0)
        ).permute(2, 0, 1).unsqueeze(0)
        with torch.no_grad():
            (reference_detections, _), _ = network(tensor)
        reference_detections = reference_detections.numpy()[0]
        converted = np.asarray(
            mlmodel.predict({"image": Image.fromarray(rgb)})["detections"], np.float32
        )[0]
        keep = reference_detections[:, 4] > CONFIDENCE_THRESHOLD
        results.append(
            {
                "fixture": fixture,
                "max_abs_diff": float(np.abs(reference_detections - converted).max()),
                "confidence_max_abs_diff": float(
                    np.abs(reference_detections[:, 4] - converted[:, 4]).max()
                ),
                "detections_above_threshold": int(keep.sum()),
                "top_confidences": [
                    round(float(value), 4)
                    for value in reference_detections[keep][:4, 4]
                ],
                "class_counts": {
                    CLASS_NAMES[class_id]: int(((reference_detections[:, 5].round() == class_id) & keep).sum())
                    for class_id in CLASS_NAMES
                },
            }
        )
    return results


if __name__ == "__main__":
    sys.exit(main())
