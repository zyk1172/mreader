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

# Existing materialized weight wins. Ordinary git pull never needs model credentials.
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
EFFECTIVE_REPOSITORY="$PRIVATE_MODEL_REPOSITORY_HTTPS"
TEMP_DEPLOY_KEY=""
cleanup_private_model_key() {
  if [[ -n "$TEMP_DEPLOY_KEY" ]]; then
    rm -f "$TEMP_DEPLOY_KEY"
  fi
}
trap cleanup_private_model_key EXIT

if [[ -n "${MREADER_MODEL_DEPLOY_KEY:-}" ]]; then
  TEMP_DEPLOY_KEY="$(mktemp "$CACHE_ROOT/deploy-key.XXXXXX")"
  printf '%s\n' "$MREADER_MODEL_DEPLOY_KEY" > "$TEMP_DEPLOY_KEY"
  chmod 600 "$TEMP_DEPLOY_KEY"
  export GIT_SSH_COMMAND="ssh -i \"$TEMP_DEPLOY_KEY\" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
  EFFECTIVE_REPOSITORY="$PRIVATE_MODEL_REPOSITORY_SSH"
elif [[ -n "${MREADER_MODEL_TOKEN:-}" ]]; then
  BASIC_AUTH="$(printf 'x-access-token:%s' "$MREADER_MODEL_TOKEN" | base64 | tr -d '\n')"
  AUTH_ARGS=(-c "http.https://github.com/.extraheader=AUTHORIZATION: basic $BASIC_AUTH")
fi

if [[ ! -d "$CACHE_REPO/.git" ]]; then
  rm -rf "$CACHE_REPO"
  GIT_LFS_SKIP_SMUDGE=1 git "${AUTH_ARGS[@]}" clone --filter=blob:none --no-checkout "$EFFECTIVE_REPOSITORY" "$CACHE_REPO"
else
  git -C "$CACHE_REPO" remote set-url origin "$EFFECTIVE_REPOSITORY"
fi

git "${AUTH_ARGS[@]}" -C "$CACHE_REPO" fetch --depth 1 origin "$PRIVATE_MODEL_REF"
GIT_LFS_SKIP_SMUDGE=1 git -C "$CACHE_REPO" checkout --detach --force FETCH_HEAD
git "${AUTH_ARGS[@]}" -C "$CACHE_REPO" lfs pull --include="$PRIVATE_MODEL_PATH" --exclude=""

if copy_weight "$CACHE_REPO/$PRIVATE_MODEL_PATH"; then
  exit 0
fi

echo "error: failed to materialize private Manga Vision weight from the configured private repository at $PRIVATE_MODEL_REF" >&2
exit 1
