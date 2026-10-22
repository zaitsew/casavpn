#!/usr/bin/env bash
#
# Offline tests for scripts/lib/casavpn-notify.sh, the sender behind casavpn-ddns
# and casavpn-alerts. A stub `curl` on PATH records what it was given and answers
# from files, so nothing touches the network.

# shellcheck disable=SC2016

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/scripts/lib/casavpn-notify.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/casavpn-notify-test.XXXXXXXX")"
trap 'rm -rf "${T:?}"' EXIT

command -v jq >/dev/null 2>&1 || { echo "jq missing, skipping notify tests"; exit 0; }

pass=0; fail=0
OUT=""; RC=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; printf '%s\n' "$OUT" | tail -n 8 | sed 's/^/       /'; }
rc_is() { if [ "$RC" -eq "$2" ]; then ok "$1"; else bad "$1 (rc=$RC, want $2)"; fi; }
has()   { if grep -q -- "$2" "$3" 2>/dev/null; then ok "$1"; else bad "$1 (no '$2' in $3)"; fi; }
lacks() { if grep -q -- "$2" "$3" 2>/dev/null; then bad "$1 ('$2' is in $3)"; else ok "$1"; fi; }
eq()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

# --- the stub curl ---------------------------------------------------------------
# Records one block per call in $FAKE/calls: the arguments (one per line), then
# the config it read from stdin when run with -K -. Answers HTTP $FAKE/code
# (default 202) for the relay, and fails with exit 22 for ntfy when $FAKE/ntfy_fail
# exists (curl -f on a 5xx), or with exit 7 when $FAKE/down exists.
mkdir -p "$T/bin"
cat >"$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
want_code=0; url=""; cfg=0; prev=""
{
  echo "--- call"
  for a in "$@"; do printf 'arg: %s\n' "$a"; done
} >>"$FAKE/calls"
for a in "$@"; do
  case "$a" in -w) want_code=1 ;; -K) cfg=1 ;; http*) url="$a" ;; esac
  prev="$a"
done
if [ "$cfg" = 1 ]; then
  conf="$(cat)"
  printf '%s\n' "$conf" | sed 's/^/stdin: /' >>"$FAKE/calls"
  [ -n "$url" ] || url="$(printf '%s\n' "$conf" | sed -n 's/^url = "\(.*\)"$/\1/p')"
fi
[ -f "$FAKE/down" ] && exit 7
case "$url" in
  */v1/events)
    code=202; [ -f "$FAKE/code" ] && code="$(cat "$FAKE/code")"
    [ "$want_code" = 1 ] && printf '%s' "$code"
    exit 0 ;;
  *)
    [ -f "$FAKE/ntfy_fail" ] && exit 22
    exit 0 ;;
esac
STUB
chmod +x "$T/bin/curl"
export PATH="$T/bin:$PATH"

new_case() {
  FAKE="$T/fake.$((++CASE))"; mkdir -p "$FAKE/state"
  export FAKE
  export CASAVPN_NOTIFY_STATE_DIR="$FAKE/state"
  unset CASAVPN_RELAY_URL CASAVPN_RELAY_TOKEN NTFY_URL CASAVPN_NOTIFY_DRY_RUN
}
CASE=0
calls() { grep -c '^--- call' "$FAKE/calls" 2>/dev/null || echo 0; }
# run <function> <args...>: call a library function in a subshell, set OUT and RC.
run() { OUT="$(bash -c '. "$1"; shift; "$@"' _ "$LIB" "$@" 2>&1)"; RC=$?; }
# body_of_call: the JSON the stub received as --data-binary (the line after that argument).
sent_json() { awk '/^arg: --data-binary$/ { getline; sub(/^arg: /, ""); print; exit }' "$FAKE/calls"; }

echo "event JSON"
new_case
run casavpn_notify_event_json ping warning 'Disk "low"' $'line1\nline2 ü' 'k:1'
eq "an event is one JSON object with the five fields" "$(jq -r '[.kind,.severity,.title,.body,.dedupe]|@tsv' <<<"$OUT" | tr '\t' '|' | tr '\n' ' ')" 'ping|warning|Disk "low"|line1\nline2 ü|k:1 '
run casavpn_notify_event_json ping info t b ''
eq "an empty dedupe key leaves the field out" "$(jq -c 'has("dedupe")' <<<"$OUT")" false
run casavpn_notify_event_json ping info "$(printf 'x%.0s' $(seq 100))" "$(printf 'y%.0s' $(seq 500))" "$(printf 'k%.0s' $(seq 80))"
eq "title, body and dedupe are cut to 80, 400 and 64" "$(jq -r '[(.title|length),(.body|length),(.dedupe|length)]|@tsv' <<<"$OUT")" "$(printf '80\t400\t64')"

echo "relay"
new_case
export CASAVPN_RELAY_URL=https://relay.example.com/ CASAVPN_RELAY_TOKEN=hosttoken123
run casavpn_notify_relay ddns.failed critical 'DNS is failing' 'three runs failed' 'ddns.failed'
rc_is "delivers (HTTP 202)" 0
has "posts to <relay>/v1/events, trailing slash removed" 'arg: https://relay.example.com/v1/events$' "$FAKE/calls"
has "uses POST" '^arg: POST$' "$FAKE/calls"
has "sends JSON" '^arg: Content-Type: application/json$' "$FAKE/calls"
has "gives the token to curl on stdin" '^stdin: header = "Authorization: Bearer hosttoken123"$' "$FAKE/calls"
lacks "keeps the token out of the arguments" 'arg: .*hosttoken123' "$FAKE/calls"
eq "the body is the event" "$(sent_json | jq -c .)" '{"kind":"ddns.failed","severity":"critical","title":"DNS is failing","body":"three runs failed","dedupe":"ddns.failed"}'
has "short timeouts" '^arg: --max-time$' "$FAKE/calls"
echo 200 >"$FAKE/code"; run casavpn_notify_relay info.test info t b k;  rc_is "HTTP 200 (deduped by the relay) counts as delivered" 0
echo 401 >"$FAKE/code"; run casavpn_notify_relay info.test info t b k;  rc_is "HTTP 401 fails" 1
has "  ...and says the token was refused" 'refused the host token' <(printf '%s\n' "$OUT")
echo 500 >"$FAKE/code"; run casavpn_notify_relay info.test info t b k;  rc_is "HTTP 500 fails" 1
rm "$FAKE/code"; touch "$FAKE/down"; run casavpn_notify_relay info.test info t b k; rc_is "an unreachable relay fails" 1
rm "$FAKE/down"
run casavpn_notify_relay 'Bad Kind' info t b;   rc_is "a kind outside a-z . _ is refused" 2
run casavpn_notify_relay a.b loud t b;          rc_is "a severity outside critical|warning|info is refused" 2
CASAVPN_RELAY_TOKEN='a"b' run casavpn_notify_relay a.b info t b; rc_is "a token with a quote is not sent" 1
n=$(calls); CASAVPN_RELAY_TOKEN='a"b' run casavpn_notify_relay a.b info t b; eq "  ...and curl is not even started" "$(calls)" "$n"
unset CASAVPN_RELAY_TOKEN; run casavpn_notify_relay a.b info t b; rc_is "no token: not configured (3)" 3
export CASAVPN_RELAY_TOKEN=hosttoken123; unset CASAVPN_RELAY_URL; run casavpn_notify_relay a.b info t b; rc_is "no URL: not configured (3)" 3

echo "ntfy"
new_case
export NTFY_URL=https://ntfy.example.com/casavpn-EXAMPLE
run casavpn_notify_ntfy disk.low warning 'Disk is 93 % full' 'free some space' 'disk.low'
rc_is "delivers" 0
has "posts to the topic (the URL is read from the stdin config)" 'stdin: url = "https://ntfy.example.com/casavpn-EXAMPLE"$' "$FAKE/calls"
lacks "the ntfy topic is not in argv" 'arg: .*casavpn-EXAMPLE' "$FAKE/calls"
has "title header" '^arg: Title: Disk is 93 % full$' "$FAKE/calls"
has "warning is priority high" '^arg: Priority: high$' "$FAKE/calls"
run casavpn_notify_ntfy disk.low warning 'Disk is 93 % full' 'free some space' 'disk.low'
rc_is "the same key again within 6 h is skipped, not an error" 0
eq "  ...without a request" "$(calls)" 1
run casavpn_notify_ntfy disk.low warning t b 'other.key'; eq "another key is sent" "$(calls)" 2
run casavpn_notify_ntfy disk.low warning t b;  run casavpn_notify_ntfy disk.low warning t b; eq "an event without a key is never limited" "$(calls)" 4
for f in "$FAKE"/state/ntfy-*; do echo 1000 >"$f"; done
run casavpn_notify_ntfy disk.low warning t b 'disk.low'; eq "after the window the key is sent again" "$(calls)" 5
run casavpn_notify_ntfy a.b critical $'t\nitle' b k2; has "critical is urgent" '^arg: Priority: urgent$' "$FAKE/calls"
has "newlines are removed from the title header" '^arg: Title: title$' "$FAKE/calls"
touch "$FAKE/ntfy_fail"; run casavpn_notify_ntfy a.b info t b 'fails'; rc_is "a failed ntfy push fails" 1
rm "$FAKE/ntfy_fail"; run casavpn_notify_ntfy a.b info t b 'fails'; rc_is "  ...and is retried, because the failure left no state" 0
unset NTFY_URL; run casavpn_notify_ntfy a.b info t b; rc_is "no NTFY_URL: not configured (3)" 3

echo "both channels"
new_case
export CASAVPN_RELAY_URL=https://relay.example.com CASAVPN_RELAY_TOKEN=hosttoken123 NTFY_URL=https://ntfy.example.com/casavpn-EXAMPLE
run casavpn_notify host.rebooted info 'Host rebooted' b 'host.rebooted:abc'
rc_is "delivers to both" 0
eq "  ...in two requests" "$(calls)" 2
echo 503 >"$FAKE/code"
run casavpn_notify host.rebooted info 'Host rebooted' b 'host.rebooted:def'
rc_is "a failing relay makes the call fail" 1
eq "  ...but ntfy was still tried" "$(calls)" 4
rm "$FAKE/code"; touch "$FAKE/ntfy_fail"
run casavpn_notify host.rebooted info 'Host rebooted' b 'host.rebooted:ghi'
rc_is "a failing ntfy makes the call fail too" 1
unset CASAVPN_RELAY_URL NTFY_URL; run casavpn_notify a.b info t b; rc_is "no channel: 3" 3
run casavpn_notify 'Bad' info t b; rc_is "bad arguments: 2" 2

echo "dry run"
new_case
export CASAVPN_NOTIFY_DRY_RUN=1
run casavpn_notify cert.expiring warning 'Certificate expires in 9 days' 'body' 'cert.expiring:2026-12-30'
rc_is "prints and succeeds with no channel configured" 0
has "  ...the event" 'would send: {"kind":"cert.expiring"' <(printf '%s\n' "$OUT")
eq "  ...and sends nothing" "$(calls)" 0
export CASAVPN_RELAY_URL=https://relay.example.com CASAVPN_RELAY_TOKEN=hosttoken123 NTFY_URL=https://ntfy.example.com/casavpn-EXAMPLE
run casavpn_notify cert.expiring warning t b k; eq "  ...also with channels configured" "$(calls)" 0

echo "casavpn_env_load"
new_case
cat >"$T/env" <<'EOF'
# comment
CASAVPN_RELAY_URL="https://relay.example.com"
export CASAVPN_RELAY_TOKEN = 'tok-from-file'
NTFY_URL=https://ntfy.example.com/casavpn-EXAMPLE
CF_API_TOKEN=must-not-be-read
CASAVPN_DOMAIN=vpn.example.com
CASAVPN_DOMAIN=second.example.com
EOF
OUT="$(CASAVPN_RELAY_TOKEN=from-env bash -c '. "$1"; casavpn_env_load "$2" CASAVPN_RELAY_URL CASAVPN_RELAY_TOKEN NTFY_URL CASAVPN_DOMAIN; echo "$CASAVPN_RELAY_URL|$CASAVPN_RELAY_TOKEN|$NTFY_URL|$CASAVPN_DOMAIN|${CF_API_TOKEN:-unset}"' _ "$LIB" "$T/env")"
eq "quotes are stripped, the environment wins, unnamed keys are ignored, the last line wins" "$OUT" 'https://relay.example.com|from-env|https://ntfy.example.com/casavpn-EXAMPLE|second.example.com|unset'
OUT="$(bash -c '. "$1"; casavpn_env_load "$2" CASAVPN_RELAY_TOKEN; echo "$CASAVPN_RELAY_TOKEN"' _ "$LIB" "$T/env")"
eq "a spaced 'export KEY = value' line is read" "$OUT" 'tok-from-file'
run casavpn_env_load "$T/missing" NTFY_URL; rc_is "a missing file returns 1" 1

printf '\nnotify tests: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
