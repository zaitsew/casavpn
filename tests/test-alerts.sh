#!/usr/bin/env bash
#
# Offline tests for scripts/casavpn-alerts and scripts/lib/host_probe.py.
#
# Every input is a fixture: a throwaway SQLite database shaped like 3x-ui's
# (client_traffics, inbounds, settings, api_tokens), a backup directory, a boot id
# file, a fixed clock (CASAVPN_ALERTS_NOW), and PATH stubs for openssl, ss,
# systemctl, df and curl. Most cases use --dry-run, which prints each event as
# JSON; a few run for real against the stub curl to check the request, the
# dedupe key, the state files and the exit status.

# shellcheck disable=SC2016

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/casavpn-alerts"
PROBE="$ROOT/scripts/lib/host_probe.py"
T="$(mktemp -d "${TMPDIR:-/tmp}/casavpn-alerts-test.XXXXXXXX")"
trap 'rm -rf "${T:?}"' EXIT

for tool in python3 jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "$tool missing, skipping alerts tests"; exit 0; }
done

pass=0; fail=0
OUT=""; RC=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; printf '%s\n' "$OUT" | tail -n 12 | sed 's/^/       /'; }
rc_is() { if [ "$RC" -eq "$2" ]; then ok "$1"; else bad "$1 (rc=$RC, want $2)"; fi; }
eq()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
said()  { if grep -q -- "$2" <<<"$OUT"; then ok "$1"; else bad "$1 (output lacks: $2)"; fi; }

NOW="$(python3 -c 'import calendar; print(calendar.timegm((2026, 12, 1, 0, 0, 0)))')"
DAY=86400
GB=1073741824
LIMIT=$((10 * GB))

# --- stubs ----------------------------------------------------------------------
BIN="$T/bin"; mkdir -p "$BIN"
mk() { printf '%s\n' "$2" >"$BIN/$1"; chmod +x "$BIN/$1"; }
mk openssl '#!/usr/bin/env bash
# openssl x509 -noout -enddate -in <file>: answers $FAKE/enddate, logs the file.
for a in "$@"; do prev_is_in=$last; last=$a; [ "$prev_is_in" = "-in" ] && echo "$a" >>"$FAKE/openssl.log"; done
[ -f "$FAKE/openssl_fail" ] && exit 1
printf "notAfter=%s\n" "$(cat "$FAKE/enddate")"'
mk ss '#!/usr/bin/env bash
cat "$FAKE/ss"'
mk systemctl '#!/usr/bin/env bash
# systemctl is-active --quiet x-ui
[ -f "$FAKE/xui_down" ] && exit 3
exit 0'
mk df '#!/usr/bin/env bash
[ -f "$FAKE/df_fail" ] && exit 1
printf "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/root 100 %s %s %s%% /\n" "$(cat "$FAKE/df")" "$((100 - $(cat "$FAKE/df")))" "$(cat "$FAKE/df")"'
mk curl '#!/usr/bin/env bash
# The relay: records the JSON body and the stdin config; answers $FAKE/code (default 202).
want_code=0; data=""; url=""; cfg=0
while [ $# -gt 0 ]; do
  case "$1" in -w) want_code=1; shift ;; --data-binary|-d) data="$2"; shift ;; -K) cfg=1 ;; http*) url="$1" ;; esac
  shift
done
[ "$cfg" = 1 ] && cat >"$FAKE/last_stdin"
printf "%s\t%s\n" "$url" "$data" >>"$FAKE/requests"
[ -f "$FAKE/down" ] && exit 7
code=202; [ -f "$FAKE/code" ] && code="$(cat "$FAKE/code")"
[ "$want_code" = 1 ] && printf "%s" "$code"
exit 0'
export PATH="$BIN:$PATH"

# --- fixtures -------------------------------------------------------------------
# mkdb <file>: client rows on stdin, "email|enable|up|down|total|expiry_ms" each.
cat >"$T/mkdb.py" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.executescript("""
CREATE TABLE client_traffics (id INTEGER PRIMARY KEY AUTOINCREMENT, inbound_id INTEGER, enable NUMERIC,
  email TEXT UNIQUE, up INTEGER, down INTEGER, expiry_time INTEGER, total INTEGER, reset INTEGER DEFAULT 0);
CREATE TABLE inbounds (id INTEGER PRIMARY KEY, enable NUMERIC, port INTEGER, remark TEXT);
CREATE TABLE settings (id INTEGER PRIMARY KEY, key TEXT, value TEXT);
CREATE TABLE api_tokens (id INTEGER PRIMARY KEY, name TEXT UNIQUE, token TEXT, scope TEXT);
INSERT INTO inbounds (enable, port, remark) VALUES (1, 443, 'main');
INSERT INTO settings (key, value) VALUES ('webBasePath', '/abc123secret/');
""")
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    email, enable, up, down, total, expiry = line.split("|")
    db.execute("INSERT INTO client_traffics (inbound_id, enable, email, up, down, total, expiry_time) VALUES (1,?,?,?,?,?,?)",
               (int(enable), email, int(up), int(down), int(total), int(expiry)))
db.commit()
PY
mkdb() { rm -f "$1"; python3 "$T/mkdb.py" "$1"; }
enddate_in() { # <seconds from NOW> -> openssl's text
  python3 -c 'import sys, time; print(time.strftime("%b %d %H:%M:%S %Y GMT", time.gmtime(int(sys.argv[1]))))' "$((NOW + $1))"
}
set_mtime() { python3 -c 'import os, sys; os.utime(sys.argv[1], (int(sys.argv[2]), int(sys.argv[2])))' "$1" "$2"; }
# new_case: a healthy host. Each test then breaks exactly one thing.
CASE=0
new_case() {
  C="$T/case.$((++CASE))"; FAKE="$C/fake"; STATE="$C/state"
  mkdir -p "$FAKE" "$C/backups" "$C/le/live/vpn.example.com" "$STATE"
  export FAKE
  : >"$C/le/live/vpn.example.com/fullchain.pem"
  enddate_in $((60 * DAY)) >"$FAKE/enddate"
  printf 'State Recv-Q Send-Q Local-Address:Port Peer-Address:Port Process\nLISTEN 0 4096 0.0.0.0:443 0.0.0.0:*\nLISTEN 0 4096 127.0.0.1:2053 0.0.0.0:*\n' >"$FAKE/ss"
  echo 40 >"$FAKE/df"
  printf 'alice|1|1000|1000|%s|0\n' "$LIMIT" | mkdb "$C/x-ui.db"
  : >"$C/backups/casavpn-20261130T033000Z.tar.zst.age"; set_mtime "$C/backups/casavpn-20261130T033000Z.tar.zst.age" $((NOW - 5 * 3600))
  echo "boot-aaaa" >"$C/boot_id"; echo "boot-aaaa" >"$STATE/alerts-boot-id"
  printf 'CASAVPN_DOMAIN=vpn.example.com\nCASAVPN_VPN_PORT=443\nAGE_RECIPIENT=\nCASAVPN_RELAY_URL=https://relay.example.com\nCASAVPN_RELAY_TOKEN=hosttoken123\n' >"$C/env"
}
alerts() { # alerts <args...>: set OUT and RC
  OUT="$(env CASAVPN_ENV_FILE="$C/env" CASAVPN_ALERTS_STATE_DIR="$STATE" CASAVPN_DB="$C/x-ui.db" \
      CASAVPN_LE_DIR="$C/le" CASAVPN_BACKUP_DEST="$C/backups" CASAVPN_ALERTS_BOOT_ID_FILE="$C/boot_id" \
      CASAVPN_ALERTS_NOW="$NOW" "${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}" bash "$SCRIPT" "$@" 2>&1)"; RC=$?
}
EXTRA_ENV=()
# events: the JSON of every event a dry run printed, one per line.
events() { grep '^would send: ' <<<"$OUT" | sed 's/^would send: //'; }
n_events() { events | grep -c . || true; }
ev() { # ev <dedupe key> <jq filter>: a field of the event with that key
  events | jq -r --arg k "$1" "select(.dedupe == \$k) | $2"
}
has_ev() { events | jq -e --arg k "$1" 'select(.dedupe == $k)' >/dev/null 2>&1; }
expect_ev() { if has_ev "$2"; then ok "$1"; else bad "$1 (no event with key $2)"; fi; }
expect_no_ev() { if has_ev "$2"; then bad "$1 (unexpected event $2)"; else ok "$1"; fi; }
expect_none() { eq "$1" "$(n_events)" 0; }
sent() { cut -f2 "$FAKE/requests" 2>/dev/null; }

echo "a healthy host"
new_case; alerts --dry-run
rc_is "exits 0" 0
expect_none "raises nothing"
said "  ...and says each check passed" "cert: .*60 days left; ok"
eq "  ...and writes nothing in dry-run mode: no first-run marker" "$([ -e "$STATE/alerts-first-run" ] && echo yes || echo no)" no

echo "certificate"
new_case; enddate_in $((14 * DAY)) >"$FAKE/enddate"; alerts --dry-run
expect_none "exactly 14 days left: no alert"
new_case; enddate_in $((14 * DAY - 1)) >"$FAKE/enddate"; alerts --dry-run
day="$(python3 -c 'import sys, time; print(time.strftime("%Y-%m-%d", time.gmtime(int(sys.argv[1]))))' $((NOW + 14 * DAY - 1)))"
expect_ev "14 days minus a second: warning" "cert.expiring:$day"
eq "  ...severity" "$(ev "cert.expiring:$day" .severity)" warning
eq "  ...title says 13 days" "$(ev "cert.expiring:$day" .title)" "Certificate expires in 13 days"
eq "  ...kind" "$(ev "cert.expiring:$day" .kind)" cert.expiring
new_case; enddate_in $((3 * DAY)) >"$FAKE/enddate"; alerts --dry-run
day="$(python3 -c 'import sys, time; print(time.strftime("%Y-%m-%d", time.gmtime(int(sys.argv[1]))))' $((NOW + 3 * DAY)))"
eq "exactly 3 days left: still a warning" "$(ev "cert.expiring:$day" .severity)" warning
new_case; enddate_in $((3 * DAY - 1)) >"$FAKE/enddate"; alerts --dry-run
day="$(python3 -c 'import sys, time; print(time.strftime("%Y-%m-%d", time.gmtime(int(sys.argv[1]))))' $((NOW + 3 * DAY - 1)))"
eq "3 days minus a second: critical" "$(ev "cert.expiring:$day:crit" .severity)" critical
new_case; enddate_in 3600 >"$FAKE/enddate"; alerts --dry-run
eq "under a day: the title says so" "$(events | jq -r .title)" "Certificate expires in under a day"
new_case; enddate_in -1 >"$FAKE/enddate"; alerts --dry-run
eq "expired: critical" "$(events | jq -r .severity)" critical
eq "  ...title" "$(events | jq -r .title)" "Certificate expired"
new_case; printf 'Dec  5 10:00:00 2026 GMT\n' >"$FAKE/enddate"; alerts --dry-run
expect_ev "a space-padded day (\"Dec  5\") is parsed" "cert.expiring:2026-12-05"
eq "  ...to 4 days" "$(ev cert.expiring:2026-12-05 .title)" "Certificate expires in 4 days"
new_case; alerts --dry-run
eq "the certificate read is the one nginx serves" "$(cat "$FAKE/openssl.log")" "$C/le/live/vpn.example.com/fullchain.pem"
new_case; rm "$C/le/live/vpn.example.com/fullchain.pem"; alerts --dry-run
rc_is "no certificate yet: skipped, not a failure" 0
said "  ...and says so" "does not exist yet; skipped"
new_case; touch "$FAKE/openssl_fail"; alerts --dry-run
rc_is "an unreadable certificate is a failed check (exit 1)" 1

echo "clients: traffic"
new_case
used90=$((LIMIT * 90 / 100)); used100=$LIMIT
{
  printf 'under89|1|%s|0|%s|0\n' $((used90 - 1)) "$LIMIT"
  printf 'at90|1|%s|0|%s|0\n' "$used90" "$LIMIT"
  printf 'at99|1|%s|0|%s|0\n' $((LIMIT - 1)) "$LIMIT"
  printf 'at100|1|%s|0|%s|0\n' "$used100" "$LIMIT"
  printf 'split|1|%s|%s|%s|0\n' $((used100 / 2)) $((used100 / 2 + 5)) "$LIMIT"
  printf 'unlimited|1|%s|%s|0|0\n' "$LIMIT" "$LIMIT"
  printf 'off90|0|%s|0|%s|0\n' "$used90" "$LIMIT"
  printf 'off100|0|%s|0|%s|0\n' "$used100" "$LIMIT"
} | mkdb "$C/x-ui.db"
alerts --dry-run
expect_no_ev "89.99 %: nothing" "client.traffic:under89:90"
expect_ev "exactly 90 %: warning" "client.traffic:at90:90"
eq "  ...severity" "$(ev client.traffic:at90:90 .severity)" warning
eq "  ...title" "$(ev client.traffic:at90:90 .title)" "at90 used 90 % of its traffic"
eq "  ...body shows used of limit" "$(ev client.traffic:at90:90 .body)" "at90 has used 9.0 GB of its 10.0 GB limit."
eq "99.99 %: warning" "$(ev client.traffic:at99:90 .severity)" warning
expect_no_ev "  ...and not critical" "client.traffic:at99:100"
eq "100 %: critical" "$(ev client.traffic:at100:100 .severity)" critical
expect_no_ev "  ...with no extra 90 % warning" "client.traffic:at100:90"
eq "up and down are added" "$(ev client.traffic:split:100 .severity)" critical
expect_no_ev "total 0 means unlimited: no alert" "client.traffic:unlimited:100"
expect_no_ev "a client switched off at 90 % is not nagged" "client.traffic:off90:90"
eq "a client switched off at 100 % is reported (the panel does that at the limit)" "$(ev client.traffic:off100:100 .severity)" critical
eq "  ...and nothing else fired" "$(n_events)" 5

echo "clients: expiry"
new_case
ms() { echo $(((NOW + $1) * 1000)); }
{
  printf 'in3d|1|0|0|0|%s\n' "$(ms $((3 * DAY)))"
  printf 'in3dminus|1|0|0|0|%s\n' "$(ms $((3 * DAY - 1)))"
  printf 'tomorrow|1|0|0|0|%s\n' "$(ms DAY)"
  printf 'tomorrowoff|0|0|0|0|%s\n' "$(ms DAY)"
  printf 'noexpiry|1|0|0|0|0\n'
  printf 'firstuse|1|0|0|0|-86400000\n'
  printf 'gone1h|0|0|0|0|%s\n' "$(ms -3600)"
  printf 'gone24h|0|0|0|0|%s\n' "$(ms $((-DAY)))"
  printf 'gone24hplus|0|0|0|0|%s\n' "$(ms $((-DAY - 1)))"
  printf 'gone3d|0|0|0|0|%s\n' "$(ms $((-3 * DAY)))"
} | mkdb "$C/x-ui.db"
alerts --dry-run
dd3="$(python3 -c 'import sys, time; print(time.strftime("%Y-%m-%d", time.gmtime(int(sys.argv[1]))))' $((NOW + 3 * DAY - 1)))"
expect_no_ev "exactly 3 days left: no alert yet" "client.expiring:in3d:$(python3 -c 'import sys, time; print(time.strftime("%Y-%m-%d", time.gmtime(int(sys.argv[1]))))' $((NOW + 3 * DAY)))"
expect_ev "3 days minus a second: warning" "client.expiring:in3dminus:$dd3"
eq "  ...severity" "$(ev "client.expiring:in3dminus:$dd3" .severity)" warning
expect_ev "tomorrow: warning" "client.expiring:tomorrow:2026-12-02"
eq "  ...title carries the date" "$(ev client.expiring:tomorrow:2026-12-02 .title)" "tomorrow expires on 2026-12-02"
expect_no_ev "a switched-off client is not warned" "client.expiring:tomorrowoff:2026-12-02"
eq "no expiry: nothing" "$(events | jq -r 'select(.title|test("noexpiry"))|.kind' | wc -l | tr -d ' ')" 0
eq "a negative expiry (starts on first use): nothing" "$(events | jq -r 'select(.title|test("firstuse"))|.kind' | wc -l | tr -d ' ')" 0
eq "expired an hour ago: critical" "$(ev client.expiring:gone1h:2026-11-30:expired .severity)" critical
eq "  ...title" "$(ev client.expiring:gone1h:2026-11-30:expired .title)" "gone1h has expired"
eq "expired exactly 24 h ago: still reported" "$(ev client.expiring:gone24h:2026-11-30:expired .severity)" critical
expect_no_ev "expired 24 h and a second ago: no longer reported" "client.expiring:gone24hplus:2026-11-29:expired"
eq "expired 3 days ago: not reported" "$(events | jq -r 'select(.title|test("gone3d"))|.kind' | wc -l | tr -d ' ')" 0

echo "clients: dedupe keys and names"
new_case
long1="$(printf 'a%.0s' $(seq 70))x"; long2="$(printf 'a%.0s' $(seq 70))y"
{
  printf '%s|1|%s|0|%s|0\n' "$long1" "$used90" "$LIMIT"
  printf '%s|1|%s|0|%s|0\n' "$long2" "$used90" "$LIMIT"
  printf 'weird "name" <1>|1|%s|0|%s|0\n' "$used90" "$LIMIT"
} | mkdb "$C/x-ui.db"
alerts --dry-run
keys="$(events | jq -r .dedupe)"
eq "three events" "$(n_events)" 3
eq "no key is longer than 64 characters" "$(awk '{ if (length($0) > 64) n++ } END { print n + 0 }' <<<"$keys")" 0
eq "two long names that share a prefix still get different keys" "$(sort -u <<<"$keys" | wc -l | tr -d ' ')" 3
eq "a key still starts with the kind and ends with the level" "$(grep -c '^client\.traffic:.*:90$' <<<"$keys")" 3
eq "quotes and angle brackets in a name stay valid JSON" "$(events | jq -r 'select(.title|test("weird")) | .title')" 'weird "name" <1> used 90 % of its traffic'
new_case; echo garbage >"$C/x-ui.db"; alerts --dry-run
rc_is "an unreadable panel database is a failed check (exit 1)" 1
said "  ...and the log names it" "clients: could not read the client list"
new_case; rm "$C/x-ui.db"; alerts --dry-run
rc_is "no panel database yet: skipped, exit 0" 0

echo "xray"
new_case; alerts --dry-run
expect_none "listening on the VPN port: ok"
new_case; printf 'State Recv-Q Send-Q Local-Address:Port Peer-Address:Port Process\nLISTEN 0 511 [::]:443 [::]:*\n' >"$FAKE/ss"; alerts --dry-run
expect_none "listening on IPv6 only: ok"
new_case; printf 'State Recv-Q Send-Q Local-Address:Port Peer-Address:Port Process\nLISTEN 0 4096 0.0.0.0:8443 0.0.0.0:*\nLISTEN 0 4096 0.0.0.0:4430 0.0.0.0:*\n' >"$FAKE/ss"; alerts --dry-run
expect_ev "only :8443 and :4430 listen, not :443: xray.down" "xray.down"
eq "  ...critical" "$(ev xray.down .severity)" critical
new_case; printf 'State Recv-Q Send-Q Local-Address:Port Peer-Address:Port Process\nESTAB 0 0 192.0.2.1:443 198.51.100.7:5000\n' >"$FAKE/ss"; alerts --dry-run
expect_ev "an established connection is not a listener" "xray.down"
new_case; printf 'State\n' >"$FAKE/ss"; touch "$FAKE/xui_down"; alerts --dry-run
expect_none "x-ui itself stopped: the Worker covers that, no alert"
new_case; printf 'State\n' >"$FAKE/ss"; python3 - "$C/x-ui.db" <<'PY'
import sqlite3, sys
d = sqlite3.connect(sys.argv[1]); d.execute("DELETE FROM inbounds"); d.commit()
PY
alerts --dry-run
expect_none "x-ui runs but no inbound exists yet (fresh install): no alert"
said "  ...and says why" "no enabled inbound on port 443 yet"
new_case; printf 'State\n' >"$FAKE/ss"; printf 'CASAVPN_VPN_PORT=8123\nCASAVPN_DOMAIN=vpn.example.com\n' >"$C/env"; alerts --dry-run
expect_none "a custom port with no inbound on it: no alert"
python3 - "$C/x-ui.db" <<'PY'
import sqlite3, sys
d = sqlite3.connect(sys.argv[1]); d.execute("INSERT INTO inbounds (enable, port) VALUES (1, 8123)"); d.commit()
PY
alerts --dry-run
expect_ev "  ...and with one on that port, alert" "xray.down"
said "  ...naming the configured port" "port 8123"

echo "backup"
new_case; set_mtime "$C/backups/casavpn-20261130T033000Z.tar.zst.age" $((NOW - 36 * 3600)); alerts --dry-run
expect_none "exactly 36 h old: ok"
new_case; set_mtime "$C/backups/casavpn-20261130T033000Z.tar.zst.age" $((NOW - 36 * 3600 - 1)); alerts --dry-run
expect_ev "36 h and a second: stale" "backup.stale:2026-11-29"
eq "  ...warning" "$(ev backup.stale:2026-11-29 .severity)" warning
eq "  ...title" "$(ev backup.stale:2026-11-29 .title)" "Backup is 36 hours old"
new_case; : >"$C/backups/casavpn-20261120T033000Z.tar.zst.age"; set_mtime "$C/backups/casavpn-20261120T033000Z.tar.zst.age" $((NOW - 2 * DAY))
set_mtime "$C/backups/casavpn-20261130T033000Z.tar.zst.age" $((NOW - 3600)); alerts --dry-run
expect_none "an old archive next to a fresh one: the newest counts"
new_case; rm "$C/backups"/*; : >"$C/backups/.casavpn-20261130T033000Z.partial"; : >"$C/backups/notes.txt"
set_mtime "$C/backups/.casavpn-20261130T033000Z.partial" $((NOW - 10)); AGE=age1placeholder
printf 'AGE_RECIPIENT=%s\nCASAVPN_RELAY_URL=https://relay.example.com\nCASAVPN_RELAY_TOKEN=hosttoken123\n' "$AGE" >"$C/env"
echo $((NOW - 2 * DAY)) >"$STATE/alerts-first-run"; alerts --dry-run
expect_ev "no archive, backups enabled, first check 2 days ago: stale (a .partial file is not a backup)" "backup.stale:none"
said "  ...says there is no backup" "No backup exists"
echo $((NOW - 3600)) >"$STATE/alerts-first-run"; alerts --dry-run
expect_none "no archive yet but the first check was an hour ago: wait for the 03:30 run"
new_case; rm -r "$C/backups"; alerts --dry-run
expect_none "backups not enabled (no directory, no AGE_RECIPIENT): skipped"
said "  ...and says so" "backups are not enabled"
new_case; : >"$C/backups/casavpn-20261129T033000Z.tar.gz.age"; set_mtime "$C/backups/casavpn-20261129T033000Z.tar.gz.age" $((NOW - 5 * DAY))
rm "$C/backups/casavpn-20261130T033000Z.tar.zst.age"; alerts --dry-run
expect_ev "a .tar.gz.age archive counts too" "backup.stale:2026-11-26"

echo "disk"
new_case; echo 90 >"$FAKE/df"; alerts --dry-run
expect_none "exactly 90 %: ok"
new_case; echo 91 >"$FAKE/df"; alerts --dry-run
expect_ev "91 %: disk.low" "disk.low"
eq "  ...warning" "$(ev disk.low .severity)" warning
eq "  ...title" "$(ev disk.low .title)" "Disk is 91 % full"
new_case; touch "$FAKE/df_fail"; alerts --dry-run
rc_is "df failing is a failed check (exit 1)" 1

echo "reboot"
new_case; alerts --dry-run
expect_none "same boot id: nothing"
new_case; echo "boot-bbbb" >"$C/boot_id"; alerts --dry-run
expect_ev "a new boot id: host.rebooted" "host.rebooted:boot-bbbb"
eq "  ...info" "$(ev host.rebooted:boot-bbbb .severity)" info
eq "  ...dry run keeps the old boot id" "$(cat "$STATE/alerts-boot-id")" boot-aaaa
new_case; rm "$STATE/alerts-boot-id"; echo "boot-bbbb" >"$C/boot_id"; alerts --dry-run
expect_none "first run (no state): nothing is reported"
new_case; rm "$STATE/alerts-boot-id"; alerts
rc_is "a real first run exits 0" 0
eq "  ...and records the boot id" "$(cat "$STATE/alerts-boot-id")" boot-aaaa
eq "  ...and sent nothing" "$([ -e "$FAKE/requests" ] && echo yes || echo no)" no
eq "  ...and wrote the first-run marker" "$([ -s "$STATE/alerts-first-run" ] && echo yes || echo no)" yes

echo "real runs: the request, the state, the exit status"
new_case; echo "boot-bbbb" >"$C/boot_id"; enddate_in $((2 * DAY)) >"$FAKE/enddate"; alerts
rc_is "events delivered: exit 0" 0
eq "two requests (certificate, reboot)" "$(wc -l <"$FAKE/requests" | tr -d ' ')" 2
eq "to the relay's events endpoint" "$(cut -f1 "$FAKE/requests" | sort -u)" "https://relay.example.com/v1/events"
eq "the reboot event carries its dedupe key" "$(sent | jq -r 'select(.kind=="host.rebooted") | .dedupe')" "host.rebooted:boot-bbbb"
eq "the certificate event is critical under 3 days" "$(sent | jq -r 'select(.kind=="cert.expiring") | .severity')" critical
eq "the host token is given to curl on stdin" "$(cat "$FAKE/last_stdin")" 'header = "Authorization: Bearer hosttoken123"'
eq "the delivered boot id is stored" "$(cat "$STATE/alerts-boot-id")" boot-bbbb
alerts
rc_is "run again: still exit 0" 0
eq "  ...the reboot is not reported twice" "$(sent | jq -r 'select(.kind=="host.rebooted") | .kind' | wc -l | tr -d ' ')" 1
new_case; echo "boot-bbbb" >"$C/boot_id"; echo 503 >"$FAKE/code"; alerts
rc_is "the relay answers 503: exit 1 (the unit shows failed)" 1
eq "  ...the boot id is NOT stored, so the next run retries" "$(cat "$STATE/alerts-boot-id")" boot-aaaa
said "  ...and the log says what failed" "delivery failed for 'host.rebooted:boot-bbbb'"
rm "$FAKE/code"; alerts
rc_is "the relay is back: delivered, exit 0" 0
eq "  ...and now the boot id is stored" "$(cat "$STATE/alerts-boot-id")" boot-bbbb
new_case; echo 91 >"$FAKE/df"; touch "$FAKE/down"; alerts
rc_is "the relay is unreachable: exit 1, not a crash" 1
said "  ...the other checks still ran" "done: 1 event(s), 1 failure(s)"

echo "ntfy"
new_case; printf 'NTFY_URL=https://ntfy.example.com/casavpn-EXAMPLE\n' >"$C/env"; echo 91 >"$FAKE/df"; alerts
rc_is "ntfy alone is enough" 0
eq "  ...and was used" "$(cut -f1 "$FAKE/requests")" "https://ntfy.example.com/casavpn-EXAMPLE"
alerts
eq "  ...a lasting condition is not pushed again 15 minutes later" "$(wc -l <"$FAKE/requests" | tr -d ' ')" 1
new_case; : >"$C/env"; echo 91 >"$FAKE/df"; alerts
rc_is "no channel at all: exit 0" 0
said "  ...and says there is nowhere to send to" "no alert channel"
eq "  ...and nothing was sent" "$([ -e "$FAKE/requests" ] && echo yes || echo no)" no

echo "arguments"
new_case; alerts --nonsense; rc_is "an unknown argument: exit 2" 2
alerts --help; rc_is "--help: exit 0" 0
said "  ...and prints the checks" "client.traffic"

echo "systemd units"
SVC="$ROOT/config/systemd/casavpn-alerts.service"; TMR="$ROOT/config/systemd/casavpn-alerts.timer"
for want in 'Type=oneshot' 'ExecStart=/usr/local/bin/casavpn-alerts' 'StateDirectory=casavpn' 'ProtectSystem=strict' 'NoNewPrivileges=true' 'AF_NETLINK'; do
  if grep -q -- "^$want\|^RestrictAddressFamilies=.*$want" "$SVC"; then ok "service has $want"; else bad "service lacks $want"; fi
done
if grep -q '^OnUnitActiveSec=15min$' "$TMR" && grep -q '^OnBootSec=' "$TMR" && grep -q '^WantedBy=timers.target$' "$TMR"; then ok "timer: after boot, then every 15 minutes, wanted by timers.target"; else bad "timer shape"; fi
state_dir="$(sed -n 's/^StateDirectory=//p' "$SVC")"
if grep -q "^ReadWritePaths=.*/var/lib/$state_dir" "$SVC"; then ok "the state directory is writable under ProtectSystem=strict"; else bad "the state directory is not in ReadWritePaths"; fi
if grep -q '/var/lib/casavpn' "$SCRIPT"; then ok "the script's default state directory is the unit's StateDirectory"; else bad "state directory mismatch"; fi

echo "host_probe.py"
new_case
eq "certdate" "$(python3 -I "$PROBE" certdate 'Dec 30 12:00:00 2026 GMT')" "$(python3 -c 'import calendar; print(calendar.timegm((2026,12,30,12,0,0)), "2026-12-30")')"
eq "setting returns a value" "$(python3 -I "$PROBE" setting "$C/x-ui.db" webBasePath)" "/abc123secret/"
eq "setting returns nothing for a missing key" "$(python3 -I "$PROBE" setting "$C/x-ui.db" nope)" ""
eq "token-exists: no" "$(python3 -I "$PROBE" token-exists "$C/x-ui.db" casavpn-app)" 0
python3 - "$C/x-ui.db" <<'PY'
import sqlite3, sys
d = sqlite3.connect(sys.argv[1]); d.execute("INSERT INTO api_tokens (name, token, scope) VALUES ('casavpn-app', 'hash', 'admin')"); d.commit()
PY
eq "token-exists: yes" "$(python3 -I "$PROBE" token-exists "$C/x-ui.db" casavpn-app)" 1
eq "quote encodes everything that is not unreserved" "$(python3 -I "$PROBE" quote 'a b&c=d/e?f#g%h+i~j_k.l-m')" 'a%20b%26c%3Dd%2Fe%3Ff%23g%25h%2Bi~j_k.l-m'
cp "$C/x-ui.db" "$C/ro.db"; before="$(cksum <"$C/ro.db")"
python3 -I "$PROBE" clients "$C/ro.db" >/dev/null
eq "reading never changes the database file" "$(cksum <"$C/ro.db")" "$before"
python3 -I "$PROBE" nonsense >/dev/null 2>&1; eq "an unknown command: exit 2" "$?" 2
python3 -I "$PROBE" clients "$C/missing.db" >/dev/null 2>&1; eq "a missing database is not created and fails with exit 1" "$?$([ -e "$C/missing.db" ] && echo created)" 1

printf '\nalerts tests: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
