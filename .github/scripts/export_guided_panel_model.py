from pathlib import Path
import shutil
from ultralytics import YOLO

checkpoint = Path('/tmp/manga109-panel-yolo26s-best.pt')
output_dir = Path('/tmp/panel-export')
output_dir.mkdir(parents=True, exist_ok=True)
target = output_dir / 'PanelDetector.mlpackage'

model = YOLO(str(checkpoint))
output = Path(model.export(
    format='coreml',
    imgsz=640,
    batch=1,
    dynamic=False,
    nms=False,
    quantize=16,
))

if target.exists():
    shutil.rmtree(target)
shutil.copytree(output, target)
print(f'exported={output}')
print(f'staged={target}')
