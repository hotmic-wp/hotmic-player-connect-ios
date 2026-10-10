#!/bin/bash
# Partner docs and privacy terms, one device library compile, then DocC.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
source .github/scripts/ci-common.sh
validation_dir="${VALIDATION_DIR:-.bench/checks}"
mkdir -p "$validation_dir"
derived="$validation_dir/DerivedData"
started=$SECONDS
job_name=checks
budget_total=540
budget_partner_docs=60
budget_device=240
budget_docbuild=240
run_step partner-docs "$budget_partner_docs" bash .github/scripts/check-partner-docs.sh
run_step device-libraries "$budget_device" xcodebuild build -scheme HotMicPlayerConnect-Package \
  -destination 'generic/platform=iOS' -derivedDataPath "$derived" \
  ARCHS=arm64 SWIFT_STRICT_CONCURRENCY=complete "${speed_flags[@]}"
run_step docbuild "$budget_docbuild" xcodebuild docbuild -scheme HotMicPlayerConnect-Package \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$derived" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES SWIFT_STRICT_CONCURRENCY=complete "${speed_flags[@]}" \
  OTHER_DOCC_FLAGS='--warnings-as-errors --analyze'
enforce_total
