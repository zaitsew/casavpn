#!/usr/bin/env bash
#
# check.sh — the local gate. There is no CI: this is what runs before a push.
#
#   1. shellcheck on every shell script (by extension or shebang)
#   2. python3 -m py_compile on every Python file
#   3. every tests/test-*.sh (picked up by glob; add a file, no edits here)
#   4. node --test in monitor/ (skipped, loudly, when node is missing)
#   5. the PII scan: working tree, path names, every commit message and
#      identity, and every line ever added to history (tools/pii-scan.py)
#
# Exit non-zero if anything fails. scripts/install-hooks.sh wires this into
# git's pre-push hook.
#
# The private denylist for step 5 is read from $CASAVPN_PII_DENYLIST or
# ~/.config/casavpn/pii-denylist.txt. It lives outside the repository and is
# never printed. CASAVPN_REQUIRE_DENYLIST=1 turns "missing" into a failure.

set -u -o pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

failed=0
step() { printf '\n== %s\n' "$*"; }
bad()  { printf 'FAILED: %s\n' "$*" >&2; failed=$((failed + 1)); }

# Files git knows about or would add (respects .gitignore), without node_modules.
all_files() { git ls-files -co --exclude-standard 2>/dev/null | grep -v '^monitor/node_modules/' || true; }

step "shellcheck"
if ! command -v shellcheck >/dev/null 2>&1; then
  echo "shellcheck is not installed (macOS: brew install shellcheck, Debian: apt install shellcheck)" >&2
  exit 1
fi
shell_files=()
while IFS= read -r f; do
  [ -f "$f" ] || continue
  case "$f" in
    *.sh) shell_files+=("$f") ;;
    *.py|*.md|*.ts|*.json|*.conf|*.tmpl|*.service|*.timer|*.plist|*.txt|*.toml|*.example|*.env) ;;
    *) if head -n 1 "$f" 2>/dev/null | grep -Eq '^#!.*\b(ba)?sh\b'; then shell_files+=("$f"); fi ;;
  esac
done < <(all_files)
if [ "${#shell_files[@]}" -gt 0 ] && shellcheck "${shell_files[@]}"; then
  echo "ok: ${#shell_files[@]} shell files"
else
  bad "shellcheck"
fi

step "python compile"
py_files=()
while IFS= read -r f; do
  [ -f "$f" ] || continue
  case "$f" in
    *.py) py_files+=("$f") ;;
    *) if head -n 1 "$f" 2>/dev/null | grep -Eq '^#!.*python'; then py_files+=("$f"); fi ;;
  esac
done < <(all_files)
if [ "${#py_files[@]}" -gt 0 ]; then
  pycache="$(mktemp -d)"
  if PYTHONPYCACHEPREFIX="$pycache" python3 -m py_compile "${py_files[@]}"; then
    echo "ok: ${#py_files[@]} python files"
  else
    bad "py_compile"
  fi
  rm -rf "$pycache"
else
  echo "no python files"
fi

step "tests"
ran=0
for t in tests/test-*.sh; do
  [ -e "$t" ] || continue
  ran=$((ran + 1))
  printf -- '-- %s\n' "$t"
  bash "$t" || bad "$t"
done
echo "ran $ran test file(s)"

step "monitor (node --test)"
if command -v node >/dev/null 2>&1; then
  if (cd monitor && node --test src/*.test.ts); then
    echo "ok: monitor tests"
  else
    bad "monitor tests"
  fi
else
  echo "SKIPPED: node is not installed; the Cloudflare Worker state machine was not tested" >&2
fi

step "PII scan"
if python3 tools/pii-scan.py --history; then
  :
else
  bad "PII scan"
fi

printf '\n'
if [ "$failed" -eq 0 ]; then
  echo "check.sh: all checks passed"
  exit 0
fi
echo "check.sh: $failed check(s) FAILED" >&2
exit 1
