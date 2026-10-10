#!/bin/bash
# The release checks must use the pinned toolchain on every runner.
set -euo pipefail
if [[ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
  echo "::error::Xcode 26.6 is required but is missing at $DEVELOPER_DIR. Install it on the runner before running the checks."
  exit 1
fi
version=$(xcodebuild -version)
if [[ "${version%%$'\n'*}" != 'Xcode 26.6' ]]; then
  echo "::error::Expected Xcode 26.6 at $DEVELOPER_DIR; found $version."
  exit 1
fi
printf '%s\n' "$version"
