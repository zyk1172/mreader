#!/usr/bin/env python3
"""Generate deterministic MangaLayout4 V1 Python-reference parity fixtures.

This dependency-free script is a transcription of the frozen postprocess behavior in:
- manga-layout4-training/src/manga_layout4/losses.py::locations / boxes_from_ltrb
- manga-layout4-training/src/manga_layout4/decode.py::decode_predictions
at training-repository tree f7e204397432e8a4a9bb1d2901442ec377a78599.

It is intentionally a synthetic raw-output gate. It verifies the Swift decoder,
NMS, coordinate restore, instance masks, connected components and adapter contour
policy even when the formal Core ML package is not materialized. Real-page
Python/Core ML parity remains a separate required gate.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path

LEVELS = {
    "p2": (4, 160, 160),
    "p3": (8, 80, 80),
    "p4": (16, 40, 40),
    "p5": (32, 20, 20),
}
CLASS_NAMES = ["frame", "text", "balloon", "onomatopoeia"]
SCORE_THRESHOLDS = {
    "frame": 0.65,
    "text": 0.35,
    "balloon": 0.30,
    "onomatopoeia": 0.30,
}
NMS_THRESHOLDS = {name: 0.35 for name in CLASS_NAMES}
PRE_NMS_TOPK = 1200
MAX_DETECTIONS = 300
MASK_THRESHOLD = 0.50
PROTO_W = 320
PROTO_H = 320


def sigmoid(value: float) -> float:
    if value >= 0:
        return 1.0 / (1.0 + math.exp(-value))
    exponential = math.exp(value)
    return exponential / (1.0 + exponential)


def logit(probability: float) -> float:
    return math.log(probability / (1.0 - probability))


def softplus(value: float) -> float:
    if value > 20.0:
        return value
    if value < -20.0:
        return math.exp(value)
    return math.log1p(math.exp(value))


def inverse_softplus(value: float) -> float:
    if value > 20.0:
        return value
    return math.log(math.expm1(value))


def make_letterbox(width: int, height: int) -> dict:
    scale = min(640.0 / width, 640.0 / height)
    resized_width = max(int(round(width * scale)), 1)
    resized_height = max(int(round(height * scale)), 1)
    horizontal_padding = max(640 - resized_width, 0)
    vertical_padding = max(640 - resized_height, 0)
    pad_left = horizontal_padding // 2
    pad_top = vertical_padding // 2
    return {
        "original_width": width,
        "original_height": height,
        "scale": scale,
        "resized_width": resized_width,
        "resized_height": resized_height,
        "pad_left": pad_left,
        "pad_top": pad_top,
        "pad_right": horizontal_padding - pad_left,
        "pad_bottom": vertical_padding - pad_top,
    }


def source_normalized_rect(model_box: list[float], meta: dict) -> list[float]:
    x1, y1, x2, y2 = model_box
    x1 = min(max(x1, 0.0), 640.0)
    x2 = min(max(x2, 0.0), 640.0)
    y1 = min(max(y1, 0.0), 640.0)
    y2 = min(max(y2, 0.0), 640.0)
    source_x1 = (x1 - meta["pad_left"]) / meta["scale"]
    source_y1 = (y1 - meta["pad_top"]) / meta["scale"]
    source_x2 = (x2 - meta["pad_left"]) / meta["scale"]
    source_y2 = (y2 - meta["pad_top"]) / meta["scale"]
    nx1 = min(max(source_x1 / meta["original_width"], 0.0), 1.0)
    ny1 = min(max(source_y1 / meta["original_height"], 0.0), 1.0)
    nx2 = min(max(source_x2 / meta["original_width"], 0.0), 1.0)
    ny2 = min(max(source_y2 / meta["original_height"], 0.0), 1.0)
    return [nx1, ny1, max(nx2 - nx1, 0.0), max(ny2 - ny1, 0.0)]


def intersection_over_union(lhs: list[float], rhs: list[float]) -> float:
    ix1 = max(lhs[0], rhs[0])
    iy1 = max(lhs[1], rhs[1])
    ix2 = min(lhs[2], rhs[2])
    iy2 = min(lhs[3], rhs[3])
    intersection = max(ix2 - ix1, 0.0) * max(iy2 - iy1, 0.0)
    lhs_area = max(lhs[2] - lhs[0], 0.0) * max(lhs[3] - lhs[1], 0.0)
    rhs_area = max(rhs[2] - rhs[0], 0.0) * max(rhs[3] - rhs[1], 0.0)
    union = lhs_area + rhs_area - intersection
    return intersection / union if union > 0 else 0.0


def decode_case(case: dict) -> dict:
    meta = make_letterbox(case["source_width"], case["source_height"])
    by_level = {level: [] for level in LEVELS}

    for input_order, candidate in enumerate(case["candidates"]):
        stride, _height, width = LEVELS[candidate["level"]]
        score = sigmoid(logit(candidate["score"]))
        distances = []
        for distance in candidate["distances"]:
            raw_distance = inverse_softplus(distance / stride)
            distances.append(softplus(raw_distance) * stride)

        cx = (candidate["x"] + 0.5) * stride
        cy = (candidate["y"] + 0.5) * stride
        left, top, right, bottom = distances
        box = [
            max(cx - left, 0.0),
            max(cy - top, 0.0),
            min(cx + right, 640.0),
            min(cy + bottom, 640.0),
        ]
        flat_index = (
            (candidate["y"] * width + candidate["x"]) * 4
            + CLASS_NAMES.index(candidate["class"])
        )
        by_level[candidate["level"]].append(
            {
                "class": candidate["class"],
                "score": score,
                "box": box,
                "level": candidate["level"],
                "coefficients": candidate.get("coefficients", [0.0] * 8),
                "flat_index": flat_index,
                "input_order": input_order,
            }
        )

    thresholded = []
    maximum_scores = {name: 0.0 for name in CLASS_NAMES}
    post_threshold_counts = {name: 0 for name in CLASS_NAMES}
    pre_threshold_topk_count = 0

    for level, (_stride, height, width) in LEVELS.items():
        # Unspecified classification logits are -100. Sparse cases contain far fewer
        # than 1200 explicit entries, so sorting these explicit values followed by
        # sub-threshold background is exactly equivalent to dense torch.topk here.
        ranked = sorted(
            by_level[level],
            key=lambda item: (-item["score"], item["flat_index"]),
        )
        top = ranked[:PRE_NMS_TOPK]
        pre_threshold_topk_count += min(PRE_NMS_TOPK, height * width * 4)
        for item in top:
            name = item["class"]
            maximum_scores[name] = max(maximum_scores[name], item["score"])
            if item["score"] >= SCORE_THRESHOLDS[name]:
                thresholded.append(item)
                post_threshold_counts[name] += 1

    kept = []
    post_nms_counts = {name: 0 for name in CLASS_NAMES}
    for class_name in CLASS_NAMES:
        class_candidates = [item for item in thresholded if item["class"] == class_name]
        class_candidates.sort(
            key=lambda item: (
                -item["score"],
                CLASS_NAMES.index(item["class"]),
                item["input_order"],
            )
        )
        class_kept = []
        for candidate in class_candidates:
            if any(
                intersection_over_union(candidate["box"], existing["box"])
                > NMS_THRESHOLDS[class_name]
                for existing in class_kept
            ):
                continue
            class_kept.append(candidate)
        post_nms_counts[class_name] = len(class_kept)
        kept.extend(class_kept)

    kept.sort(
        key=lambda item: (
            -item["score"],
            CLASS_NAMES.index(item["class"]),
            item["input_order"],
        )
    )
    kept = kept[:MAX_DETECTIONS]

    detections = []
    balloons = []
    for item in kept:
        x1, y1, x2, y2 = item["box"]
        detections.append(
            {
                "class": item["class"],
                "score": item["score"],
                "level": item["level"],
                "model_box": [x1, y1, x2 - x1, y2 - y1],
                "normalized_box": source_normalized_rect(item["box"], meta),
            }
        )
        if item["class"] == "balloon":
            balloons.append(mask_expected(item, case, meta))

    return {
        "name": case["name"],
        "source_width": case["source_width"],
        "source_height": case["source_height"],
        "letterbox": meta,
        "candidates": case["candidates"],
        "prototype_defaults": case.get(
            "prototype_defaults",
            [-10.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        ),
        "prototype_rectangles": case.get("prototype_rectangles", []),
        "expected": {
            "detections": detections,
            "diagnostics": {
                "total_location_class_count": sum(
                    height * width * 4 for _stride, height, width in LEVELS.values()
                ),
                "pre_threshold_top_k_count": pre_threshold_topk_count,
                "post_threshold_counts": post_threshold_counts,
                "post_nms_counts": post_nms_counts,
                "maximum_scores": maximum_scores,
            },
            "balloons": balloons,
        },
    }


def mask_expected(item: dict, case: dict, meta: dict) -> dict:
    defaults = case.get(
        "prototype_defaults",
        [-10.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
    )
    rectangles = case.get("prototype_rectangles", [])
    coefficients = [math.tanh(value) for value in item["coefficients"]]
    x1, y1, x2, y2 = item["box"]
    crop_x1 = min(max(math.floor(x1 * PROTO_W / 640.0), 0), PROTO_W)
    crop_y1 = min(max(math.floor(y1 * PROTO_H / 640.0), 0), PROTO_H)
    crop_x2 = min(max(math.ceil(x2 * PROTO_W / 640.0), 0), PROTO_W)
    crop_y2 = min(max(math.ceil(y2 * PROTO_H / 640.0), 0), PROTO_H)
    pixels = [0] * (PROTO_W * PROTO_H)

    for y in range(crop_y1, crop_y2):
        for x in range(crop_x1, crop_x2):
            values = list(defaults)
            for rectangle in rectangles:
                if (
                    rectangle["x1"] <= x < rectangle["x2"]
                    and rectangle["y1"] <= y < rectangle["y2"]
                ):
                    values[rectangle["channel"]] = rectangle["value"]
            mask_logit = sum(coefficients[index] * values[index] for index in range(8))
            if sigmoid(mask_logit) >= MASK_THRESHOLD:
                pixels[y * PROTO_W + x] = 1

    found_components = connected_components(pixels, PROTO_W, PROTO_H)
    found_components.sort(
        key=lambda component: (
            -len(component["indices"]),
            component["bounds"][1],
            component["bounds"][0],
        )
    )
    contours = [
        scanline_contour(component, PROTO_W, PROTO_H, meta)
        for component in found_components
    ]
    return {
        "foreground_pixel_count": sum(pixels),
        "mask_sha256": hashlib.sha256(bytes(pixels)).hexdigest(),
        "component_pixel_counts": [
            len(component["indices"]) for component in found_components
        ],
        "component_bounds": [
            component["bounds"] for component in found_components
        ],
        "contours": contours,
    }


def connected_components(pixels: list[int], width: int, height: int) -> list[dict]:
    visited = [False] * len(pixels)
    result = []
    neighbors = [
        (-1, -1), (0, -1), (1, -1),
        (-1, 0),            (1, 0),
        (-1, 1),  (0, 1),  (1, 1),
    ]
    for seed, value in enumerate(pixels):
        if not value or visited[seed]:
            continue
        visited[seed] = True
        queue = [seed]
        cursor = 0
        indices = []
        min_x, min_y = width, height
        max_x = max_y = 0
        while cursor < len(queue):
            index = queue[cursor]
            cursor += 1
            indices.append(index)
            x = index % width
            y = index // width
            min_x, min_y = min(min_x, x), min(min_y, y)
            max_x, max_y = max(max_x, x), max(max_y, y)
            for dx, dy in neighbors:
                nx, ny = x + dx, y + dy
                if 0 <= nx < width and 0 <= ny < height:
                    next_index = ny * width + nx
                    if pixels[next_index] and not visited[next_index]:
                        visited[next_index] = True
                        queue.append(next_index)
        result.append(
            {
                "indices": indices,
                "bounds": [min_x, min_y, max_x - min_x + 1, max_y - min_y + 1],
            }
        )
    return result


def model_point_to_normalized(x: float, y: float, meta: dict) -> list[float]:
    normalized_x = (
        (x - meta["pad_left"])
        / meta["scale"]
        / meta["original_width"]
    )
    normalized_y = (
        (y - meta["pad_top"])
        / meta["scale"]
        / meta["original_height"]
    )
    return [
        min(max(normalized_x, 0.0), 1.0),
        min(max(normalized_y, 0.0), 1.0),
    ]


def scanline_contour(
    component: dict,
    width: int,
    height: int,
    meta: dict,
) -> list[list[float]]:
    row_extents = {}
    for index in component["indices"]:
        x = index % width
        y = index // width
        if y in row_extents:
            row_extents[y] = [
                min(row_extents[y][0], x),
                max(row_extents[y][1], x),
            ]
        else:
            row_extents[y] = [x, x]

    rows = sorted(row_extents)
    prototype_points = [
        (row_extents[y][0] + 0.5, y + 0.5)
        for y in rows
    ]
    prototype_points.extend(
        (row_extents[y][1] + 0.5, y + 0.5)
        for y in reversed(rows)
    )
    normalized = [
        model_point_to_normalized(
            x * 640.0 / width,
            y * 640.0 / height,
            meta,
        )
        for x, y in prototype_points
    ]

    deduplicated = []
    for point in normalized:
        if (
            deduplicated
            and abs(deduplicated[-1][0] - point[0]) < 0.000001
            and abs(deduplicated[-1][1] - point[1]) < 0.000001
        ):
            continue
        deduplicated.append(point)
    if (
        len(deduplicated) > 1
        and abs(deduplicated[0][0] - deduplicated[-1][0]) < 0.000001
        and abs(deduplicated[0][1] - deduplicated[-1][1]) < 0.000001
    ):
        deduplicated.pop()

    # Mirrors MangaVisionContour.maximumPointCount and floor-based sampling.
    if len(deduplicated) > 32:
        count = len(deduplicated)
        deduplicated = [
            deduplicated[math.floor(index * count / 32.0)]
            for index in range(32)
        ]
    return deduplicated if len(deduplicated) >= 3 else []


CASES = [
    {
        "name": "p2_same_class_nms_preserves_cross_class",
        "source_width": 640,
        "source_height": 640,
        "candidates": [
            {"level": "p2", "class": "frame", "x": 10, "y": 10, "score": 0.90, "distances": [20, 20, 20, 20]},
            {"level": "p2", "class": "frame", "x": 11, "y": 10, "score": 0.88, "distances": [20, 20, 20, 20]},
            {"level": "p2", "class": "text", "x": 10, "y": 10, "score": 0.80, "distances": [20, 20, 20, 20]},
        ],
    },
    {
        "name": "p3_per_class_thresholds",
        "source_width": 640,
        "source_height": 640,
        "candidates": [
            {"level": "p3", "class": "text", "x": 20, "y": 12, "score": 0.36, "distances": [15, 10, 18, 12]},
            {"level": "p3", "class": "text", "x": 30, "y": 15, "score": 0.34, "distances": [10, 10, 10, 10]},
            {"level": "p3", "class": "onomatopoeia", "x": 40, "y": 20, "score": 0.31, "distances": [12, 14, 16, 18]},
            {"level": "p3", "class": "balloon", "x": 50, "y": 30, "score": 0.29, "distances": [25, 20, 25, 20]},
        ],
    },
    {
        "name": "p4_balloon_mask_two_components",
        "source_width": 640,
        "source_height": 640,
        "prototype_defaults": [-10, 0, 0, 0, 0, 0, 0, 0],
        "prototype_rectangles": [
            {"channel": 0, "value": 10, "x1": 50, "y1": 40, "x2": 60, "y2": 50},
            {"channel": 0, "value": 10, "x1": 120, "y1": 100, "x2": 128, "y2": 108},
        ],
        "candidates": [
            {
                "level": "p4",
                "class": "balloon",
                "x": 9,
                "y": 7,
                "score": 0.78,
                "distances": [152, 120, 336, 392],
                "coefficients": [10, 0, 0, 0, 0, 0, 0, 0],
            }
        ],
    },
    {
        "name": "p5_large_frame",
        "source_width": 640,
        "source_height": 640,
        "candidates": [
            {"level": "p5", "class": "frame", "x": 9, "y": 9, "score": 0.72, "distances": [280, 280, 280, 280]}
        ],
    },
    {
        "name": "cross_level_text_nms",
        "source_width": 640,
        "source_height": 640,
        "candidates": [
            {"level": "p2", "class": "text", "x": 49, "y": 49, "score": 0.86, "distances": [60, 60, 60, 60]},
            {"level": "p3", "class": "text", "x": 24, "y": 24, "score": 0.82, "distances": [58, 58, 58, 58]},
            {"level": "p4", "class": "onomatopoeia", "x": 20, "y": 20, "score": 0.65, "distances": [20, 20, 20, 20]},
        ],
    },
    {
        "name": "portrait_letterbox_and_mask_crop",
        "source_width": 1000,
        "source_height": 1500,
        "prototype_defaults": [-10, 0, 0, 0, 0, 0, 0, 0],
        "prototype_rectangles": [
            {"channel": 0, "value": 10, "x1": 10, "y1": 80, "x2": 100, "y2": 180},
            {"channel": 0, "value": 10, "x1": 180, "y1": 100, "x2": 250, "y2": 170},
        ],
        "candidates": [
            {
                "level": "p3",
                "class": "balloon",
                "x": 19,
                "y": 32,
                "score": 0.67,
                "distances": [80, 70, 96, 110],
                "coefficients": [8, 0, 0, 0, 0, 0, 0, 0],
            },
            {"level": "p2", "class": "onomatopoeia", "x": 95, "y": 90, "score": 0.44, "distances": [30, 12, 35, 16]},
        ],
    },
    {
        "name": "landscape_letterbox",
        "source_width": 1600,
        "source_height": 900,
        "candidates": [
            {"level": "p4", "class": "frame", "x": 19, "y": 19, "score": 0.91, "distances": [210, 130, 250, 180]},
            {"level": "p2", "class": "text", "x": 80, "y": 95, "score": 0.74, "distances": [22, 12, 28, 14]},
        ],
    },
    {
        "name": "all_levels_all_classes",
        "source_width": 1200,
        "source_height": 1800,
        "prototype_defaults": [-9, 0, 0, 0, 0, 0, 0, 0],
        "prototype_rectangles": [
            {"channel": 0, "value": 9, "x1": 135, "y1": 155, "x2": 170, "y2": 190}
        ],
        "candidates": [
            {"level": "p2", "class": "text", "x": 70, "y": 70, "score": 0.83, "distances": [18, 10, 24, 14]},
            {"level": "p3", "class": "onomatopoeia", "x": 25, "y": 35, "score": 0.62, "distances": [34, 26, 40, 30]},
            {
                "level": "p4",
                "class": "balloon",
                "x": 18,
                "y": 21,
                "score": 0.73,
                "distances": [70, 60, 74, 68],
                "coefficients": [9, 0, 0, 0, 0, 0, 0, 0],
            },
            {"level": "p5", "class": "frame", "x": 9, "y": 10, "score": 0.88, "distances": [250, 290, 260, 250]},
        ],
    },
]


def build_fixture() -> dict:
    return {
        "revision": "manga-layout4-v1-python-swift-synthetic-parity-v1",
        "reference": {
            "repository": "zyk1172/manga-layout4-training",
            "tree": "f7e204397432e8a4a9bb1d2901442ec377a78599",
            "decode": "src/manga_layout4/decode.py",
            "bbox": "src/manga_layout4/losses.py::boxes_from_ltrb",
            "note": "Synthetic raw-output gate; formal-model real-page parity is a separate required gate.",
        },
        "configuration": {
            "pre_nms_topk": PRE_NMS_TOPK,
            "max_detections": MAX_DETECTIONS,
            "score_thresholds": SCORE_THRESHOLDS,
            "nms_thresholds": NMS_THRESHOLDS,
            "mask_threshold": MASK_THRESHOLD,
        },
        "cases": [decode_case(case) for case in CASES],
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    arguments = parser.parse_args()
    output = Path(arguments.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(build_fixture(), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
