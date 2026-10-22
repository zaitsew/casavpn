#!/usr/bin/env bash
#
# Offline tests for `scripts/store.py lint`: the App Store text rules. No network and no
# credentials: lint never loads ~/ops/bin/testflight.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/store.py"
T="$(mktemp -d "${TMPDIR:-/tmp}/casavpn-store-test.XXXXXXXX")"
trap 'rm -rf "${T:?}"' EXIT

command -v python3 >/dev/null 2>&1 || { echo "python3 missing, skipping store tests"; exit 0; }

pass=0; fail=0
OUT=""; RC=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; printf '%s\n' "$OUT" | tail -n 8 | sed 's/^/       /'; }
rc_is() { if [ "$RC" -eq "$2" ]; then ok "$1"; else bad "$1 (rc=$RC, want $2)"; fi; }
out_has() { if grep -qF -- "$2" <<<"$OUT"; then ok "$1"; else bad "$1 (output lacks: $2)"; fi; }

lint() { OUT="$(CASAVPN_STORE_DIR="$1" python3 -I "$SCRIPT" lint 2>&1)"; RC=$?; }
fresh() { rm -rf "$T/store"; cp -R "$ROOT/app/store" "$T/store"; }
MD="$T/store/metadata/en-US"

echo "-- the shipped files"
lint "$ROOT/app/store"; rc_is "app/store passes lint" 0

echo "-- limits and rules"
fresh; printf 'A subtitle that is far too long to fit\n' >"$MD/subtitle.txt"
lint "$T/store"; rc_is "a 31+ character subtitle fails" 1; out_has "says which file" "subtitle.txt"

fresh; printf 'vpn, server, admin\n' >"$MD/keywords.txt"
lint "$T/store"; rc_is "spaces after commas in keywords fail" 1

fresh; printf 'Manage servers with Xray\n' >"$MD/subtitle.txt"
lint "$T/store"; rc_is "Xray in the subtitle fails" 1; out_has "names the rule" "third-party"

fresh; printf '%s\nWorks with 3x-ui and 3x-ui again.\n' "$(cat "$MD/description.txt")" >"$MD/description.txt"
lint "$T/store"; rc_is "3x-ui twice in the description fails" 1

fresh; printf '%s\nPowered by Claude.\n' "$(cat "$MD/description.txt")" >"$MD/description.txt"
lint "$T/store"; rc_is "a model provider in the description fails" 1; out_has "names the rule" "model provider"

fresh; rm "$MD/privacy_url.txt"
lint "$T/store"; rc_is "a missing file fails" 1

fresh; rm "$T/store/review_notes.txt"
lint "$T/store"; rc_is "missing review notes fail" 1

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
