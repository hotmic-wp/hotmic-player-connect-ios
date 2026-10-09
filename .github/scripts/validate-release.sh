#!/bin/bash
set -euo pipefail
bash .github/scripts/check-partner-docs.sh
mkdir -p .validation
# Surface useful build diagnostics if a redirected command fails.
trap 'result=$?; if (( result != 0 )); then tail -n 80 .validation/*.log; fi' EXIT
project=Examples/HotMicExamples.xcodeproj
shared=(-project "$project" -scheme ReleaseChecks -configuration Debug -derivedDataPath .validation/DerivedData -clonedSourcePackagesDirPath .build CODE_SIGNING_ALLOWED=NO SWIFT_STRICT_CONCURRENCY=complete)
xcodebuild build "${shared[@]}" -destination 'generic/platform=iOS Simulator' > .validation/build-simulator.log 2>&1
xcodebuild build "${shared[@]}" -destination 'generic/platform=iOS' > .validation/build-device.log 2>&1
xcodebuild docbuild -scheme HotMicPlayerCore -destination 'generic/platform=iOS Simulator' -derivedDataPath .validation/DerivedData -clonedSourcePackagesDirPath .build CODE_SIGNING_ALLOWED=NO SWIFT_STRICT_CONCURRENCY=complete OTHER_DOCC_FLAGS='--warnings-as-errors --analyze' > .validation/docbuild.log 2>&1
# The only full unit-suite invocation, after all builds and documentation.
xcodebuild test "${shared[@]}" -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -parallel-testing-enabled NO -resultBundlePath .validation/UnitTests.xcresult > .validation/tests.log 2>&1
