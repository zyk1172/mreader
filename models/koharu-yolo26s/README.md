---
license: other
library_name: ultralytics
pipeline_tag: image-segmentation
base_model: ShadowB/Manga109-panel-balloon-text-yolov26-segmentation
datasets:
  - MS92/MangaSegmentation
tags:
  - comics
  - manga
  - yolo26
  - instance-segmentation
  - safetensors
---

# Koharu YOLO26s

Koharu YOLO26s is a unified comic-page instance-segmentation model. It detects
and segments four classes:

| ID | Class |
|---:|---|
| 0 | `frame` |
| 1 | `dialogue_text` |
| 2 | `balloon` |
| 3 | `onomatopoeia_text` |

The model was fine-tuned from
[`ShadowB/Manga109-panel-balloon-text-yolov26-segmentation`](https://huggingface.co/ShadowB/Manga109-panel-balloon-text-yolov26-segmentation)
using MangaSeg annotations and locally licensed Manga109 page images. The
published repository contains no dataset images or annotations.

## Files

- `model.safetensors`: inference state dictionary; this is the only weight file.
- `yolo26s-seg.yaml`: YOLO26s segmentation architecture.
- `config.json`: class names and recommended image size.
- `export-manifest.json`: weight checksum and conversion validation.

The SafeTensors export contains 844 tensors for 11,437,172 parameters. It was
validated with strict state-dictionary loading and an exact forward comparison
against the training checkpoint (`max_abs_diff = 0`).

## Loading

```python
import json
from pathlib import Path

from huggingface_hub import snapshot_download
from safetensors.torch import load_file
from ultralytics import YOLO

root = Path(
    snapshot_download(
        "mayocream/koharu-yolo26s",
        allow_patterns=["*.safetensors", "*.yaml", "*.json"],
    )
)
config = json.loads((root / "config.json").read_text())
model = YOLO(root / "yolo26s-seg.yaml", task="segment")
model.model.load_state_dict(load_file(root / "model.safetensors"), strict=True)
model.model.names = {int(key): value for key, value in config["names"].items()}

results = model.predict("page.jpg", imgsz=1280, conf=0.25)
```

The checkpoint intentionally is not distributed as a PyTorch pickle (`.pt`).

## Evaluation

Evaluation used a held-out 1,539-page, book-disjoint test split.

| Evaluation | Box mAP50 | Box mAP50-95 | Mask mAP50 | Mask mAP50-95 |
|---|---:|---:|---:|---:|
| Four classes | 0.879 | 0.795 | 0.830 | 0.422 |
| Shared three classes | 0.975 | 0.923 | 0.946 | 0.492 |
| Upstream checkpoint, shared classes | 0.932 | 0.877 | 0.741 | 0.380 |

The largest shared-class improvement is dialogue-text segmentation. Balloon
mask AP remained approximately equal to the upstream checkpoint. The new
onomatopoeia class reached box mAP50-95 0.414 and mask mAP50-95 0.236.

## Training

- Input size: 1280 pixels
- Epochs: 41
- Training images: 7,532
- Validation images: 1,531
- Test images: 1,539
- Optimizer: MuSGD
- Best epoch: 36
- Ultralytics: 8.4.43

## Terms and attribution

This checkpoint is a derived research artifact. Use and redistribution must
comply with the terms of Manga109, MangaSeg, COO, the upstream checkpoint, and
Ultralytics. Review those terms before commercial use or redistribution.

- [Manga109](http://www.manga109.org/en/)
- [MangaSegmentation](https://huggingface.co/datasets/MS92/MangaSegmentation)
- [COO: Comic Onomatopoeia](https://github.com/ku21fan/COO-Comic-Onomatopoeia)
