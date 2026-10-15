#!/usr/bin/env bash
#
# Tests for tools/pii-scan.py.
#
# Every PII-shaped fixture is assembled at run time inside a throwaway git
# repository, so this file itself never contains a value the scanner would
# flag (and the real repository's history stays clean). The private denylist
# used here is synthetic; the developer's real one is never read.

set -u -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCAN="$ROOT/tools/pii-scan.py"
T="$(mktemp -d "${TMPDIR:-/tmp}/casavpn-pii-test.XXXXXXXX")"
trap 'rm -rf "$T"' EXIT

PASS=0
FAIL=0
OUT=""
RC=0
ok()   { PASS=$((PASS + 1)); }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; printf '%s\n' "$OUT" | tail -n 12 | sed 's/^/    /'; }
assert() { local d="$1"; shift; if "$@"; then ok; else bad "$d"; fi; }
rc_is()    { [ "$RC" -eq "$1" ]; }
out_has()  { grep -q -- "$1" <<<"$OUT"; }
out_lacks(){ ! grep -q -- "$1" <<<"$OUT"; }

# --- a throwaway repository ---------------------------------------------------
REPO="$T/repo"
mkdir -p "$REPO/tools"
cp "$SCAN" "$REPO/tools/pii-scan.py"
cp "$ROOT/tools/pii-allow.txt" "$REPO/tools/pii-allow.txt"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.name "CasaVPN contributors"
git -C "$REPO" config user.email "alice@example.com"
git -C "$REPO" config commit.gpgsign false

CANARY="zzcanaryzz"                       # the synthetic private word
DENY="$T/denylist.txt"
printf '# synthetic denylist for the test\n%s\n^never-this-host\\.example$\n' "$CANARY" >"$DENY"
export CASAVPN_PII_DENYLIST="$DENY"

scan() { OUT=$(cd "$REPO" && python3 tools/pii-scan.py "$@" 2>&1) && RC=0 || RC=$?; }
commit() { git -C "$REPO" add -A && git -C "$REPO" commit -q -m "${1:-test commit}"; }
reset_repo() {
  rm -rf "$REPO/fixtures"; mkdir -p "$REPO/fixtures"
  git -C "$REPO" rm -rq --cached fixtures 2>/dev/null || true
}
put() { printf '%s\n' "$2" >"$REPO/fixtures/$1"; }   # put <name> <text>

# Fragments joined at run time (so no flaggable literal exists in this file).
J() { local IFS=; printf '%s' "$*"; }
rand_chars() { python3 -c "import secrets,string,sys; a=string.ascii_letters+string.digits; print(''.join(secrets.choice(a) for _ in range(int(sys.argv[1]))))" "$1"; }
mixed() { # a token of length $1 that certainly has lower, upper and digit
  local n="$1" body
  body="$(rand_chars $((n - 3)))"; printf '%s' "aZ7${body}"
}

# --- 0. a clean tree passes ------------------------------------------------------
reset_repo
put ok.md "Connect to vpn.example.com from 203.0.113.9, mail alice@example.com, v6 2001:db8::1, loopback 127.0.0.1 and ::1."
put ok2.md "uuid 00000000-0000-0000-0000-000000000000 and 11111111-1111-1111-1111-111111111111; time 03:30:00; ntfy topic https://ntfy.sh/casavpn-CHANGE-ME"
put ok3.md "Private ranges as text: 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10"
commit "add clean fixtures"
scan
assert "clean tree: exit 0" rc_is 0
assert "clean tree: says clean" out_has "clean"

# --- 1. each generic rule fires --------------------------------------------------
expect_finding() { # <rule> <text> [filename]
  reset_repo; put "${3:-f.txt}" "$2"; commit "fixture for $1"
  scan
  assert "rule $1: exit 1" rc_is 1
  assert "rule $1: reported" out_has "PII\\[$1\\]"
}
expect_finding ipv4 "router at $(J 192 .168 .1 .1)"
expect_finding ipv4 "public host $(J 79 .12 .34 .56)"
expect_finding ipv6 "address $(J 2a02 :9999 :: 5)"
expect_finding email "write to $(J bob @ gmail .com)"
expect_finding uuid "id $(python3 -c 'import uuid; print(uuid.uuid4())')"
expect_finding age-secret "$(J AGE-SECRET-KEY-1 "$(python3 -c 'print("QPZRY9X8GF2TVDW0S3JN54KHCE6MUA7L"[:30].upper())')")"
expect_finding private-key "$(J '-----BEGIN ' 'OPENSSH PRIVATE KEY' '-----')"
expect_finding token "CF_API_TOKEN=$(mixed 40)"
expect_finding token "pbk=$(mixed 43)"
expect_finding hex32 "zone $(python3 -c 'import secrets; print(secrets.token_hex(16))')"
expect_finding ntfy-topic "curl https://ntfy.sh/$(J my team- 4f9a1c)"
expect_finding age-pubkey "recipient $(J age1 "$(python3 -c 'print("q"*58)')")"

# generic rules apply to file NAMES too, not only the private denylist
reset_repo; put "$(J bob @ gmail .com).txt" "harmless body"; commit "named after an e-mail"
scan
assert "an e-mail address in a file name is flagged" rc_is 1
assert "  ...as a path-name finding" out_has "PII\\[email\\].*path name"
reset_repo; put "host-$(J 79 .12 .34 .56).txt" "harmless body"; commit "named after an address"
scan
assert "an IP address in a file name is flagged" rc_is 1

# --- 2. things that look similar but are fine ---------------------------------------
reset_repo
put fine.txt "versions 3.10.2 26.7.28 and 1.8.0; a sha256 $(python3 -c 'import hashlib; print(hashlib.sha256(b"x").hexdigest())'); 40 hex $(python3 -c 'import hashlib; print(hashlib.sha1(b"x").hexdigest())')"
commit "lookalikes"
scan
assert "version strings and hashes are not flagged" rc_is 0

# --- 3. the allow-list can exempt one rule in one file ----------------------------------
reset_repo
put boundary.sh "classify $(J 100 .64 .0 .1) as cgnat"
printf 'skip-rule ipv4 fixtures/boundary.sh\n' >>"$REPO/tools/pii-allow.txt"
commit "boundary file"
scan
assert "skip-rule ipv4 for one path: clean" rc_is 0
put other.sh "same $(J 100 .64 .0 .1)"
commit "other file"
scan
assert "skip-rule does not cover other paths" rc_is 1
cp "$ROOT/tools/pii-allow.txt" "$REPO/tools/pii-allow.txt"

# --- 4. private denylist -----------------------------------------------------------------
reset_repo
put d.txt "hello from $CANARY"
commit "denylisted word"
scan
assert "denylist hit: exit 1" rc_is 1
assert "denylist hit: reported by entry number" out_has "denylist entry #1"
assert "denylist hit: names the file and line" out_has "fixtures/d.txt:1"
assert "denylist hit: the matched text is NOT printed" out_lacks "$CANARY"
assert "denylist hit: the pattern is NOT printed" out_lacks "never-this-host"

reset_repo
put e.txt "never-this-host.example"
commit "second entry"
scan
assert "denylist entry #2 matches (ERE)" out_has "denylist entry #2"

reset_repo
put f.txt "$(printf '%s' "$CANARY" | tr '[:lower:]' '[:upper:]') in capitals"
commit "case"
scan
assert "denylist is case-insensitive" out_has "denylist entry #1"

# a path name counts
reset_repo
put "$CANARY.txt" "innocent body"
commit "path name"
scan
assert "denylist matches file names" out_has "path name"

# commit message and identity
reset_repo
put g.txt "clean"
commit "release notes for $CANARY"
scan
assert "denylist hit in a commit message" out_has "commit "
assert "  ...and the commit message text is not printed" out_lacks "release notes for"

reset_repo
put g.txt "clean again"
git -C "$REPO" add -A
GIT_AUTHOR_NAME="Mr $CANARY" git -C "$REPO" commit -q -m "innocent message"
scan
assert "denylist hit in an author identity" rc_is 1
reset_repo
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "cleanup" || true

# --- 5. history: a file committed and then deleted is still found -----------------------------
# (start from a fresh repository so earlier bad commits do not interfere)
rm -rf "$REPO/.git"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.name "CasaVPN contributors"
git -C "$REPO" config user.email "alice@example.com"
git -C "$REPO" config commit.gpgsign false
reset_repo
put keep.txt "fine"
commit "initial"
put oops.txt "router $(J 192 .168 .7 .7)"
commit "oops"
rm -f "$REPO/fixtures/oops.txt"
commit "remove oops"
scan
assert "tree is clean once the file is deleted" rc_is 0
scan --history
assert "--history still finds the deleted file's content" rc_is 1
assert "  ...and names the commit" out_has "history "

# a deleted file's NAME stays in history too
rm -rf "$REPO/.git"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.name "CasaVPN contributors"
git -C "$REPO" config user.email "alice@example.com"
git -C "$REPO" config commit.gpgsign false
reset_repo
put keep.txt "fine"; commit "initial"
put "$(J bob @ gmail .com).txt" "x"; commit "add a file named after an e-mail"
rm -f "$REPO/fixtures/"*gmail*; commit "remove it"
scan
assert "tree is clean once the oddly named file is deleted" rc_is 0
scan --history
assert "--history finds a deleted file's name" rc_is 1
assert "  ...as a history path" out_has "history path"

# a merge commit: a line added only in the merge resolution, deleted afterwards
rm -rf "$REPO/.git"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.name "CasaVPN contributors"
git -C "$REPO" config user.email "alice@example.com"
git -C "$REPO" config commit.gpgsign false
reset_repo
put base.txt "base"; commit "base"
git -C "$REPO" checkout -q -b side
put side.txt "side"; commit "side work"
git -C "$REPO" checkout -q main
put main.txt "main"; commit "main work"
git -C "$REPO" merge -q --no-ff --no-commit side >/dev/null 2>&1
put evil.txt "router $(J 192 .168 .9 .9)"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m "merge side"
git -C "$REPO" rm -q -f fixtures/evil.txt && git -C "$REPO" commit -q -m "drop the file again"
scan
assert "merge test: the tree is clean" rc_is 0
scan --history
assert "--history sees a line added only inside a merge commit" rc_is 1
assert "  ...as an ipv4 finding" out_has "PII\\[ipv4\\]"

# --- 6. identities and the author-email literal -----------------------------------------------------
rm -rf "$REPO/.git"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.name "CasaVPN contributors"
git -C "$REPO" config user.email "$(J 1234 + somebody @ gmail .com)"
git -C "$REPO" config commit.gpgsign false
reset_repo
put x.txt "fine"
commit "initial"
scan
assert "a personal author e-mail is flagged" out_has "PII\\[email\\]"
git -C "$REPO" config user.email "alice@example.com"
git -C "$REPO" commit -q --amend --reset-author --no-edit
scan
assert "an example.com author is fine" rc_is 0

# the literal from the allow-list is removed before the denylist runs
printf 'literal %s@users.noreply.github.com\n' "9${CANARY}" >>"$REPO/tools/pii-allow.txt"
git -C "$REPO" config user.email "9${CANARY}@users.noreply.github.com"
git -C "$REPO" commit -q --amend --reset-author --no-edit --allow-empty
scan
assert "an allow-listed literal is exempt from the denylist" rc_is 0
cp "$ROOT/tools/pii-allow.txt" "$REPO/tools/pii-allow.txt"
git -C "$REPO" config user.email "alice@example.com"
git -C "$REPO" commit -q --amend --reset-author --no-edit --allow-empty

# --- 7. a missing denylist warns loudly but does not fail ----------------------------------------------
scan_nodeny() { OUT=$(cd "$REPO" && env CASAVPN_PII_DENYLIST="$T/does-not-exist" HOME="$T/nohome" python3 tools/pii-scan.py 2>&1) && RC=0 || RC=$?; }
scan_nodeny
assert "no denylist: still exit 0 on a clean repo" rc_is 0
assert "no denylist: warns loudly" out_has "WARNING: no private denylist"
OUT=$(cd "$REPO" && env CASAVPN_PII_DENYLIST="$T/does-not-exist" HOME="$T/nohome" CASAVPN_REQUIRE_DENYLIST=1 python3 tools/pii-scan.py 2>&1) && RC=0 || RC=$?
assert "CASAVPN_REQUIRE_DENYLIST=1 makes a missing denylist fatal" rc_is 2

# --- 8. an invalid denylist regex is a setup error, not a silent pass ------------------------------------------
printf '(unclosed\n' >"$T/bad-deny.txt"
OUT=$(cd "$REPO" && env CASAVPN_PII_DENYLIST="$T/bad-deny.txt" python3 tools/pii-scan.py 2>&1) && RC=0 || RC=$?
assert "invalid denylist regex: not exit 0" test "$RC" -ne 0

echo
echo "pii-scan tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
