#!/usr/bin/env bash
set -euo pipefail

ROOT="${SRCROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
# shellcheck disable=SC1090
source "$ROOT/scripts/private_model_source.conf"

WEIGHT="$ROOT/$PUBLIC_MODEL_WEIGHT_PATH"
PRIVATE_REPO_SLUG="zyk1172/manga-vision-training"
PUBLIC_REPO_SLUG="zyk1172/mreader"
KEY_DIR="${MREADER_MODEL_KEY_DIR:-$HOME/Library/Application Support/mreader/private-model-ci}"
KEY_PATH="$KEY_DIR/mreader-model-readonly"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/mreader-model-bootstrap.XXXXXX")"

cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required command not found: $1" >&2
    exit 1
  fi
}

require git
require gh
require ssh-keygen
if ! git lfs version >/dev/null 2>&1; then
  echo "error: Git LFS is required. Install it once with: brew install git-lfs" >&2
  exit 1
fi
gh auth status >/dev/null

if [[ ! -f "$WEIGHT" ]]; then
  echo "error: current Manga Vision weight is missing: $WEIGHT" >&2
  exit 1
fi
BYTES="$(wc -c < "$WEIGHT" | tr -d ' ')"
if (( BYTES <= 1048576 )); then
  echo "error: current weight is unexpectedly small ($BYTES bytes)" >&2
  exit 1
fi
if head -n 1 "$WEIGHT" 2>/dev/null | grep -q '^version https://git-lfs.github.com/spec/v1$'; then
  echo "error: current public file is only an LFS pointer; a real weight binary is required" >&2
  exit 1
fi

# Use the existing gh login without placing a personal token in any remote URL.
GH_TOKEN_VALUE="$(gh auth token)"
BASIC_AUTH="$(printf 'x-access-token:%s' "$GH_TOKEN_VALUE" | base64 | tr -d '\n')"
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0="http.https://github.com/.extraheader"
export GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $BASIC_AUTH"

PRIVATE_CHECKOUT="$WORKDIR/manga-vision-training"
GIT_LFS_SKIP_SMUDGE=1 git clone --depth 1 "$PRIVATE_MODEL_REPOSITORY_HTTPS" "$PRIVATE_CHECKOUT"
git -C "$PRIVATE_CHECKOUT" lfs install --local
git -C "$PRIVATE_CHECKOUT" lfs track "$PRIVATE_MODEL_PATH" >/dev/null
mkdir -p "$(dirname "$PRIVATE_CHECKOUT/$PRIVATE_MODEL_PATH")"
cp "$WEIGHT" "$PRIVATE_CHECKOUT/$PRIVATE_MODEL_PATH"

git -C "$PRIVATE_CHECKOUT" config user.name "$(gh api user --jq .login)"
git -C "$PRIVATE_CHECKOUT" config user.email "$(gh api user --jq '.id | tostring + "+mreader-model@users.noreply.github.com"')"
git -C "$PRIVATE_CHECKOUT" add .gitattributes "$PRIVATE_MODEL_PATH"
if ! git -C "$PRIVATE_CHECKOUT" diff --cached --quiet; then
  git -C "$PRIVATE_CHECKOUT" commit -m "model: store MangaVision V2B5 weight privately"
  git -C "$PRIVATE_CHECKOUT" push origin HEAD:main
else
  echo "Private model repository already contains the same staged weight."
fi

mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"
if [[ ! -f "$KEY_PATH" ]]; then
  ssh-keygen -q -t ed25519 -N "" -C "mreader-model-ci-readonly" -f "$KEY_PATH"
fi
chmod 600 "$KEY_PATH"
chmod 644 "$KEY_PATH.pub"
PUBLIC_KEY="$(cat "$KEY_PATH.pub")"

if ! gh api "repos/$PRIVATE_REPO_SLUG/keys" --paginate --jq '.[].key' | grep -Fqx "$PUBLIC_KEY"; then
  gh api --method POST "repos/$PRIVATE_REPO_SLUG/keys" \
    -f title="mreader CI model read-only" \
    -f key="$PUBLIC_KEY" \
    -F read_only=true >/dev/null
fi

gh secret set MREADER_MODEL_DEPLOY_KEY --repo "$PUBLIC_REPO_SLUG" < "$KEY_PATH"

SHA256="$(shasum -a 256 "$WEIGHT" | awk '{print $1}')"
echo
echo "Private Manga Vision bootstrap complete."
echo "weight bytes: $BYTES"
echo "weight sha256: $SHA256"
echo "private repository: $PRIVATE_REPO_SLUG"
echo "CI secret: MREADER_MODEL_DEPLOY_KEY"
echo
echo "The public weight can now be removed in the cutover commit."
