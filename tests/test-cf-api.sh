#!/usr/bin/env bash
#
# Tests for scripts/cf-api.sh with a fake `curl` first on PATH. No network.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/cf-api.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

command -v jq >/dev/null 2>&1 || { echo "jq missing, skipping cf-api tests"; exit 0; }

mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<'FAKE'
#!/usr/bin/env bash
# Logs "<METHOD> <url> <body>" and the raw argv; serves canned JSON.
method=GET; body=""; url=""; cfg=""
while [ $# -gt 0 ]; do
  case "$1" in
    --request) method="$2"; shift 2 ;;
    --data) body="$2"; shift 2 ;;
    --config) cfg="$2"; shift 2 ;;
    --header|--max-time) shift 2 ;;
    --*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s\n' "$*" >> "$FAKE_CURL_ARGV"
# Really read the config (`--config -` is stdin, like real curl); no auth, no API.
[ -n "$cfg" ] && cat "$cfg" > "$FAKE_CURL_CONFIG"
if ! grep -q '^header = "Authorization: Bearer .' "$FAKE_CURL_CONFIG" 2>/dev/null; then
  echo '{"success":false,"errors":[{"code":9106,"message":"Missing X-Auth-Key, X-Auth-Email or Authorization headers"}],"result":null}'
  exit 0
fi
printf '%s %s %s\n' "$method" "${url#*/client/v4}" "$body" >> "$FAKE_CURL_LOG"
case "$method ${url#*/client/v4}" in
  "GET /user/tokens/verify") cat "$FAKE_DIR/verify.json" ;;
  "GET /zones?name="*) cat "$FAKE_DIR/zone.json" ;;
  "GET /zones/Z1/dns_records"*)
    page="${url##*page=}"; case "$url" in *page=*) ;; *) page=1 ;; esac
    if [ -n "${FAKE_PAGED:-}" ]; then cat "$FAKE_DIR/records-p$page.json"; else cat "$FAKE_DIR/records.json"; fi ;;
  "PATCH /zones/Z1/dns_records/"*)
    case "$url" in *"/${FAKE_PATCH_FAIL:-none}") echo '{"success":false,"errors":[{"code":1004,"message":"record locked"}],"result":null}'; exit 0 ;; esac
    echo '{"success":true,"errors":[],"result":{"type":"A","name":"patched","ttl":60}}' ;;
  *) echo '{"success":false,"errors":[{"code":7003,"message":"no route"}],"result":null}' ;;
esac
FAKE
chmod +x "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH"
export FAKE_DIR="$WORK/fixtures" FAKE_CURL_LOG="$WORK/curl.log" FAKE_CURL_ARGV="$WORK/argv.log" FAKE_CURL_CONFIG="$WORK/config.log"
mkdir -p "$FAKE_DIR"
SECRET="tok-SECRET-0123456789"
export CF_API_TOKEN="$SECRET"

echo '{"success":true,"errors":[],"result":{"id":"u1","status":"active"}}' > "$FAKE_DIR/verify.json"
cat > "$FAKE_DIR/zone.json" <<'J'
{"success":true,"errors":[],"result":[{"id":"Z1","name":"example.com","status":"pending","plan":{"name":"Free Website"},"name_servers":["amy.ns.cloudflare.com","bob.ns.cloudflare.com"],"original_name_servers":["ns1.old-dns.example"]}]}
J
cat > "$FAKE_DIR/records.json" <<'J'
{"success":true,"errors":[],"result":[
 {"id":"R1","name":"vpn.example.com","type":"A","content":"198.51.100.10","proxied":false,"ttl":3600},
 {"id":"R2","name":"example.com","type":"A","content":"203.0.113.40","proxied":true,"ttl":1},
 {"id":"R3","name":"www.example.com","type":"A","content":"203.0.113.40","proxied":true,"ttl":1},
 {"id":"R4","name":"example.com","type":"MX","content":"mail.example.net","priority":10,"proxied":false,"ttl":3600}]}
J

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
run() { : > "$FAKE_CURL_LOG"; : > "$FAKE_CURL_ARGV"; : > "$FAKE_CURL_CONFIG"; OUT="$("$SCRIPT" "$@" 2>&1)"; RC=$?; }
check() { # <name> <condition-rc>
  if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; printf '%s\n' "$OUT" | sed 's/^/       /'; fi
}

echo "cf-api.sh"

run verify-token
[ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q "status: active"; check "verify-token reports active" $?

run zone-id example.com
[ "$OUT" = "Z1" ]; check "zone-id prints the id" $?

run zone-status example.com
[ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q "status:      pending" && printf '%s' "$OUT" | grep -q "amy.ns.cloudflare.com bob.ns.cloudflare.com"
check "zone-status shows state and nameservers" $?

run list-records example.com
[ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q "vpn.example.com" && printf '%s' "$OUT" | grep -q "10 mail.example.net"
check "list-records shows the records" $?

# the token must never reach a command line, stdout or stderr
run list-records example.com
! grep -q "$SECRET" "$FAKE_CURL_ARGV" && ! printf '%s' "$OUT" | grep -q "$SECRET" && grep -q "$SECRET" "$FAKE_CURL_CONFIG"
check "token travels only through the curl config, never argv or output" $?

run ensure-grey example.com
[ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q "dry run: 2 record" && ! grep -q '^PATCH' "$FAKE_CURL_LOG"
check "ensure-grey is a dry run by default" $?

run ensure-grey example.com --apply
[ $RC -eq 0 ] && [ "$(grep -c '^PATCH' "$FAKE_CURL_LOG")" -eq 2 ] && grep -q 'PATCH /zones/Z1/dns_records/R2 {"proxied":false}' "$FAKE_CURL_LOG" && ! grep -q 'R1\|R4' "$FAKE_CURL_LOG"
check "ensure-grey --apply patches only the proxied records" $?

run set-ttl example.com vpn 60
[ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q "ttl 3600 -> 60" && ! grep -q '^PATCH' "$FAKE_CURL_LOG"
check "set-ttl is a dry run by default" $?

run set-ttl example.com vpn 60 --apply
[ $RC -eq 0 ] && grep -q 'PATCH /zones/Z1/dns_records/R1 {"ttl":60}' "$FAKE_CURL_LOG"
check "set-ttl --apply patches the vpn record" $?

run set-ttl example.com vpn 30 --apply
[ $RC -ne 0 ] && ! grep -q '^PATCH' "$FAKE_CURL_LOG"
check "set-ttl rejects a TTL below 60" $?

echo '{"success":false,"errors":[{"code":9109,"message":"Invalid access token"}],"result":null}' > "$FAKE_DIR/verify.json"
run verify-token
[ $RC -eq 1 ] && printf '%s' "$OUT" | grep -q "9109: Invalid access token"
check "success=false exits 1 with the API error" $?

unset CF_API_TOKEN
run verify-token
[ $RC -eq 1 ] && printf '%s' "$OUT" | grep -q "CF_API_TOKEN is not set"
check "missing token is reported" $?

# a failed PATCH must not be masked by a later success
export CF_API_TOKEN="$SECRET" FAKE_PATCH_FAIL=R2
run ensure-grey example.com --apply
[ $RC -ne 0 ] && [ "$(grep -c '^PATCH' "$FAKE_CURL_LOG")" -eq 2 ] && printf '%s' "$OUT" | grep -q "set grey:" && printf '%s' "$OUT" | grep -q "1 update(s) failed"
check "ensure-grey keeps going after a failed PATCH and exits non-zero" $?
export FAKE_PATCH_FAIL=R1
run set-ttl example.com vpn 60 --apply
[ $RC -ne 0 ] && printf '%s' "$OUT" | grep -q "1 update(s) failed"
check "set-ttl exits non-zero when its PATCH fails" $?
unset FAKE_PATCH_FAIL

# records on later pages are found, not silently skipped
cat > "$FAKE_DIR/records-p1.json" <<'J'
{"success":true,"errors":[],"result_info":{"page":1,"per_page":500,"total_pages":3},"result":[
 {"id":"R1","name":"vpn.example.com","type":"A","content":"198.51.100.10","proxied":false,"ttl":3600}]}
J
cat > "$FAKE_DIR/records-p2.json" <<'J'
{"success":true,"errors":[],"result_info":{"page":2,"per_page":500,"total_pages":3},"result":[
 {"id":"R5","name":"a.example.com","type":"A","content":"203.0.113.40","proxied":true,"ttl":1}]}
J
cat > "$FAKE_DIR/records-p3.json" <<'J'
{"success":true,"errors":[],"result_info":{"page":3,"per_page":500,"total_pages":3},"result":[
 {"id":"R6","name":"vpn.example.com","type":"TXT","content":"x","proxied":false,"ttl":3600},
 {"id":"R7","name":"b.example.com","type":"A","content":"203.0.113.41","proxied":true,"ttl":1}]}
J
export FAKE_PAGED=1
run list-records example.com
[ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q "a.example.com" && printf '%s' "$OUT" | grep -q "b.example.com" && printf '%s' "$OUT" | grep -q "vpn.example.com"
check "list-records follows every page" $?
run ensure-grey example.com --apply
[ $RC -eq 0 ] && [ "$(grep -c '^PATCH' "$FAKE_CURL_LOG")" -eq 2 ] && grep -q 'dns_records/R5 ' "$FAKE_CURL_LOG" && grep -q 'dns_records/R7 ' "$FAKE_CURL_LOG"
check "ensure-grey --apply patches proxied records on pages 2 and 3" $?
run set-ttl example.com vpn 60 --apply
[ $RC -eq 0 ] && grep -q 'dns_records/R1 ' "$FAKE_CURL_LOG" && grep -q 'dns_records/R6 ' "$FAKE_CURL_LOG"
check "set-ttl --apply patches a record found on a later page" $?
echo '{"success":false,"errors":[{"code":1,"message":"page 3 broke"}],"result":null}' > "$FAKE_DIR/records-p3.json"
run ensure-grey example.com --apply
[ $RC -ne 0 ] && ! grep -q '^PATCH' "$FAKE_CURL_LOG"
check "a failed page fails the command before anything is patched" $?
unset FAKE_PAGED

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
