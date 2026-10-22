#!/usr/bin/env bash
# Generates CasaVPN.xcodeproj from project.yml. The project is not committed.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is not installed (brew install xcodegen)" >&2
  exit 1
fi

if [ ! -f Config/Local.xcconfig ]; then
  cp Config/Local.xcconfig.example Config/Local.xcconfig
  echo "created Config/Local.xcconfig from the example; set your bundle id and team in it" >&2
fi

xcodegen generate --spec project.yml
