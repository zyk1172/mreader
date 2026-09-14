from pathlib import Path
from ultralytics import YOLO

checkpoint = Path('/tmp/manga109-panel-yolo26s-best.pt')
output_dir = Path('/tmp/panel-export')
output_dir.mkdir(parents=True, exist_ok=True)

model = YOLO(str(checkpoint))
output = model.export(
    format='coreml',
    imgsz=640,
    batch=1,
    dynamic=False,
    nms=False,
    quantize=16,
)
print(f'exported={output}')
