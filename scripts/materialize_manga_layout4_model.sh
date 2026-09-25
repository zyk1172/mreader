#!/usr/bin/env bash
set -euo pipefail

ROOT="${SRCROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
TARGET_ROOT="$ROOT/.local-models"
TARGET="$TARGET_ROOT/MangaLayout4V1.mlpackage"
TRAINING_REPO="${MREADER_MANGA_LAYOUT4_TRAINING_REPO_PATH:-$ROOT/../manga-layout4-training}"

is_model_package() {
  local path="$1"
  [[ -d "$path" ]] || return 1
  [[ -f "$path/Manifest.json" ]] || return 1
  [[ -d "$path/Data/com.apple.CoreML" ]] || return 1
  return 0
}

copy_model() {
  local source="$1"
  is_model_package "$source" || return 1
  if [[ "$source" == "$TARGET" ]]; then
    return 0
  fi
  rm -rf "$TARGET"
  mkdir -p "$TARGET_ROOT"
  if command -v ditto >/dev/null 2>&1; then
    ditto "$source" "$TARGET"
  else
    cp -R "$source" "$TARGET"
  fi
  is_model_package "$TARGET"
}

if is_model_package "$TARGET"; then
  echo "MangaLayout4 V1 model ready: $TARGET"
  exit 0
fi

if [[ -n "${MREADER_MANGA_LAYOUT4_MODEL_PATH:-}" ]] && copy_model "$MREADER_MANGA_LAYOUT4_MODEL_PATH"; then
  echo "MangaLayout4 V1 model materialized from MREADER_MANGA_LAYOUT4_MODEL_PATH"
  exit 0
fi

if [[ -d "$TRAINING_REPO/outputs" ]]; then
  FOUND="$(find "$TRAINING_REPO/outputs" -type d -name 'MangaLayout4V1.mlpackage' -print -quit 2>/dev/null || true)"
  if [[ -n "$FOUND" ]] && copy_model "$FOUND"; then
    echo "MangaLayout4 V1 model materialized from training outputs: $FOUND"
    exit 0
  fi
fi

CACHE="${MREADER_MANGA_LAYOUT4_MODEL_CACHE:-$HOME/Library/Caches/mreader/models/MangaLayout4V1.mlpackage}"
if copy_model "$CACHE"; then
  echo "MangaLayout4 V1 model materialized from cache: $CACHE"
  exit 0
fi

if [[ "${CI:-}" == "true" || "${CI:-}" == "1" ]] && [[ "${MREADER_REQUIRE_MANGA_LAYOUT4_MODEL:-0}" != "1" ]]; then
  echo "warning: MangaLayout4V1.mlpackage is not available in CI; real-model runtime gate is skipped."
  echo "warning: synthetic raw-output parity still runs, but it does not prove the app bundle contains the model."
  exit 0
fi

cat >&2 <<EOF
error: MangaLayout4V1.mlpackage was not found.
Set MREADER_MANGA_LAYOUT4_MODEL_PATH to the formal epoch-40 MangaLayout4V1.mlpackage,
or keep the training checkout beside mreader so this script can find:
  $TRAINING_REPO/outputs/**/MangaLayout4V1.mlpackage
Refusing to build a local app that would launch without the Layout4 model.
EOF
exit 1
