# Private Manga Vision model weight

`mreader` keeps application code and the Core ML model specification public, while the large V2B5 `weight.bin` is maintained in the private `zyk1172/manga-vision-training` repository.

## Design

- Normal `git pull` never contacts the private model repository.
- Xcode/CI materializes the weight only when the real local `weight.bin` is missing.
- An existing local weight is reused, so ordinary development and offline builds are not disturbed.
- The private repository stores `exports/coreml/MangaVisionV2B5/weight.bin` with Git LFS.
- Credentials are never committed. Local Git credentials are used by default; CI prefers the dedicated read-only `MREADER_MODEL_DEPLOY_KEY` and retains `MREADER_MODEL_TOKEN` only as an optional fallback.
- `MREADER_MODEL_WEIGHT_PATH` can point at an already-downloaded weight for fully offline setup.

## One-time private migration

Preferred path: from the public `mreader` checkout, while the real weight is still present, run:

```bash
bash scripts/bootstrap_private_model_access.sh
```

The bootstrap script:

1. pushes the current V2B5 weight into the private training repository using Git LFS;
2. generates a dedicated ED25519 deploy key;
3. registers only the public key on `zyk1172/manga-vision-training` as **read-only**;
4. stores the private key in the public repository Actions secret `MREADER_MODEL_DEPLOY_KEY`;\n5. seeds the local model cache so the first build after cutover does not need a network fetch.

It uses the existing authenticated `gh` login only during bootstrap and does **not** store the personal GitHub token in CI.

Manual fallback is still available from the private training checkout:

```bash
bash scripts/import_mreader_weight.sh /absolute/path/to/mreader/mreader/MangaVisionV2B5.mlpackage/Data/com.apple.CoreML/weights/weight.bin
git add .gitattributes exports/coreml/MangaVisionV2B5/weight.bin
git commit -m "model: store MangaVision V2B5 weight privately"
git push
```

After the private object and deploy key are confirmed, the tracked public `weight.bin` can be removed in the cutover commit.

## Historical exposure

The current V2B5 weight has already existed in the public Git history. Removing it from the current tree does not erase old commits. Rewriting public history would disrupt existing clones and ordinary pulls, so the low-disruption policy is: treat the already-published weight as exposed, keep all future weights private, and rotate to a new private-only weight if secrecy of the active model matters.
