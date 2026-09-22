# Private Manga Vision model weight

`mreader` keeps application code and the Core ML model specification public, while the large V2B5 `weight.bin` is maintained in the private `zyk1172/manga-vision-training` repository.

## Design

- Normal `git pull` never contacts the private model repository.
- Xcode/CI materializes the weight only when the real local `weight.bin` is missing.
- An existing local weight is reused, so ordinary development and offline builds are not disturbed.
- The private repository stores `exports/coreml/MangaVisionV2B5/weight.bin` with Git LFS.
- Credentials are never committed. Local Git credentials are used by default; CI may provide `MREADER_MODEL_TOKEN`.
- `MREADER_MODEL_WEIGHT_PATH` can point at an already-downloaded weight for fully offline setup.

## One-time private migration

From a checkout of the private training repository, while the current public checkout still contains the real weight:

```bash
bash scripts/import_mreader_weight.sh /absolute/path/to/mreader/mreader/MangaVisionV2B5.mlpackage/Data/com.apple.CoreML/weights/weight.bin
git add .gitattributes exports/coreml/MangaVisionV2B5/weight.bin
git commit -m "model: store MangaVision V2B5 weight privately"
git push
```

After the private LFS object is confirmed, configure the public repository Actions secret `MREADER_MODEL_READ_TOKEN` with read-only access to `zyk1172/manga-vision-training`. Then the tracked public `weight.bin` can be removed in the cutover commit.

## Historical exposure

The current V2B5 weight has already existed in the public Git history. Removing it from the current tree does not erase old commits. Rewriting public history would disrupt existing clones and ordinary pulls, so the low-disruption policy is: treat the already-published weight as exposed, keep all future weights private, and rotate to a new private-only weight if secrecy of the active model matters.
