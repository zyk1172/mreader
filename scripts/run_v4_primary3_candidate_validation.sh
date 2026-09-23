#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash scripts/run_v4_primary3_candidate_validation.sh /path/to/Candidate.mlpackage [DEVICE_ID]

With DEVICE_ID the script runs the production baseline on the phone first,
then stages the candidate and runs the identical end-to-end benchmark.
The original model is restored even on failure.
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
OUTPUT_DIR="${TMPDIR:-/tmp}/mreader-v4-primary3-results"
DERIVED_BASELINE="${TMPDIR:-/tmp}/mreader-v4-primary3-baseline-derived"
DERIVED_CANDIDATE="${TMPDIR:-/tmp}/mreader-v4-primary3-candidate-derived"
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
rm -rf "$DERIVED_BASELINE" "$DERIVED_CANDIDATE"
rm -rf "$OUTPUT_DIR/V4Primary3BaselineDevice.xcresult" \
       "$OUTPUT_DIR/V4Primary3SimulatorGate.xcresult" \
       "$OUTPUT_DIR/V4Primary3CandidateDevice.xcresult"
ditto "$MODEL_DST" "$MODEL_BACKUP"

restore_model() {
  rm -rf "$MODEL_DST"
  ditto "$MODEL_BACKUP" "$MODEL_DST"
  rm -rf "$BACKUP_ROOT"
}
trap restore_model EXIT INT TERM

run_device_pipeline() {
  local derived="$1"
  local result_bundle="$2"
  local log="$3"
  xcodebuild \
    -project "$REPO_ROOT/mreader.xcodeproj" \
    -scheme mreaderDeviceBench \
    -configuration Debug \
    -destination "platform=iOS,id=$DEVICE_ID" \
    -derivedDataPath "$derived" \
    -only-testing:mreaderTests/V2B5DevicePerformanceTests/testEndToEndProviderPipelineAll \
    -resultBundlePath "$result_bundle" \
    test | tee "$log"
}

if [[ -n "$DEVICE_ID" ]]; then
  echo "==> Physical-device production baseline"
  run_device_pipeline \
    "$DERIVED_BASELINE" \
    "$OUTPUT_DIR/V4Primary3BaselineDevice.xcresult" \
    "$OUTPUT_DIR/device-baseline.log"
fi

echo "==> Candidate staged temporarily"
rm -rf "$MODEL_DST"
ditto "$CANDIDATE" "$MODEL_DST"
echo "    $CANDIDATE"

echo "==> Candidate simulator contract + regression gate"
xcodebuild \
  -project "$REPO_ROOT/mreader.xcodeproj" \
  -scheme mreader \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -derivedDataPath "$DERIVED_CANDIDATE" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  -only-testing:mreaderTests/MangaVisionRegressionGateTests \
  -resultBundlePath "$OUTPUT_DIR/V4Primary3SimulatorGate.xcresult" \
  test | tee "$OUTPUT_DIR/simulator-gate.log"

if [[ -n "$DEVICE_ID" ]]; then
  echo "==> Physical-device candidate full provider pipeline"
  run_device_pipeline \
    "$DERIVED_CANDIDATE" \
    "$OUTPUT_DIR/V4Primary3CandidateDevice.xcresult" \
    "$OUTPUT_DIR/device-candidate.log"

  echo "==> Baseline JSON records"
  grep 'V2B5_BENCHMARK_JSON=' "$OUTPUT_DIR/device-baseline.log" || true
  echo "==> Candidate JSON records"
  grep 'V2B5_BENCHMARK_JSON=' "$OUTPUT_DIR/device-candidate.log" || true
  echo "Compare baseline/candidate with their thermal state and stage-level p50/p95; do not compare total latency alone."
else
  echo "==> DEVICE_ID not supplied; physical-device A/B stage not run."
  echo "    Obtain it with: xcrun xctrace list devices"
fi

echo "==> Results: $OUTPUT_DIR"
echo "==> Original bundled model will now be restored."
