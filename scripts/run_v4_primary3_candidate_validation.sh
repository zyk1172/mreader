#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash scripts/run_v4_primary3_candidate_validation.sh /path/to/Candidate.mlpackage [DEVICE_ID]

The candidate is staged temporarily as mreader/MangaVisionV2B5.mlpackage, then:
  1. the simulator MangaVisionRegressionGateTests run;
  2. if DEVICE_ID is supplied, the physical-device end-to-end provider benchmark runs;
  3. the original bundled model is restored even on failure.

No candidate model bytes are committed by this script.
EOF
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CANDIDATE="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
DEVICE_ID="${2:-}"
MODEL_DST="$REPO_ROOT/mreader/MangaVisionV2B5.mlpackage"
DERIVED_DATA="${TMPDIR:-/tmp}/mreader-v4-primary3-derived"
OUTPUT_DIR="${TMPDIR:-/tmp}/mreader-v4-primary3-results"
BACKUP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mreader-v4-model-backup.XXXXXX")"
MODEL_BACKUP="$BACKUP_ROOT/MangaVisionV2B5.mlpackage"

if [[ ! -d "$CANDIDATE" ]]; then
  echo "Candidate mlpackage does not exist: $CANDIDATE" >&2
  exit 2
fi
if [[ ! -d "$MODEL_DST" ]]; then
  echo "Bundled model is missing: $MODEL_DST" >&2
  exit 2
fi

mkdir -p "$OUTPUT_DIR"
rm -rf "$DERIVED_DATA"
ditto "$MODEL_DST" "$MODEL_BACKUP"

restore_model() {
  rm -rf "$MODEL_DST"
  ditto "$MODEL_BACKUP" "$MODEL_DST"
  rm -rf "$BACKUP_ROOT"
}
trap restore_model EXIT INT TERM

rm -rf "$MODEL_DST"
ditto "$CANDIDATE" "$MODEL_DST"

echo "==> Candidate staged temporarily"
echo "    $CANDIDATE"

echo "==> Simulator contract + regression gate"
xcodebuild \
  -project "$REPO_ROOT/mreader.xcodeproj" \
  -scheme mreader \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  -only-testing:mreaderTests/MangaVisionRegressionGateTests \
  -resultBundlePath "$OUTPUT_DIR/V4Primary3SimulatorGate.xcresult" \
  test | tee "$OUTPUT_DIR/simulator-gate.log"

if [[ -n "$DEVICE_ID" ]]; then
  echo "==> Physical-device full provider pipeline"
  xcodebuild \
    -project "$REPO_ROOT/mreader.xcodeproj" \
    -scheme mreaderDeviceBench \
    -configuration Debug \
    -destination "platform=iOS,id=$DEVICE_ID" \
    -derivedDataPath "$DERIVED_DATA" \
    -only-testing:mreaderTests/V2B5DevicePerformanceTests/testEndToEndProviderPipelineAll \
    -resultBundlePath "$OUTPUT_DIR/V4Primary3DevicePipeline.xcresult" \
    test | tee "$OUTPUT_DIR/device-pipeline.log"

  echo "==> Device JSON records"
  grep 'V2B5_BENCHMARK_JSON=' "$OUTPUT_DIR/device-pipeline.log" || true
else
  echo "==> DEVICE_ID not supplied; physical-device stage not run."
  echo "    Obtain it with: xcrun xctrace list devices"
fi

echo "==> Results: $OUTPUT_DIR"
echo "==> Original bundled model will now be restored."
