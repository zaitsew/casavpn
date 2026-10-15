#!/usr/bin/env bash
#
# Tests for scripts/healthcheck.sh in --local and remote mode, with fake system
# tools first on PATH. No network, no root, nothing on the host is touched.

# The fakes are written as single-quoted scripts on purpose; the helpers take
# optional arguments they are not given here.
# shellcheck disable=SC2016,SC2119,SC2120

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HC="$ROOT/scripts/healthcheck.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/casavpn-hc-test.XXXXXXXX")"
trap 'rm -rf "${T:?}"' EXIT

for tool in sqlite3 openssl python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "$tool missing, skipping healthcheck tests"; exit 0; }
done

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; printf '%s\n' "$OUT" | sed 's/^/       /'; }
OUT=""; RC=0
expect() { # <name> <rc> [grep pattern]
  if [ "$RC" -ne "$2" ]; then bad "$1 (rc=$RC, want $2)"; return; fi
  if [ -n "${3:-}" ] && ! grep -q -- "$3" <<<"$OUT"; then bad "$1 (output lacks: $3)"; return; fi
  ok "$1"
}
said() { # <name> <pattern>: the last run's output contains the pattern
  if grep -q -- "$2" <<<"$OUT"; then ok "$1"; else bad "$1 (output lacks: $2)"; fi
}

# --- fake tools -----------------------------------------------------------------
BIN="$T/bin"; mkdir -p "$BIN"
mk() { printf '%s\n' "$2" >"$BIN/$1"; chmod +x "$BIN/$1"; }

mk sudo '#!/usr/bin/env bash
[ "$1" = "-n" ] && shift
exec "$@"'
mk systemctl '#!/usr/bin/env bash
# systemctl is-active|is-enabled --quiet <unit>; units in $FAKE_BAD_UNITS fail.
unit="${@: -1}"
case " ${FAKE_BAD_UNITS:-} " in *" $unit "*) exit 3 ;; esac
exit 0'
mk ss '#!/usr/bin/env bash
cat "$FAKE_SS"'
mk nft '#!/usr/bin/env bash
[ -n "${FAKE_NO_NFT:-}" ] && exit 1
exit 0'
mk sshd '#!/usr/bin/env bash
printf "passwordauthentication %s\npermitrootlogin %s\n" "${FAKE_SSH_PASSWORD:-no}" "${FAKE_SSH_ROOT:-no}"'
mk fail2ban-client '#!/usr/bin/env bash
exit 0'
mk dig '#!/usr/bin/env bash
echo "${FAKE_DNS_IP:-198.51.100.10}"'
mk curl '#!/usr/bin/env bash
# api.ipify.org -> the host IP; anything else -> an HTTP status code.
for a in "$@"; do case "$a" in *ipify*) echo "${FAKE_PUBLIC_IP:-198.51.100.10}"; exit 0 ;; esac; done
echo "${FAKE_WEB_CODE:-404}"'
mk ssh '#!/usr/bin/env bash
# Run the remote command locally through the fakes; "true" succeeds.
[ "${FAKE_SSH_DOWN:-}" = 1 ] && exit 255
while [ $# -gt 0 ]; do case "$1" in -o) shift 2 ;; -*) shift ;; *) break ;; esac; done
shift   # the target
exec bash -c "$*"'
mk nc '#!/usr/bin/env bash
port="${@: -1}"
case " ${FAKE_NC_CLOSED:-} " in *" $port "*) exit 1 ;; esac
exit 0'
mk openssl '#!/usr/bin/env bash
case "$1" in
  s_client) printf "subject=CN = %s\nVerify return code: 0 (ok)\n" "${FAKE_CERT_CN:-www.example.net}" ;;
  x509) if [[ "$*" == *-enddate* && "$*" != *-in* ]]; then echo "notAfter=Jan  1 00:00:00 2099 GMT"; else exec "$REAL_OPENSSL" "$@"; fi ;;
  *) exec "$REAL_OPENSSL" "$@" ;;
esac'
REAL_OPENSSL="$(command -v openssl)"; export REAL_OPENSSL

# --- local-mode fixtures -----------------------------------------------------------
DB="$T/x-ui.db"
LE="$T/le"; mkdir -p "$LE/vpn.example.com"
BK="$T/backups"; mkdir -p "$BK"
python3 - "$DB" <<'PY'
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute("CREATE TABLE inbounds (id INTEGER PRIMARY KEY, remark TEXT, port INTEGER, protocol TEXT, enable INTEGER, settings TEXT, stream_settings TEXT)")
db.execute("CREATE TABLE settings (id INTEGER PRIMARY KEY, key TEXT, value TEXT)")
stream = {"security": "reality", "realitySettings": {"minClientVer": "1.8.0"}}
db.execute("INSERT INTO inbounds VALUES (1, 'main', 443, 'vless', 1, '{}', ?)", (json.dumps(stream),))
tpl = {"outbounds": [{"tag": "direct", "protocol": "freedom"}, {"tag": "blocked", "protocol": "blackhole"}],
       "routing": {"rules": [{"type": "field", "outboundTag": "blocked", "ip": ["geoip:private"]},
                             {"type": "field", "outboundTag": "blocked", "protocol": ["bittorrent"]}]}}
db.execute("INSERT INTO settings (key, value) VALUES ('xrayTemplateConfig', ?)", (json.dumps(tpl),))
db.commit()
PY
cp "$DB" "$T/good.db"
openssl req -x509 -newkey rsa:2048 -nodes -days 90 -subj "/CN=vpn.example.com" \
  -keyout "$LE/vpn.example.com/privkey.pem" -out "$LE/vpn.example.com/fullchain.pem" >/dev/null 2>&1
printf 'LISTEN 0 4096 0.0.0.0:443 0.0.0.0:*\nLISTEN 0 4096 127.0.0.1:2053 0.0.0.0:*\nLISTEN 0 4096 127.0.0.1:2096 0.0.0.0:*\n' >"$T/ss.good"
cp "$T/ss.good" "$T/ss.cur"
export FAKE_SS="$T/ss.cur"
printf 'CASAVPN_DOMAIN=vpn.example.com\nCASAVPN_REALITY_TARGET=www.example.net\n' >"$T/test.env"
GOOD_BACKUP="$BK/casavpn-20260101T000000Z.tar.zst.age"

lrun() { OUT="$(env PATH="$BIN:$PATH" CASAVPN_ENV="$T/test.env" CASAVPN_DB="$DB" CASAVPN_LE_DIR="$LE" \
  CASAVPN_BACKUP_DEST="$BK" "$HC" --local "$@" 2>&1)"; RC=$?; }
reset_local() {
  cp "$T/good.db" "$DB"; cp "$T/ss.good" "$T/ss.cur"
  find "$BK" -type f -delete; touch "$GOOD_BACKUP"
  unset FAKE_BAD_UNITS FAKE_NO_NFT FAKE_SSH_PASSWORD FAKE_SSH_ROOT FAKE_DNS_IP FAKE_PUBLIC_IP
}

echo "healthcheck.sh --local"
reset_local; lrun
expect "a healthy host passes" 0 "All critical checks passed"
said "  ...and reports the block rules" "routing: geoip:private and bittorrent"

reset_local; FAKE_BAD_UNITS="x-ui"; export FAKE_BAD_UNITS; lrun
expect "x-ui down is critical" 1 "x-ui is NOT active"
reset_local; FAKE_BAD_UNITS="casavpn-ddns.timer"; export FAKE_BAD_UNITS; lrun
expect "a disabled DDNS timer is only a warning" 0 "casavpn-ddns.timer is not enabled"

reset_local; printf 'LISTEN 0 4096 0.0.0.0:443 0.0.0.0:*\nLISTEN 0 4096 0.0.0.0:2053 0.0.0.0:*\nLISTEN 0 4096 127.0.0.1:2096 0.0.0.0:*\n' >"$T/ss.cur"; lrun
expect "panel on all interfaces is critical" 1 "port 2053 listens on ALL interfaces"
reset_local; printf 'LISTEN 0 4096 127.0.0.1:2053 0.0.0.0:*\n' >"$T/ss.cur"; lrun
expect "nothing on the VPN port is critical" 1 "nothing listens on the VPN port 443"
reset_local; printf 'LISTEN 0 4096 *:443 *:*\nLISTEN 0 4096 [::]:2096 [::]:*\nLISTEN 0 4096 127.0.0.1:2053 0.0.0.0:*\n' >"$T/ss.cur"; lrun
expect "IPv6 wildcard listeners are recognised" 1 "port 2096 listens on ALL interfaces"

reset_local; FAKE_SSH_PASSWORD=yes; export FAKE_SSH_PASSWORD; lrun
expect "SSH password login on is critical" 1 "password login is ON"
reset_local; FAKE_SSH_ROOT=yes; export FAKE_SSH_ROOT; lrun
expect "SSH root login with password is critical" 1 "root can log in"
reset_local; FAKE_NO_NFT=1; export FAKE_NO_NFT; lrun
expect "a missing firewall table is a warning, not silence" 0 "table 'inet casavpn' is not loaded"

reset_local; python3 "$ROOT/scripts/lib/set_min_client_ver.py" --db "$DB" --version 1.2.0 >/dev/null; lrun
expect "a wrong minClientVer is critical" 1 "minClientVer"
reset_local
sqlite3 "$DB" "update settings set value='{\"outbounds\":[{\"tag\":\"blocked\",\"protocol\":\"blackhole\"}],\"routing\":{\"rules\":[{\"outboundTag\":\"blocked\",\"ip\":[\"geoip:private\"]}]}}' where key='xrayTemplateConfig';"; lrun
expect "a template without the torrent block is critical" 1 "bittorrent is not blocked"
reset_local; sqlite3 "$DB" "delete from settings;"; lrun
expect "no stored template: panel defaults, flagged as unverified" 0 "block rules UNVERIFIED"
reset_local; rm -f "${DB:?}"; lrun
expect "no database is critical" 1 "no 3x-ui database"

reset_local; find "$BK" -type f -delete; lrun
expect "no recent backup is critical" 1 "no backup newer than 3 days"
reset_local; find "$BK" -type f -delete; touch -t 202001010000 "$BK/casavpn-20200101T000000Z.tar.zst.age"; lrun
expect "only an old backup is critical" 1 "no backup newer than 3 days"

reset_local; FAKE_DNS_IP=203.0.113.9; export FAKE_DNS_IP; lrun
expect "DNS not pointing at this host is critical" 1 "casavpn-ddns --force"

reset_local; mkdir -p "$T/le2/vpn.example.com"
openssl req -x509 -newkey rsa:2048 -nodes -days 5 -subj "/CN=vpn.example.com" \
  -keyout "$T/le2/vpn.example.com/k.pem" -out "$T/le2/vpn.example.com/fullchain.pem" >/dev/null 2>&1
OUT="$(env PATH="$BIN:$PATH" CASAVPN_ENV="$T/test.env" CASAVPN_DB="$DB" CASAVPN_LE_DIR="$T/le2" CASAVPN_BACKUP_DEST="$BK" "$HC" --local 2>&1)"; RC=$?
expect "a certificate about to expire is critical" 1 "renewal is failing"

OUT="$(env PATH="$BIN:$PATH" CASAVPN_ENV=/nonexistent "$HC" --local 2>&1)"; RC=$?
expect "no hostname anywhere is a usage error" 2 "No hostname"
OUT="$(env PATH="$BIN:$PATH" CASAVPN_ENV=/nonexistent "$HC" --bogus 2>&1)"; RC=$?
expect "an unknown argument is a usage error" 2 "unknown argument"

echo "healthcheck.sh (remote)"
rrun() { OUT="$(env PATH="$BIN:$PATH" CASAVPN_ENV="$T/test.env" "$HC" --ssh admin@192.0.2.10 "$@" 2>&1)"; RC=$?; }
reset_remote() { unset FAKE_DNS_IP FAKE_PUBLIC_IP FAKE_WEB_CODE FAKE_NC_CLOSED FAKE_CERT_CN FAKE_BAD_UNITS FAKE_SSH_DOWN; }
reset_remote; FAKE_NC_CLOSED="2053 2096 22"; export FAKE_NC_CLOSED; rrun
expect "a healthy deployment passes" 0 "All critical checks passed"
said "  ...and reports closed management ports" "port 22 is closed"

reset_remote; FAKE_DNS_IP=203.0.113.9; export FAKE_DNS_IP; rrun
expect "DNS differing from the Pi's public IP is critical" 1 "casavpn-ddns --force"
reset_remote; FAKE_NC_CLOSED="443"; export FAKE_NC_CLOSED; rrun
expect "a closed VPN port is critical" 1 "unreachable: check the router port forward"
reset_remote; FAKE_CERT_CN="something.else.test"; export FAKE_CERT_CN; rrun
expect "a wrong camouflage certificate is critical" 1 "Reality may be misconfigured"
reset_remote; FAKE_WEB_CODE=000; export FAKE_WEB_CODE; rrun
expect "no HTTPS answer on the web port is critical" 1 "no HTTPS response"
reset_remote; FAKE_WEB_CODE=200; export FAKE_WEB_CODE; rrun
expect "HTTP 200 on the web root is flagged for review" 0 "is the panel reachable"
reset_remote; FAKE_BAD_UNITS="nginx"; export FAKE_BAD_UNITS; rrun
expect "a stopped service on the Pi is critical" 1 "nginx is NOT active"
reset_remote; FAKE_SSH_DOWN=1; export FAKE_SSH_DOWN; rrun
expect "SSH down skips host checks with a warning" 0 "cannot SSH"
reset_remote
printf 'CASAVPN_DOMAIN=vpn.example.com\n' >"$T/notarget.env"
OUT="$(env PATH="$BIN:$PATH" CASAVPN_ENV="$T/notarget.env" "$HC" 2>&1)"; RC=$?
expect "no Reality target anywhere is a usage error, not a default" 2 "No Reality target"
OUT="$(env PATH="$BIN:$PATH" CASAVPN_ENV="$T/notarget.env" "$HC" --sni www.example.net 2>&1)"; RC=$?
expect "--sni supplies the target when the env file has none" 0 "genuine www.example.net certificate"
reset_remote
OUT="$(env PATH="$BIN:$PATH" CASAVPN_ENV="$T/test.env" "$HC" 2>&1)"; RC=$?
expect "without an SSH target the host checks are skipped, loudly" 0 "no --ssh target"
said "  ...and DNS correctness is called UNVERIFIED" "UNVERIFIED"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
