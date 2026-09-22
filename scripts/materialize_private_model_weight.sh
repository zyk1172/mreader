#!/usr/bin/env bash
set -euo pipefail

ROOT="${SRCROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
CONFIG="$ROOT/scripts/private_model_source.conf"
if [[ ! -f "$CONFIG" ]]; then
  echo "error: private model source config is missing: $CONFIG" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG"

TARGET="$ROOT/$PUBLIC_MODEL_WEIGHT_PATH"
PRIVATE_SIBLING="${MREADER_MODEL_REPO_PATH:-$ROOT/../manga-vision-training}"
CACHE_ROOT="${MREADER_MODEL_CACHE_DIR:-$HOME/Library/Caches/mreader/private-models}"
CACHE_REPO="$CACHE_ROOT/manga-vision-training"

is_real_weight() {
  local path="$1"
  [[ -f "$path" ]] || return 1
  local bytes
  bytes="$(wc -c < "$path" | tr -d ' ')"
  (( bytes > 1048576 )) || return 1
  if head -n 1 "$path" 2>/dev/null | grep -q '^version https://git-lfs.github.com/spec/v1$'; then
    return 1
  fi
  return 0
}

copy_weight() {
  local source="$1"
  if ! is_real_weight "$source"; then
    return 1
  fi
  mkdir -p "$(dirname "$TARGET")"
  cp "$source" "$TARGET"
  if ! is_real_weight "$TARGET"; then
    echo "error: copied model weight is invalid: $TARGET" >&2
    rm -f "$TARGET"
    return 1
  fi
  echo "Manga Vision private weight ready: $TARGET"
  return 0
}

# Existing materialized weight wins. This keeps ordinary pulls and offline builds untouched.
if is_real_weight "$TARGET"; then
  exit 0
fi

if [[ -n "${MREADER_MODEL_WEIGHT_PATH:-}" ]] && copy_weight "$MREADER_MODEL_WEIGHT_PATH"; then
  exit 0
fi

if copy_weight "$PRIVATE_SIBLING/$PRIVATE_MODEL_PATH"; then
  exit 0
fi

# Reuse an already-materialized private cache before attempting network access.
if copy_weight "$CACHE_REPO/$PRIVATE_MODEL_PATH"; then
  exit 0
fi

if ! git lfs version >/dev/null 2>&1; then
  echo "error: private Manga Vision weight is missing and Git LFS is unavailable." >&2
  echo "Install Git LFS once (brew install git-lfs), or set MREADER_MODEL_WEIGHT_PATH." >&2
  exit 1
fi

mkdir -p "$CACHE_ROOT"

AUTH_ARGS=()
if [[ -n "${MREADER_MODEL_TOKEN:-}" ]]; then
  BASIC_AUTH="$(printf 'x-access-token:%s' "$MREADER_MODEL_TOKEN" | base64 | tr -d '\n')"
  AUTH_ARGS=(-c "http.https://github.com/.extraheader=AUTHORIZATION: basic $BASIC_AUTH")
fi

if [[ ! -d "$CACHE_REPO/.git" ]]; then
  rm -rf "$CACHE_REPO"
  GIT_LFS_SKIP_SMUDGE=1 git "${AUTH_ARGS[@]}" clone --filter=blob:none --no-checkout "$PRIVATE_MODEL_REPOSITORY" "$CACHE_REPO"
fi

git "${AUTH_ARGS[@]}" -C "$CACHE_REPO" fetch --depth 1 origin "$PRIVATE_MODEL_REF"
git -C "$CACHE_REPO" checkout --detach --force FETCH_HEAD
git "${AUTH_ARGS[@]}" -C "$CACHE_REPO" lfs pull --include="$PRIVATE_MODEL_PATH" --exclude=""

if copy_weight "$CACHE_REPO/$PRIVATE_MODEL_PATH"; then
  exit 0
fi

echo "error: failed to materialize private Manga Vision weight from $PRIVATE_MODEL_REPOSITORY@$PRIVATE_MODEL_REF" >&2
exit 1
