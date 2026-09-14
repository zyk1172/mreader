# Guided Panel Core ML model

The bundled `mreader/PanelDetector.mlpackage` is an FP16 Core ML export of `ShadowB/Manga109-panel-balloon-text-yolov26-segmentation` (`best.pt`).

- Upstream model: https://huggingface.co/ShadowB/Manga109-panel-balloon-text-yolov26-segmentation
- Upstream checkpoint SHA-256: `0b4376e426fa96af3976afa6a2602421dacf2dec96ef87b4a44f5e8d4971cb6f`
- Architecture: YOLO26s instance segmentation
- Classes: `frame`, `text`, `balloon`
- App export: Core ML ML Program, static 640x640 input, batch 1, FP16, NMS-free/end-to-end output
- Runtime use: Guided Panel consumes only class `0` (`frame`). `text` and `balloon` detections are intentionally excluded.
- Upstream model repository declares MIT. Dataset and Ultralytics terms remain independently applicable; review them before redistribution/commercial release.

The original PyTorch checkpoint is not bundled in the app. Xcode compiles the `.mlpackage` into `PanelDetector.mlmodelc` for the application bundle.
