#!/usr/bin/env bash
#
# Tests for scripts/dns-diff.sh with a fake `dig` first on PATH. No network.
# Fixtures live in $FAKE_DIG_DIR/<server>/<fqdn>.<TYPE>, one answer line per
# record. A first line "STATUS:SERVFAIL" sets the response status.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/dns-diff.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
cat > "$WORK/bin/dig" <<'FAKE'
#!/usr/bin/env bash
server=""; short=0; pos=()
for a in "$@"; do
  case "$a" in
    @*) server="${a#@}" ;;
    +short) short=1 ;;
    +*) ;;
    *) pos+=("$a") ;;
  esac
done
type="${pos[0]}"; name="${pos[1]}"
if [ -n "$server" ]; then case " ${FAKE_DIG_FAIL:-} " in *" $server "*) exit 9 ;; esac; fi
status=NOERROR; body=""; flags="qr aa rd"; authority=""
f="$FAKE_DIG_DIR/$server/$name.$type"
# A <name>.<TYPE>.referral file turns the answer into a non-authoritative referral.
if [ -f "$f.referral" ]; then flags="qr rd"; authority="$(cat "$f.referral")"; fi
if [ -f "$f" ]; then
  first="$(head -n1 "$f")"
  if [[ "$first" == STATUS:* ]]; then status="${first#STATUS:}"; body="$(tail -n +2 "$f")"; else body="$(cat "$f")"; fi
fi
if [ "$short" = 1 ]; then
  printf '%s\n' "$body" | awk 'NF { sub(/^[^ \t]+[ \t]+[^ \t]+[ \t]+[^ \t]+[ \t]+[^ \t]+[ \t]*/, ""); print }'
else
  echo ";; ->>HEADER<<- opcode: QUERY, status: $status, id: 1"
  echo ";; flags: $flags; QUERY: 1, ANSWER: 0, AUTHORITY: 0, ADDITIONAL: 0"
  printf '%s\n' "$body"
  [ -z "$authority" ] || printf '%s\n' "$authority"
fi
exit 0
FAKE
chmod +x "$WORK/bin/dig"
export PATH="$WORK/bin:$PATH"
export FAKE_DIG_DIR="$WORK/zones"

cat > "$WORK/inventory.txt" <<'INV'
@               A MX NS TXT
vpn             A
dkim._domainkey CNAME
INV
export DNSDIFF_INVENTORY="$WORK/inventory.txt"
export DNSDIFF_DOMAIN="example.com"
export DNSDIFF_ALLOWLIST="$WORK/allowlist.txt"
cat > "$WORK/allowlist.txt" <<'AL'
vpn A nonempty
@ NS ns-only
AL
export DNSDIFF_KEY_RECORDS="$WORK/key-records.txt"
cat > "$WORK/key-records.txt" <<'KR'
@ A
@ MX
@ TXT
@ NS
www A
dkim._domainkey CNAME
vpn A
KR
export DNSDIFF_PARENT="parent.test parent2.test"
export DNSDIFF_RESOLVERS="r1.test r2.test"

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }

# rec <server> <name> <TYPE> <rdata>   (appends one answer line)
rec() {
  mkdir -p "$FAKE_DIG_DIR/$1"
  printf '%s. 300 IN %s %s\n' "$2" "$3" "$4" >> "$FAKE_DIG_DIR/$1/$2.$3"
}

# A complete healthy zone on <server>.
zone() {
  local s="$1" vpn="${2:-198.51.100.10}"
  rec "$s" example.com A 203.0.113.40
  rec "$s" example.com MX "10 mx1.mail.example.net."
  rec "$s" example.com MX "10 mx2.mail.example.net."
  rec "$s" example.com TXT '"v=spf1 include:mail.example.net ~all"'
  rec "$s" example.com TXT '"verification=abcdef123456"'
  rec "$s" example.com NS "${NS_VALUE:-ns1.example.net.}"
  rec "$s" vpn.example.com A "$vpn"
  rec "$s" dkim._domainkey.example.com CNAME "dkim.example.com.at.mail.example.net."
}

reset() { rm -rf "$FAKE_DIG_DIR"; unset FAKE_DIG_FAIL; mkdir -p "$FAKE_DIG_DIR"; }
no_ds() {
  local p
  for p in parent.test parent2.test; do mkdir -p "$FAKE_DIG_DIR/$p"; : > "$FAKE_DIG_DIR/$p/example.com.DS"; done
}
with_ds() { rec parent.test example.com DS "12345 8 2 0000000000000000000000000000000000000000000000000000000000000000"; }

run() { OUT="$("$SCRIPT" "$@" 2>&1)"; RC=$?; }
expect() { # <name> <rc> [grep pattern]
  if [ "$RC" -ne "$2" ]; then bad "$1 (rc=$RC, want $2)"; printf '%s\n' "$OUT" | sed 's/^/       /'; return; fi
  if [ -n "${3:-}" ] && ! printf '%s\n' "$OUT" | grep -q -- "$3"; then
    bad "$1 (output lacks: $3)"; printf '%s\n' "$OUT" | sed 's/^/       /'; return
  fi
  ok "$1"
}

echo "dns-diff.sh"

# 1. identical zones, no DS: clean
reset; zone old; zone new; no_ds
run old new
expect "equal zones are clean" 0 "CLEAN"

# 2. a record missing on the new side: difference, exit 1, names the record
reset; zone old; zone new; no_ds
rm "$FAKE_DIG_DIR/new/example.com.MX"
run old new
expect "missing MX is a difference" 1 "DIFFERENCES"
if printf '%s\n' "$OUT" | grep -q "@ MX"; then ok "difference names the record"; else bad "difference names the record"; fi

# 3. a changed value (DKIM target) is a difference
reset; zone old; zone new; no_ds
rm "$FAKE_DIG_DIR/new/dkim._domainkey.example.com.CNAME"
rec new dkim._domainkey.example.com CNAME "other.example.com."
run old new
expect "changed CNAME is a difference" 1 "dkim._domainkey"

# 4. case, trailing dot and TXT chunking are not differences
reset; zone old; zone new; no_ds
rm "$FAKE_DIG_DIR/new/example.com.TXT" "$FAKE_DIG_DIR/new/example.com.MX"
rec new example.com TXT '"v=spf1 include:mail.example.net" " ~all"'
rec new example.com TXT '"verification=abcdef123456"'
rec new example.com MX "10 MX1.mail.example.net"
rec new example.com MX "10 mx2.mail.example.net."
run old new
expect "formatting differences are normalised away" 0 "CLEAN"

# 5. allow-list: different vpn address and different apex NS are fine
reset; zone old; NS_VALUE=ns1.cloudflare.example. zone new 203.0.113.9; no_ds
run old new
expect "vpn address and apex NS changes are allow-listed" 0 "allowed"

# 6. allow-list nonempty: vpn missing on the new side is not fine
reset; zone old; zone new; no_ds
rm "$FAKE_DIG_DIR/new/vpn.example.com.A"
run old new
expect "vpn missing on new side is a difference" 1 "DIFFERENCES"

# 7. DS present: blocker, loud, exit 2
reset; zone old; zone new; with_ds
run old new
expect "DS at the parent blocks the cutover" 2 "DNSSEC IS ON"

# 8. DS present but explicitly allowed
run old new --allow-ds
expect "--allow-ds lets a clean diff through" 0 "CLEAN"

# 9. DS present and differences: still exit 2 (the blocker wins), diffs shown
reset; zone old; zone new; with_ds
rm "$FAKE_DIG_DIR/new/example.com.A"
run old new
expect "DS blocker wins over differences" 2 "DIFFERENCES"

# 10. parent unreachable: cannot confirm DNSSEC state
reset; zone old; zone new; no_ds
export FAKE_DIG_FAIL=parent.test
run old new
expect "unknown DS state is an error" 3 "Could not get a clean NOERROR"
unset FAKE_DIG_FAIL

# 11. a nameserver that does not answer is a difference, never a pass
reset; zone old; zone new; no_ds
export FAKE_DIG_FAIL=new
run old new
expect "unreachable nameserver is a query error" 3 "query error"
unset FAKE_DIG_FAIL

# 11b. both nameservers time out: identical errors must not look like a match
reset; zone old; zone new; no_ds
export FAKE_DIG_FAIL="old new"
run old new
expect "both sides failing is an error, never CLEAN" 3 "NOT CLEAN"
if printf '%s\n' "$OUT" | grep -q "^CLEAN"; then bad "no CLEAN line when both sides fail"; else ok "no CLEAN line when both sides fail"; fi
unset FAKE_DIG_FAIL

# 11c. the parent answers SERVFAIL (empty answer): that is not "DS absent"
reset; zone old; zone new; no_ds
printf 'STATUS:SERVFAIL\n' > "$FAKE_DIG_DIR/parent.test/example.com.DS"
run old new
expect "parent SERVFAIL is not proof the DS is absent" 3 "Could not get a clean NOERROR"

# 11d. REFUSED from the second parent server, first says absent
reset; zone old; zone new; no_ds
printf 'STATUS:REFUSED\n' > "$FAKE_DIG_DIR/parent2.test/example.com.DS"
run old new
expect "every parent server must answer NOERROR" 3 "Could not get a clean NOERROR"

# 11e. a DS visible only at the second parent server still blocks
reset; zone old; zone new; no_ds
rec parent2.test example.com DS "12345 8 2 0000000000000000000000000000000000000000000000000000000000000000"
run old new
expect "DS seen on any parent server blocks" 2 "DNSSEC IS ON"

# 11f. a timed-out parent server is unknown, not absent
reset; zone old; zone new; no_ds
export FAKE_DIG_FAIL=parent2.test
run old new
expect "parent timeout is not proof the DS is absent" 3 "Could not get a clean NOERROR"
unset FAKE_DIG_FAIL

# 12. usage
run
expect "no arguments prints usage" 3

# 12b. --domain overrides the environment
reset; zone old; zone new; no_ds
run old new --domain example.com
expect "--domain is accepted" 0 "CLEAN"
run old new --domain
expect "--domain without a value is a usage error" 3 "needs a value"

# 12c. the zone defaults to the registered domain of CASAVPN_DOMAIN
reset; zone old; zone new; no_ds
OUT="$(env -u DNSDIFF_DOMAIN CASAVPN_DOMAIN=vpn.example.com CASAVPN_ENV=/nonexistent "$SCRIPT" old new 2>&1)"; RC=$?
expect "zone defaults to the last two labels of CASAVPN_DOMAIN" 0 "Comparing example.com"
OUT="$(env -u DNSDIFF_DOMAIN -u CASAVPN_DOMAIN CASAVPN_ENV=/nonexistent "$SCRIPT" old new 2>&1)"; RC=$?
expect "no zone anywhere is an error that says what to do" 3 "Pass --domain"

# 12d. the parent servers are found by walking down from the root
reset; zone old; zone new
mkdir -p "$FAKE_DIG_DIR/root1.test" "$FAKE_DIG_DIR/tld1.test" "$FAKE_DIG_DIR/tld2.test"
printf '. 300 IN NS root1.test.\n' > "$FAKE_DIG_DIR/..NS"
printf 'com. 172800 IN NS tld1.test.\ncom. 172800 IN NS tld2.test.\n' > "$FAKE_DIG_DIR/root1.test/example.com.DS.referral"
: > "$FAKE_DIG_DIR/root1.test/example.com.DS"
for p in tld1.test tld2.test; do : > "$FAKE_DIG_DIR/$p/example.com.DS"; done
OUT="$(env -u DNSDIFF_PARENT "$SCRIPT" old new 2>&1)"; RC=$?
expect "parent servers are found by walking from the root" 0 "tld1.test tld2.test"

# 12e. a zone below a separately delegated suffix: the TLD only refers. The old
# behaviour read that referral as "DS absent"; the DS lives one level further down.
reset; zone old; zone new
mkdir -p "$FAKE_DIG_DIR/root1.test" "$FAKE_DIG_DIR/uk1.test" "$FAKE_DIG_DIR/couk1.test"
printf '. 300 IN NS root1.test.\n' > "$FAKE_DIG_DIR/..NS"
: > "$FAKE_DIG_DIR/root1.test/example.co.uk.DS"
printf 'uk. 172800 IN NS uk1.test.\n' > "$FAKE_DIG_DIR/root1.test/example.co.uk.DS.referral"
: > "$FAKE_DIG_DIR/uk1.test/example.co.uk.DS"
printf 'co.uk. 172800 IN NS couk1.test.\n' > "$FAKE_DIG_DIR/uk1.test/example.co.uk.DS.referral"
printf 'example.co.uk. 3600 IN DS 12345 8 2 0000000000000000000000000000000000000000000000000000000000000000\n' > "$FAKE_DIG_DIR/couk1.test/example.co.uk.DS"
OUT="$(env -u DNSDIFF_PARENT "$SCRIPT" old new --domain example.co.uk 2>&1)"; RC=$?
expect "a DS below a delegated suffix is found, not mistaken for absent" 2 "DNSSEC IS ON"
if printf '%s\n' "$OUT" | grep -q "couk1.test"; then ok "  ...and names the real parent server"; else bad "  ...and names the real parent server"; fi
# ...and the same walk with no DS at the real parent is clean
: > "$FAKE_DIG_DIR/couk1.test/example.co.uk.DS"
OUT="$(env -u DNSDIFF_PARENT "$SCRIPT" old new --domain example.co.uk 2>&1)"; RC=$?
expect "the walk ends at the real parent; no DS there is absent" 0 "couk1.test"

# 12f. explicit parents that only REFER are unknown, never absent
reset; zone old; zone new; no_ds
printf 'com. 172800 IN NS tld1.test.\n' > "$FAKE_DIG_DIR/parent.test/example.com.DS.referral"
run old new
expect "a referral from a configured parent is not proof of absence" 3 "Could not get a clean"

# 12g. a referral loop ends, with an error
reset; zone old; zone new
mkdir -p "$FAKE_DIG_DIR/root1.test" "$FAKE_DIG_DIR/loop1.test"
printf '. 300 IN NS root1.test.\n' > "$FAKE_DIG_DIR/..NS"
printf 'com. 172800 IN NS loop1.test.\n' > "$FAKE_DIG_DIR/root1.test/example.com.DS.referral"
printf 'com. 172800 IN NS root1.test.\n' > "$FAKE_DIG_DIR/loop1.test/example.com.DS.referral"
OUT="$(env -u DNSDIFF_PARENT "$SCRIPT" old new 2>&1)"; RC=$?
expect "a referral loop is an error, not a pass" 3 "walking down from the root"

echo "dns-diff.sh --resolvers"

# 13. resolvers agree with the reference
reset; zone ref; zone r1.test; zone r2.test; no_ds
run --resolvers ref
expect "agreeing resolvers are clean" 0 "CLEAN"

# 14. a resolver still serving the old vpn address is fine (allow-listed)
reset; zone ref; zone r1.test; zone r2.test 198.51.100.77; no_ds
run --resolvers ref
expect "stale vpn address on a resolver is allow-listed" 0 "CLEAN"

# 14b. a resolver that SERVFAILs is not fine
reset; zone ref; zone r1.test; zone r2.test; no_ds
printf 'STATUS:SERVFAIL\n' > "$FAKE_DIG_DIR/r1.test/example.com.MX"
run --resolvers ref
expect "SERVFAIL from a resolver is a query error" 3 "ERROR(SERVFAIL)"

# 14c. a resolver that times out is an error, even if the reference also fails
reset; zone ref; zone r1.test; zone r2.test; no_ds
export FAKE_DIG_FAIL="ref r1.test"
run --resolvers ref
expect "resolver and reference failing alike is not CLEAN" 3 "NOT CLEAN"
unset FAKE_DIG_FAIL

# 14d. resolver mode also refuses to call an unanswered DS query clean
reset; zone ref; zone r1.test; zone r2.test; no_ds
printf 'STATUS:SERVFAIL\n' > "$FAKE_DIG_DIR/parent.test/example.com.DS"
run --resolvers ref
expect "resolver mode: unanswered DS query is an error" 3 "NOT CLEAN"

# 15. default reference is the parent's delegation
reset; zone ref; zone r1.test; zone r2.test; no_ds
rec parent.test example.com NS "ref."
run --resolvers
expect "reference defaults to the delegation" 0 "Reference nameserver: ref"

# 16. stale DS is reported (informational) in resolver mode
reset; zone ref; zone r1.test; zone r2.test; with_ds
run --resolvers ref
expect "resolver mode reports a DS" 0 "DS present"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
