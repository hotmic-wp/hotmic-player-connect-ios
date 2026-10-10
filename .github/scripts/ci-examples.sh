#!/bin/bash
# Simulator compiles of the example apps. No tests and no simulator boot.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
source .github/scripts/ci-common.sh
validation_dir="${VALIDATION_DIR:-.bench/examples}"
mkdir -p "$validation_dir"
derived="$validation_dir/DerivedData"
started=$SECONDS
job_name=examples
budget_total=540
# The first app compiles the shared libraries; the later app reuses DerivedData.
budget_streams=420
budget_engagement=240
build_app() {
  local scheme="$1"
  xcodebuild build -project Examples/HotMicExamples.xcodeproj -scheme "$scheme" \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$derived" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES SWIFT_STRICT_CONCURRENCY=complete "${speed_flags[@]}"
}
run_step Streams-simulator "$budget_streams" build_app Streams
run_step StreamsAndEngagement-simulator "$budget_engagement" build_app StreamsAndEngagement
enforce_total
