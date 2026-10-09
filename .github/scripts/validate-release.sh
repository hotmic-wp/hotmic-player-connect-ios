#!/bin/bash
set -euo pipefail
bash .github/scripts/check-partner-docs.sh
mkdir -p .validation
# Surface useful build diagnostics if a redirected command fails.
created_simulator=0
simulator_id="${SIMULATOR_UDID:-}"
cleanup() {
  result=$?
  if (( result != 0 )); then tail -n 80 .validation/*.log; fi
  if [ "$created_simulator" = 1 ]; then xcrun simctl delete "$simulator_id"; fi
}
trap cleanup EXIT
project=Examples/HotMicExamples.xcodeproj
shared=(-project "$project" -scheme ReleaseChecks -configuration Debug -derivedDataPath .validation/DerivedData -clonedSourcePackagesDirPath .build CODE_SIGNING_ALLOWED=NO SWIFT_STRICT_CONCURRENCY=complete)
xcodebuild build "${shared[@]}" -destination 'generic/platform=iOS Simulator' > .validation/build-simulator.log 2>&1
xcodebuild build "${shared[@]}" -destination 'generic/platform=iOS' > .validation/build-device.log 2>&1
xcodebuild docbuild -scheme HotMicPlayerCore-Package -destination 'generic/platform=iOS Simulator' -derivedDataPath .validation/DerivedData -clonedSourcePackagesDirPath .build CODE_SIGNING_ALLOWED=NO SWIFT_STRICT_CONCURRENCY=complete OTHER_DOCC_FLAGS='--warnings-as-errors --analyze' > .validation/docbuild.log 2>&1
if [ "${BUILD_ONLY:-0}" = 1 ]; then exit 0; fi
if [ -z "$simulator_id" ]; then
  selection=$(xcrun simctl list -j | python3 .github/scripts/select-simulator.py)
  runtime=${selection%%$'\n'*}
  simulator_type=${selection#*$'\n'}
  simulator_id=$(xcrun simctl create HotMic-core-ci "$simulator_type" "$runtime")
  created_simulator=1
  xcrun simctl boot "$simulator_id"
  xcrun simctl bootstatus "$simulator_id" -b
fi
# The only full unit-suite invocation, after all builds and documentation.
xcodebuild test "${shared[@]}" -destination "platform=iOS Simulator,id=$simulator_id" -parallel-testing-enabled NO -resultBundlePath .validation/UnitTests.xcresult > .validation/tests.log 2>&1
