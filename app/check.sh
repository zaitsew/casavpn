#!/usr/bin/env bash
# The app's gate: generate the project, run the CasaKit unit tests, build the app.
# No simulator is needed: the tests run on macOS and the build targets the generic simulator SDK.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

./generate.sh

echo "== CasaKit tests"
swift test --package-path CasaKit

echo "== app build"
xcodebuild -project CasaVPN.xcodeproj -scheme CasaVPN \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -n 40 | tee /dev/stderr | grep -q "BUILD SUCCEEDED"

echo "ok: app/check.sh"
