#!/usr/bin/env bash
#
# Regression test: a test that builds a throwaway git repository must not touch
# the repository named by an inherited GIT_DIR. A pre-push hook started from a
# linked worktree exports GIT_DIR; on 2026-10-16 test-pii-scan.sh, run that way,
# wrote its fixture user.email into the real .git/config.

set -u -o pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/casavpn-git-env-test.XXXXXXXX")"
trap 'rm -rf "$T"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

# a stand-in for "the real repository"
DECOY="$T/decoy"
git init -q -b main "$DECOY"
git -C "$DECOY" -c user.name=x -c user.email=x@example.com -c commit.gpgsign=false commit -q --allow-empty -m decoy
before_cfg="$(cat "$DECOY/.git/config")"
before_refs="$(git -C "$DECOY" for-each-ref --format='%(refname) %(objectname)')"
before_head="$(cat "$DECOY/.git/HEAD")"

if GIT_DIR="$DECOY/.git" bash "$ROOT/tests/test-pii-scan.sh" >"$T/out.txt" 2>&1; then
  ok
else
  bad "test-pii-scan.sh fails when GIT_DIR is inherited"
  tail -n 12 "$T/out.txt" | sed 's/^/    /'
fi

if [ "$(cat "$DECOY/.git/config")" = "$before_cfg" ]; then ok; else bad "the inherited GIT_DIR's config was changed"; fi
if [ "$(git -C "$DECOY" for-each-ref --format='%(refname) %(objectname)')" = "$before_refs" ]; then ok; else bad "the inherited GIT_DIR's refs were changed"; fi
if [ "$(cat "$DECOY/.git/HEAD")" = "$before_head" ]; then ok; else bad "the inherited GIT_DIR's HEAD was changed"; fi

printf 'git-env tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
