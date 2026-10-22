#!/usr/bin/env bash
#
# Offline tests for scripts/casavpn-ddns.
#
# A stub `curl` on PATH answers from files in $FAKE_DIR, so nothing touches the
# network. The stub keeps a tiny stateful Cloudflare: records.json is the zone,
# a PUT edits it, a GET reads it, which lets the tests check the read-back.

set -u -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/casavpn-ddns"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
OUT=""
RC=0

# --- the stub curl --------------------------------------------------------------
mkdir -p "$TMP/bin"
cat >"$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
# Fake curl: see tests/test-ddns.sh. Controlled through files in $FAKE_DIR.
method=GET; url=""; data=""; headers=""; has_cfg=0; fail_http=0; np=""; want_code=0
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift ;;
    --data|--data-binary|-d) data="$2"; shift ;;
    -w) want_code=1; shift ;;
    -H) headers="$headers|$2"; shift ;;
    --noproxy) np="$2"; shift ;;
    -K) has_cfg=1; shift ;;
    -f|-fsS) fail_http=1 ;;
    --max-time|--connect-timeout|--retry|--retry-delay|--retry-max-time) shift ;;
    http*) url="$1" ;;
  esac
  shift
done
[ "$has_cfg" = 1 ] && tee -a "$FAKE_DIR/stdin.log" >"$FAKE_DIR/last_stdin"
echo "$method $url" >>"$FAKE_DIR/calls.log"
printf 'noproxy=[%s] proxyenv=[%s] %s\n' "$np" "${HTTPS_PROXY:-}${ALL_PROXY:-}" "$url" >>"$FAKE_DIR/proxy.log"

ip_reply() { [ -f "$FAKE_DIR/$1" ] || exit 22; cat "$FAKE_DIR/$1"; }
cf_fail() { echo '{"success":false,"errors":[{"code":10000,"message":"Authentication error"}],"result":null}'; }

case "$url" in
  *api.ipify.org*)          ip_reply ip_ipify ;;
  *ipv4.icanhazip.com*)     ip_reply ip_icanhazip ;;
  *checkip.amazonaws.com*)  ip_reply ip_amazon ;;
  *1.1.1.1/cdn-cgi/trace*)
    [ -f "$FAKE_DIR/ip_trace" ] || exit 22
    printf 'fl=1\nh=1.1.1.1\nip=%s\nts=1\n' "$(cat "$FAKE_DIR/ip_trace")" ;;
  *api.cloudflare.com*dns_records*)
    rec="$FAKE_DIR/records.json"
    case "$method" in
      GET)
        [ -f "$FAKE_DIR/get_fail" ] && { cf_fail; exit 0; }
        jq -c '{success: true, errors: [], result: map(select(.type == "A"))}' "$rec" ;;
      PUT)
        [ -f "$FAKE_DIR/put_success_false" ] && { cf_fail; exit 0; }
        id="${url##*/}"
        if [ ! -f "$FAKE_DIR/put_lie" ]; then
          jq -c --arg id "$id" --argjson b "$data" 'map(if .id == $id then . + $b else . end)' "$rec" >"$rec.new" && mv "$rec.new" "$rec"
        fi
        echo '{"success":true,"errors":[],"result":{}}' ;;
      POST)
        jq -c --argjson b "$data" '. + [$b + {id: "created1"}]' "$rec" >"$rec.new" && mv "$rec.new" "$rec"
        echo '{"success":true,"errors":[],"result":{}}' ;;
    esac ;;
  *relay.test/v1/events)
    # the alert relay (scripts/lib/casavpn-notify.sh): a POST of a JSON event, HTTP code on stdout
    printf '%s|%s\n' "$method" "$data" >>"$FAKE_DIR/relay.log"
    cp "$FAKE_DIR/last_stdin" "$FAKE_DIR/relay_auth" 2>/dev/null
    if [ "$want_code" = 1 ]; then if [ -f "$FAKE_DIR/relay_503" ]; then printf 503; else printf 202; fi; fi ;;
  *)
    # anything else is the ntfy topic
    printf '%s|%s|%s\n' "$url" "$headers" "$data" >>"$FAKE_DIR/ntfy.log"
    # ntfy_http_error simulates a 429/503: curl -f exits 22, without -f it exits 0
    if [ -f "$FAKE_DIR/ntfy_http_error" ] && [ "$fail_http" = 1 ]; then exit 22; fi ;;
esac
STUB
chmod +x "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH"

# --- helpers --------------------------------------------------------------------

IP=11.22.33.44   # the host's "real" public address in these tests (synthetic, routable-looking)
OLD=55.66.77.88

assert() { # assert <description> <command...>
  local desc="$1"; shift
  if "$@"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n' "$desc"
    printf '  rc=%s\n  output: %s\n' "$RC" "$(printf '%s' "$OUT" | tail -n 8 | sed 's/^/    /')"
  fi
}
out_has()   { grep -q -- "$1" <<<"$OUT"; }
rc_is()     { [ "$RC" -eq "$1" ]; }
no_calls()  { ! grep -q -- "$1" "$FAKE_DIR/calls.log" 2>/dev/null; }
has_calls() { grep -q -- "$1" "$FAKE_DIR/calls.log" 2>/dev/null; }
relay_count() { [ -f "$FAKE_DIR/relay.log" ] && wc -l <"$FAKE_DIR/relay.log" | tr -d ' ' || echo 0; }
token_not_in_output() { ! grep -q hosttoken123 <<<"$OUT"; }
relay_names_last_error() { relay_json 1 | grep -q 'Last error'; }
relay_json() { sed -n "${1:-1}p" "$FAKE_DIR/relay.log" | cut -d'|' -f2-; }
ntfy_count() { [ -f "$FAKE_DIR/ntfy.log" ] && wc -l <"$FAKE_DIR/ntfy.log" | tr -d ' ' || echo 0; }
topic_not_in_output() { ! grep -q secret-topic <<<"$OUT"; }
no_tmp_files() { [ -z "$(find "$STATE_DIR" -name '.tmp*' 2>/dev/null)" ]; }
state_dir_private() { [ "$(find "$STATE_DIR" -maxdepth 0 -perm 700 2>/dev/null)" = "$STATE_DIR" ]; }
no_alert_state() { [ -z "$(find "$STATE_DIR" -name 'alert-*' 2>/dev/null)" ]; }
has_alert_state() { [ -n "$(find "$STATE_DIR" -name 'alert-*' 2>/dev/null)" ]; }
state() { cat "$STATE_DIR/$1" 2>/dev/null; }
rec() { jq -r ".[0].$1" "$FAKE_DIR/records.json"; }

# new_case: fresh fake Cloudflare, state dir and env file.
new_case() {
  FAKE_DIR="$TMP/fake.$((++CASE))"
  STATE_DIR="$TMP/state.$CASE"
  ENV_FILE="$TMP/env.$CASE"
  mkdir -p "$FAKE_DIR"
  export FAKE_DIR
  set_ips "$IP" "$IP" "$IP" "$IP"
  set_records "[{\"id\":\"rec1\",\"type\":\"A\",\"name\":\"vpn.example.test\",\"content\":\"$OLD\",\"proxied\":false,\"ttl\":60}]"
  write_env "NTFY_URL=https://ntfy.test/secret-topic"
}
write_env() {
  {
    echo "CF_API_TOKEN=tok_test"
    echo "CF_ZONE_ID=zone1"
    echo "CASAVPN_DOMAIN=vpn.example.test"
    [ $# -gt 0 ] && printf '%s\n' "$@"
  } >"$ENV_FILE"
}
set_ips() { # ipify icanhazip amazon trace; "-" = source is down; anything else is the reply
  local names="ipify icanhazip amazon trace" n v i=1
  for n in $names; do
    v="${!i}"
    if [ "$v" = "-" ]; then rm -f "$FAKE_DIR/ip_$n"; else printf '%s\n' "$v" >"$FAKE_DIR/ip_$n"; fi
    i=$((i + 1))
  done
}
set_records() { printf '%s' "$1" >"$FAKE_DIR/records.json"; }
run_ddns() {
  OUT=$(env CASAVPN_ENV_FILE="$ENV_FILE" CASAVPN_DDNS_STATE_DIR="$STATE_DIR" \
            CASAVPN_DDNS_EGRESS_IFACE="${EGRESS:-eth0}" "$@" bash "$SCRIPT" 2>&1) && RC=0 || RC=$?
}
ddns() { # ddns <script args...>
  OUT=$(env CASAVPN_ENV_FILE="$ENV_FILE" CASAVPN_DDNS_STATE_DIR="$STATE_DIR" \
            CASAVPN_DDNS_EGRESS_IFACE="${EGRESS:-eth0}" bash "$SCRIPT" "$@" 2>&1) && RC=0 || RC=$?
}
CASE=0

# --- 1. pure functions: validation and ranges ---------------------------------------
# shellcheck source=../scripts/casavpn-ddns
source "$SCRIPT"
RC=0; OUT=""
for good in 1.2.3.4 11.22.33.44 255.255.255.255 0.0.0.0 100.10.5.5; do
  assert "valid_ipv4 accepts $good" valid_ipv4 "$good"
done
for bad in 1.2.3.256 999.1.1.1 1.2.3 1.2.3.4.5 01.2.3.4 1.2.3.04 a.b.c.d "" "1.2.3.4 " "<html>" 1.2.3.-4 ::1; do
  if valid_ipv4 "$bad"; then FAIL=$((FAIL + 1)); echo "FAIL: valid_ipv4 accepted '$bad'"; else PASS=$((PASS + 1)); fi
done
# Public: must be publishable.
for pub in 11.22.33.44 100.10.5.5 100.19.255.255 100.63.255.255 100.128.0.1 172.15.0.1 172.32.0.1 \
           1.1.1.1 8.8.8.8 191.255.0.1 223.255.255.254 192.169.0.1 169.253.0.1 11.0.0.1 9.255.255.255; do
  if non_public_reason "$pub" >/dev/null; then FAIL=$((FAIL + 1)); echo "FAIL: $pub wrongly classed non-public"; else PASS=$((PASS + 1)); fi
done
# Documentation ranges are /24s: their neighbours are ordinary public space.
for pub in 203.0.112.255 203.0.114.1 203.1.113.1 198.51.99.255 198.51.101.1 198.52.100.1 198.17.255.255 198.20.0.1 \
           192.0.1.1 192.0.3.1 192.1.2.1 192.0.4.0; do
  if non_public_reason "$pub" >/dev/null; then FAIL=$((FAIL + 1)); echo "FAIL: $pub wrongly classed non-public"; else PASS=$((PASS + 1)); fi
done
# Non-public: must be refused (CGNAT is 100.64.0.0 - 100.127.255.255).
for priv in 0.1.2.3 10.0.0.1 10.255.255.255 100.64.0.0 100.64.0.1 100.100.1.1 100.127.255.255 127.0.0.1 \
            169.254.1.1 172.16.0.1 172.31.255.255 192.168.1.1 192.0.2.1 198.18.0.1 198.19.5.5 198.19.255.255 192.0.0.0 192.0.0.255 192.0.2.255 198.51.100.0 198.51.100.255 203.0.113.0 203.0.113.255 224.0.0.1 240.0.0.1 255.255.255.255; do
  if non_public_reason "$priv" >/dev/null; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $priv wrongly classed public"; fi
done

# --- 2. stale record is repaired and verified ---------------------------------------------
new_case; ddns
assert "stale IP: exits 0" rc_is 0
assert "stale IP: record rewritten" test "$(rec content)" = "$IP"
assert "stale IP: state recorded" test "$(state last-ip)" = "$IP"
assert "stale IP: read-back GET after the PUT" bash -c "grep -n . '$FAKE_DIR/calls.log' | awk '/PUT/{p=1} p && /GET/{f=1} END{exit !f}'"
assert "stale IP: ntfy push says old -> new" grep -q "$OLD -> $IP" "$FAKE_DIR/ntfy.log"
assert "stale IP: token not on any argv (sent via stdin)" grep -q 'tok_test' "$FAKE_DIR/stdin.log"
assert "stale IP: ntfy topic not printed in the log" topic_not_in_output

# --- 2b. proxies are never used for discovery or the Cloudflare API ---------------------------
new_case; run_ddns HTTPS_PROXY=http://127.0.0.1:9 ALL_PROXY=http://127.0.0.1:9
assert "proxy env: still repairs the record" test "$(rec content)" = "$IP"
assert "proxy env: every IP-discovery and API call carried --noproxy '*'" bash -c "
  grep -E 'api.ipify|icanhazip|amazonaws|cdn-cgi|api.cloudflare' '$FAKE_DIR/proxy.log' | grep -vq 'noproxy=\[\*\]'; [ \$? -ne 0 ]"
assert "proxy env: and the calls were actually seen" bash -c "grep -c 'noproxy=\[\*\]' '$FAKE_DIR/proxy.log' | grep -qv '^0$'"

# --- 3. success:false on a write must not be recorded as success ---------------------------
new_case; touch "$FAKE_DIR/put_success_false"; ddns
assert "success=false: exits 1" rc_is 1
assert "success=false: state NOT written" test ! -f "$STATE_DIR/last-ip"
assert "success=false: failure counted" test "$(state fail-count)" = "1"
assert "success=false: record untouched" test "$(rec content)" = "$OLD"

# --- 4. a write that Cloudflare acknowledges but did not apply is caught by the read-back ----
new_case; touch "$FAKE_DIR/put_lie"; ddns
assert "lying PUT: exits 1" rc_is 1
assert "lying PUT: read-back mismatch reported" out_has "read-back disagrees"
assert "lying PUT: state NOT written" test ! -f "$STATE_DIR/last-ip"

# --- 5. drift with a matching local cache is still repaired --------------------------------------
new_case; mkdir -p "$STATE_DIR"; echo "$IP" >"$STATE_DIR/last-ip"; ddns
assert "drift behind a matching cache: repaired" test "$(rec content)" = "$IP"
assert "drift behind a matching cache: exits 0" rc_is 0

# --- 6. orange cloud ------------------------------------------------------------------------
new_case
set_records "[{\"id\":\"rec1\",\"type\":\"A\",\"name\":\"vpn.example.test\",\"content\":\"$IP\",\"proxied\":true,\"ttl\":1}]"
ddns
assert "orange cloud: turned off" test "$(rec proxied)" = "false"
assert "orange cloud: ttl forced to 60" test "$(rec ttl)" = "60"
assert "orange cloud: exits 0" rc_is 0

# --- 7. wrong TTL (Cloudflare 'Auto' on a grey cloud is 300, not 60) -----------------------------
new_case
set_records "[{\"id\":\"rec1\",\"type\":\"A\",\"name\":\"vpn.example.test\",\"content\":\"$IP\",\"proxied\":false,\"ttl\":300}]"
ddns
assert "ttl 300: set to 60" test "$(rec ttl)" = "60"
assert "ttl 300: IP kept" test "$(rec content)" = "$IP"

# --- 8. in sync: no write, no noise ---------------------------------------------------------------
new_case
set_records "[{\"id\":\"rec1\",\"type\":\"A\",\"name\":\"vpn.example.test\",\"content\":\"$IP\",\"proxied\":false,\"ttl\":60}]"
ddns
assert "in sync: exits 0" rc_is 0
assert "in sync: no PUT/POST" no_calls '^P'
assert "in sync: no ntfy push" test "$(ntfy_count)" = "0"
assert "in sync: says so" out_has "in sync"

# --- 9. two A records: fail loudly, change nothing -------------------------------------------------
new_case
set_records "[{\"id\":\"rec1\",\"type\":\"A\",\"name\":\"vpn.example.test\",\"content\":\"$IP\",\"proxied\":false,\"ttl\":60},{\"id\":\"rec2\",\"type\":\"A\",\"name\":\"vpn.example.test\",\"content\":\"$OLD\",\"proxied\":false,\"ttl\":60}]"
ddns
assert "two A records: exits 1" rc_is 1
assert "two A records: nothing written" no_calls '^P'
assert "two A records: ntfy push sent" grep -q 'multiple A records' "$FAKE_DIR/ntfy.log"

# --- 10. AAAA is never touched and never created ---------------------------------------------------
new_case
set_records "[{\"id\":\"v6\",\"type\":\"AAAA\",\"name\":\"vpn.example.test\",\"content\":\"2001:db8::1\",\"proxied\":false,\"ttl\":60}]"
ddns
assert "AAAA only: a missing A record is created" test "$(jq -r '[.[]|select(.type=="A")][0].content' "$FAKE_DIR/records.json")" = "$IP"
assert "AAAA only: the AAAA record is unchanged" test "$(jq -r '[.[]|select(.type=="AAAA")][0].content' "$FAKE_DIR/records.json")" = "2001:db8::1"
assert "AAAA only: no PUT against the AAAA id" no_calls 'PUT .*/v6'
assert "AAAA only: no second AAAA created" test "$(jq '[.[]|select(.type=="AAAA")]|length' "$FAKE_DIR/records.json")" = "1"

# --- 11. an octet above 255 is rejected --------------------------------------------------------------
new_case; set_ips 999.1.1.1 1.2.3.256 300.1.1.1 "999.1.1.1"; ddns
assert "octet > 255: exits 1" rc_is 1
assert "octet > 255: nothing written" no_calls '^P'
new_case; set_ips 1.2.3.256 1.2.3.256 1.2.3.256 1.2.3.256; ddns
assert "octet > 255 even when every source agrees: exits 1" rc_is 1
assert "octet > 255 even when every source agrees: no write" no_calls '^P'

# --- 12. 100.10.x is public, 100.64.x is CGNAT ----------------------------------------------------------
new_case; set_ips 100.10.20.30 100.10.20.30 100.10.20.30 100.10.20.30; ddns
assert "100.10.x is public: published" test "$(rec content)" = "100.10.20.30"
new_case; set_ips 100.64.1.2 100.64.1.2 100.64.1.2 100.64.1.2; ddns
assert "100.64.x is CGNAT: exits 1" rc_is 1
assert "100.64.x is CGNAT: nothing written" no_calls '^P'
assert "100.64.x is CGNAT: ntfy push sent" grep -q 'not public' "$FAKE_DIR/ntfy.log"
new_case; set_ips 100.100.1.1 100.100.1.1 100.100.1.1 100.100.1.1; ddns
assert "100.100.x is CGNAT (inside 100.64/10): exits 1" rc_is 1
new_case; set_ips 192.168.1.50 192.168.1.50 192.168.1.50 192.168.1.50; ddns
assert "RFC1918 refused" rc_is 1

# --- 13. sources that disagree ----------------------------------------------------------------------------
new_case; set_ips 1.1.1.2 2.2.2.2 3.3.3.3 4.4.4.4; ddns
assert "all four sources differ: exits 1" rc_is 1
assert "all four differ: nothing written" no_calls '^P'
new_case; set_ips 1.1.1.2 1.1.1.2 3.3.3.3 3.3.3.3; ddns
assert "2-2 tie: exits 1" rc_is 1
assert "2-2 tie: nothing written" no_calls '^P'
new_case; set_ips "$IP" - - -; ddns
assert "one lone answer: exits 1" rc_is 1
assert "one lone answer: nothing written" no_calls '^P'
new_case; set_ips "$IP" "$IP" "<html>rate limited</html>" -; ddns
assert "two agree, one junk, one down: published" test "$(rec content)" = "$IP"
new_case; set_ips "$IP" "$IP" "$IP" 4.4.4.4; ddns
assert "3-1 majority wins" test "$(rec content)" = "$IP"

# --- 14. dry-run writes nothing ------------------------------------------------------------------------------
new_case; ddns --dry-run
assert "dry-run: exits 0" rc_is 0
assert "dry-run: says what it would do" out_has "DRY RUN"
assert "dry-run: record untouched" test "$(rec content)" = "$OLD"
assert "dry-run: no PUT/POST" no_calls '^P'
assert "dry-run: state dir not created" test ! -e "$STATE_DIR"
assert "dry-run: no ntfy push" test "$(ntfy_count)" = "0"
new_case; set_ips 1.1.1.2 2.2.2.2 3.3.3.3 4.4.4.4; ddns --dry-run
assert "dry-run + failure: still no state" test ! -e "$STATE_DIR"

# --- 15. --check -------------------------------------------------------------------------------------------------
new_case
set_records "[{\"id\":\"rec1\",\"type\":\"A\",\"name\":\"vpn.example.test\",\"content\":\"$IP\",\"proxied\":false,\"ttl\":60}]"
ddns --check
assert "--check in sync: exits 0" rc_is 0
assert "--check mentions the CGNAT reachability probe" out_has "nc -vz vpn.example.test 443"
new_case
set_records "[{\"id\":\"rec1\",\"type\":\"A\",\"name\":\"vpn.example.test\",\"content\":\"$IP\",\"proxied\":true,\"ttl\":1}]"
ddns --check
assert "--check orange cloud with the right IP: exits 1" rc_is 1
assert "--check orange cloud: says the settings drifted" out_has "drifted settings"
new_case
set_records "[{\"id\":\"rec1\",\"type\":\"A\",\"name\":\"vpn.example.test\",\"content\":\"$IP\",\"proxied\":false,\"ttl\":300}]"
ddns --check
assert "--check ttl 300 with the right IP: exits 1" rc_is 1
assert "--check ttl 300: record untouched" test "$(rec ttl)" = "300"
new_case; ddns --check
assert "--check drifted: exits 1" rc_is 1
assert "--check drifted: record untouched" test "$(rec content)" = "$OLD"
assert "--check: nothing written, state dir absent" test ! -e "$STATE_DIR"
assert "--check: no PUT/POST" no_calls '^P'

# --- 16. --force does a real write + read-back even when in sync -------------------------------------------------
new_case
set_records "[{\"id\":\"rec1\",\"type\":\"A\",\"name\":\"vpn.example.test\",\"content\":\"$IP\",\"proxied\":false,\"ttl\":60}]"
ddns --force
assert "--force when in sync: PUT issued" has_calls '^PUT'
assert "--force when in sync: exits 0" rc_is 0
assert "--force when in sync: no 'changed' push (nothing changed)" test "$(ntfy_count)" = "0"

# --- 17. overlapping runs -------------------------------------------------------------------------------------------
new_case; mkdir -p "$STATE_DIR"
if command -v flock >/dev/null 2>&1; then
  flock "$STATE_DIR/lock" sleep 20 & holder=$!
  sleep 1
else
  mkdir "$STATE_DIR/lock.d"; sleep 20 & holder=$!; echo "$holder" >"$STATE_DIR/lock.d/pid"
fi
ddns
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
assert "overlap: second run backs off with exit 0" rc_is 0
assert "overlap: says another run holds the lock" out_has "another run holds the lock"
assert "overlap: made no network calls at all" test ! -f "$FAKE_DIR/calls.log"
assert "overlap: record untouched" test "$(rec content)" = "$OLD"

# --- 18. repeated failures: push on the 3rd, then rate-limited ------------------------------------------------------
new_case; touch "$FAKE_DIR/get_fail"
ddns; ddns
assert "2 failures: no 'failing' push yet" test "$(ntfy_count)" = "0"
ddns
assert "3rd failure: push sent" grep -q 'casavpn-ddns failing' "$FAKE_DIR/ntfy.log"
assert "3rd failure: counter is 3" test "$(state fail-count)" = "3"
ddns
assert "4th failure within the hour: identical alert suppressed" test "$(ntfy_count)" = "1"
rm -f "$FAKE_DIR/get_fail"; ddns
assert "recovery resets the failure counter" test "$(state fail-count)" = "0"
assert "recovery: record repaired" test "$(rec content)" = "$IP"

# --- 18b. an HTTP error from ntfy is not a delivery ---------------------------------------------------------
new_case; touch "$FAKE_DIR/ntfy_http_error"; ddns
assert "ntfy 429: the run itself still succeeds" rc_is 0
assert "ntfy 429: push was attempted" test "$(ntfy_count)" = "1"
assert "ntfy 429: rate-limit state NOT recorded" no_alert_state
set_records "[{\"id\":\"rec1\",\"type\":\"A\",\"name\":\"vpn.example.test\",\"content\":\"$OLD\",\"proxied\":false,\"ttl\":60}]"
rm -f "$FAKE_DIR/ntfy_http_error"; ddns
assert "ntfy recovered: the same alert is retried (not suppressed)" test "$(ntfy_count)" = "2"
assert "ntfy recovered: rate-limit state recorded after the 2xx" has_alert_state

# --- 19. no NTFY_URL: log only ------------------------------------------------------------------------------------------
new_case; write_env; ddns
assert "no NTFY_URL: run succeeds" rc_is 0
assert "no NTFY_URL: alert logged" out_has "ALERT"
assert "no NTFY_URL: no push attempted" test "$(ntfy_count)" = "0"

# --- 20. tunnel egress refused ----------------------------------------------------------------------------------------------
new_case; EGRESS=tun0 ddns
assert "egress via tun0: exits 1" rc_is 1
assert "egress via tun0: nothing written" no_calls '^P'
new_case; EGRESS=wg0 ddns
assert "egress via wg0: exits 1" rc_is 1
new_case; EGRESS=eth0 ddns
assert "egress via eth0: fine" rc_is 0
unset EGRESS

# --- 21. state writes are atomic (no stray temp files left behind) ------------------------------------------------------------------
new_case; ddns
assert "no .tmp files left in the state dir" no_tmp_files
assert "state dir is private (0700)" state_dir_private

# --- 21b. the env file is shared with install.sh and the backup job ----------------------------------------------
new_case; write_env "CASAVPN_ADMIN_USER=pi" "AGE_RECIPIENT=age1example" "SOMETHING_ELSE=1"; ddns
assert "keys that belong to other tools are ignored" rc_is 0
assert "  ...silently (no per-minute log noise)" bash -c "! grep -q 'unknown key' <<<\"\$1\"" _ "$OUT"
new_case; write_env "CASAVPN_DDNS_PROVIDER=nonesuch"; ddns
assert "unknown provider: exits 1" rc_is 1
assert "  ...names the known providers" out_has "known: cloudflare"
assert "  ...nothing written" no_calls '^P'
new_case; write_env "CASAVPN_DDNS_PROVIDER=cloudflare" "CASAVPN_VPN_PORT=8123"; ddns --check
assert "--check hint uses the configured VPN port" out_has "nc -vz vpn.example.test 8123"
new_case; grep -v '^CF_ZONE_ID' "$ENV_FILE" >"$ENV_FILE.new" && mv "$ENV_FILE.new" "$ENV_FILE"; ddns
assert "missing CF_ZONE_ID: exits 1 and says so" bash -c "[ $RC -eq 1 ] && grep -q 'CF_ZONE_ID not set' <<<\"\$1\"" _ "$OUT"

# --- 18c. the alert relay gets ip.changed and ddns.failed -----------------------------------------------------------
RELAY_ENV=("CASAVPN_RELAY_URL=https://relay.test" "CASAVPN_RELAY_TOKEN=hosttoken123")
new_case; write_env "NTFY_URL=https://ntfy.test/secret-topic" "${RELAY_ENV[@]}"; ddns
assert "relay: a stale record is still repaired" test "$(rec content)" = "$IP"
assert "relay: ip.changed is posted once" test "$(relay_count)" = "1"
assert "relay: ... as a warning of kind ip.changed" test "$(relay_json 1 | jq -r '[.kind,.severity]|join(" ")')" = "ip.changed warning"
assert "relay: ... with the old and the new address in the dedupe key" test "$(relay_json 1 | jq -r .dedupe)" = "ip.changed:$OLD-$IP"
assert "relay: ... and the same text as ntfy" test "$(relay_json 1 | jq -r .body)" = "vpn.example.test: $OLD -> $IP (content $OLD->$IP)"
assert "relay: the token travels in curl's stdin config" grep -q 'Authorization: Bearer hosttoken123' "$FAKE_DIR/relay_auth"
assert "relay: ntfy still gets its push" test "$(ntfy_count)" = "1"
assert "relay: the token is not printed" token_not_in_output
new_case; write_env "${RELAY_ENV[@]}"; ddns
assert "relay without ntfy: ip.changed is posted" test "$(relay_count)" = "1"
assert "relay without ntfy: the rate-limit state is kept per channel" test -f "$STATE_DIR/relay-changed-${OLD}-${IP}"
new_case; write_env "${RELAY_ENV[@]}"; ddns --dry-run
assert "relay: --dry-run posts nothing" test "$(relay_count)" = "0"
new_case; write_env "${RELAY_ENV[@]}"; set_records "[{\"id\":\"rec1\",\"type\":\"A\",\"name\":\"vpn.example.test\",\"content\":\"$IP\",\"proxied\":false,\"ttl\":60}]"; ddns
assert "relay: nothing changed, nothing posted" test "$(relay_count)" = "0"
new_case; write_env "${RELAY_ENV[@]}"; touch "$FAKE_DIR/get_fail"
ddns; ddns
assert "relay: no ddns.failed after 2 failed runs" test "$(relay_count)" = "0"
ddns
assert "relay: ddns.failed after the 3rd failed run" test "$(relay_json 1 | jq -r '[.kind,.severity,.dedupe]|join(" ")')" = "ddns.failed critical ddns.failed"
assert "relay: ... naming the last error" relay_names_last_error
ddns
assert "relay: a 4th failure within the hour is not posted again" test "$(relay_count)" = "1"
new_case; write_env "${RELAY_ENV[@]}"; touch "$FAKE_DIR/relay_503"; ddns
assert "relay down: the run still repairs DNS and exits 0" bash -c "[ $RC -eq 0 ] && [ \"\$(jq -r '.[0].content' '$FAKE_DIR/records.json')\" = '$IP' ]"
assert "relay down: the failure is logged" out_has "could not deliver the relay alert"
assert "relay down: no rate-limit state, so the next run retries" test ! -f "$STATE_DIR/relay-changed-${OLD}-${IP}"
assert "relay down: the undelivered ip.changed is kept" test "$(jq -r '[.kind,.relay,.ntfy]|join(" ")' "$STATE_DIR/pending-event")" = "ip.changed 1 0"
rm -f "$FAKE_DIR/relay_503"; : >"$FAKE_DIR/relay.log"
ddns
assert "pending: the next run (DNS already in sync) resends it" test "$(relay_count)" = "1"
assert "pending: ... as the same event" test "$(relay_json 1 | jq -r '[.kind,.dedupe]|join(" ")')" = "ip.changed ip.changed:$OLD-$IP"
assert "pending: ... and forgets it once delivered" test ! -e "$STATE_DIR/pending-event"
ddns
assert "pending: nothing is sent again after that" test "$(relay_count)" = "1"
new_case; write_env "NTFY_URL=https://ntfy.test/secret-topic" "${RELAY_ENV[@]}"; touch "$FAKE_DIR/relay_503"; ddns
assert "pending: ntfy delivered, relay failed: only the relay is pending" test "$(jq -r '[.relay,.ntfy]|join(" ")' "$STATE_DIR/pending-event")" = "1 0"
rm -f "$FAKE_DIR/relay_503"; n=$(ntfy_count); ddns
assert "pending: the retry does not push to ntfy twice" test "$(ntfy_count)" = "$n"
assert "pending: ... and the relay got it" test "$(relay_count)" -ge 1
new_case; write_env "${RELAY_ENV[@]}"; touch "$FAKE_DIR/relay_503"; ddns; ddns; ddns
assert "pending: a still-failing relay keeps the event" test -s "$STATE_DIR/pending-event"
jq -c '.at = 1000' "$STATE_DIR/pending-event" >"$STATE_DIR/p.tmp" && mv "$STATE_DIR/p.tmp" "$STATE_DIR/pending-event"
ddns
assert "pending: an event older than 24 h is dropped" test ! -e "$STATE_DIR/pending-event"
assert "pending: ... and logged" out_has "dropping the kept alert"
new_case; write_env "${RELAY_ENV[@]}"; touch "$FAKE_DIR/relay_503"; ddns --dry-run
assert "pending: --dry-run keeps nothing" test ! -e "$STATE_DIR/pending-event"
new_case; write_env "NTFY_URL=https://ntfy.test/secret-topic" "CASAVPN_RELAY_URL=https://relay.test"; ddns
assert "relay URL without a token: not used" test "$(relay_count)" = "0"

# --- 22. bad arguments --------------------------------------------------------------------------------------------------------------
new_case; ddns --nonsense
assert "unknown argument: exit 2" rc_is 2
ddns --check --force
assert "--check with --force: exit 2" rc_is 2

echo
echo "ddns tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
