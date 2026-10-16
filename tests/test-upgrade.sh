#!/usr/bin/env bash
#
# Tests for scripts/upgrade.sh and scripts/rollback.sh against a fake 3x-ui
# tree, a real sqlite database and fake systemctl. No root, no network.

# shellcheck disable=SC2016
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Helpers (sha256_of, xui_arch) first, so the test's own ok/bad below win.
# shellcheck source=scripts/lib/common.sh
. "$ROOT/scripts/lib/common.sh"
UP="$ROOT/scripts/upgrade.sh"
RB="$ROOT/scripts/rollback.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/casavpn-upgrade-test.XXXXXXXX")"
LISTENER=""
cleanup() { [ -z "$LISTENER" ] || kill "$LISTENER" 2>/dev/null; rm -rf "${T:?}"; }
trap cleanup EXIT

for tool in sqlite3 python3 tar; do
  command -v "$tool" >/dev/null 2>&1 || { echo "$tool missing, skipping upgrade tests"; exit 0; }
done

pass=0; fail=0; OUT=""; RC=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; printf '%s\n' "$OUT" | tail -n 15 | sed 's/^/       /'; }
expect() { # <name> <rc> [pattern]
  if [ "$RC" -ne "$2" ]; then bad "$1 (rc=$RC, want $2)"; return; fi
  if [ -n "${3:-}" ] && ! grep -q -- "$3" <<<"$OUT"; then bad "$1 (output lacks: $3)"; return; fi
  ok "$1"
}
yes() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

# --- a free port with a listener, and one with none ---------------------------------
read -r OPEN_PORT CLOSED_PORT < <(python3 - <<'PY'
import socket
a = socket.socket(); a.bind(("127.0.0.1", 0)); b = socket.socket(); b.bind(("127.0.0.1", 0))
print(a.getsockname()[1], b.getsockname()[1])
PY
)
python3 - "$OPEN_PORT" <<'PY' &
import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(16)
while True:
    c, _ = s.accept(); c.close()
PY
LISTENER=$!; disown
sleep 0.5

# --- the fake host -------------------------------------------------------------------
BIN="$T/bin"; mkdir -p "$BIN"
mk() { printf '%s\n' "$2" >"$BIN/$1"; chmod +x "$BIN/$1"; }
mk id '#!/bin/sh
if [ "$1" = "-u" ]; then echo 0; else /usr/bin/id "$@"; fi'
mk systemctl '#!/bin/sh
echo "$@" >>"$FAKE_SYSTEMCTL_LOG"'
mk casavpn-healthcheck '#!/bin/sh
echo "healthcheck ran"'
export FAKE_SYSTEMCTL_LOG="$T/systemctl.log"

arch="$(xui_arch 2>/dev/null || echo amd64)"
make_tree() { # <dir> <version> <bundled core version>: a fake installed 3x-ui tree
  mkdir -p "$1/bin"
  printf '#!/bin/sh\necho "x-ui %s"\n' "$2" >"$1/x-ui"; chmod +x "$1/x-ui"
  printf '#!/bin/sh\necho "Xray %s (bundled)"\n' "$3" >"$1/bin/xray-linux-$arch"; chmod +x "$1/bin/xray-linux-$arch"
}
XUI="$T/usr/local/x-ui"
make_tree "$XUI" 1.0.0 26.2.0

# the new release as a tarball, with a unit file of its own and a newer bundled core
NEW="$T/new/x-ui"; make_tree "$NEW" 2.0.0 26.10.10
printf '[Service]\nExecStart=%s/x-ui\n# new unit\n' "$XUI" >"$NEW/x-ui.service.debian"
tar -czf "$T/new.tar.gz" -C "$T/new" x-ui
SUM="$(sha256_of "$T/new.tar.gz")"
write_pin() {
  printf 'XUI_VERSION=v2.0.0\nXUI_SHA256_AMD64=%s\nXUI_SHA256_ARM64=%s\nXUI_REPO=example/x-ui\n' "$1" "$1" >"$T/pin.env"
}
write_pin "$SUM"
# the pinned Xray core: a zip with a fake `xray`, and its pin file
zipname=Xray-linux-64.zip; [ "$arch" != arm64 ] || zipname=Xray-linux-arm64-v8a.zip
mkzip() { # <zip> <version the fake core reports>
  python3 -I - "$1" "$2" <<'PY2'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1], "w")
z.writestr("xray", '#!/bin/sh\necho "Xray %s (pinned)"\n' % sys.argv[2])
z.writestr("geoip.dat", "not the binary")
z.close()
PY2
}
mkdir -p "$T/served"; mkzip "$T/served/$zipname" 26.7.28
CSUM="$(sha256_of "$T/served/$zipname")"
write_core_pin() { # <hash>
  printf 'XRAY_CORE_VERSION=v26.7.28\nXRAY_CORE_SHA256_AMD64=%s\nXRAY_CORE_SHA256_ARM64=%s\nXRAY_CORE_REPO=example/core\n' "$1" "$1" >"$T/core-pin.env"
}
write_core_pin "$CSUM"
# a curl that serves $T/served and logs the URLs it is asked for
mkdir -p "$T/curlbin"
cat >"$T/curlbin/curl" <<'SH'
#!/bin/sh
out=""; url=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac; done
echo "$url" >>"$FAKE_CURL_LOG"
[ -n "$out" ] && [ -r "$FAKE_SERVED/$(basename "$url")" ] || exit 22
cp "$FAKE_SERVED/$(basename "$url")" "$out"
SH
chmod +x "$T/curlbin/curl"
export FAKE_CURL_LOG="$T/curl.log" FAKE_SERVED="$T/served"

DB="$T/etc/x-ui/x-ui.db"; mkdir -p "$(dirname "$DB")" "$T/etc/systemd"
make_db() {
  rm -f "$DB" "$DB-wal" "$DB-shm"
  python3 - "$DB" <<'PY'
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute("CREATE TABLE inbounds (id INTEGER PRIMARY KEY, remark TEXT, port INTEGER, protocol TEXT, enable INTEGER, settings TEXT, stream_settings TEXT)")
db.execute("CREATE TABLE settings (id INTEGER PRIMARY KEY, key TEXT, value TEXT)")
stream = {"security": "reality", "realitySettings": {"minClientVer": ""}}
db.execute("INSERT INTO inbounds VALUES (1, 'main', 443, 'vless', 1, '{\"clients\":[{\"email\":\"alice\"}]}', ?)", (json.dumps(stream),))
db.execute("INSERT INTO settings (key, value) VALUES ('webListen', '')")
db.commit()
PY
}
make_db
printf '[Service]\nExecStart=%s/x-ui\n# old unit\n' "$XUI" >"$T/etc/systemd/x-ui.service"
printf 'CASAVPN_DOMAIN=vpn.example.com\nCASAVPN_PANEL_PORT=%s\nCASAVPN_MIN_CLIENT_VER=1.8.0\n' "$OPEN_PORT" >"$T/test.env"

OFFLINE_CORE=1   # 0: let the script download the core through the fake curl
run() { # <script> args...
  local script="$1"; shift
  local extra=()
  if [ "$script" = "$UP" ] && [ "$OFFLINE_CORE" = 1 ]; then extra=(--offline-xray "$T/served/$zipname"); fi
  : >"$FAKE_SYSTEMCTL_LOG"; : >"$FAKE_CURL_LOG"
  OUT="$(env PATH="$T/curlbin:$BIN:$PATH" CASAVPN_ENV="$T/test.env" CASAVPN_XUI_DIR="$XUI" CASAVPN_DB="$DB" \
    CASAVPN_STATE_DIR="$T/state" CASAVPN_SYSTEMD_DIR="$T/etc/systemd" CASAVPN_XUI_PIN="$T/pin.env" CASAVPN_XRAY_PIN="$T/core-pin.env" \
    CASAVPN_PANEL_WAIT=3 "$script" --env "$T/test.env" ${extra[@]+"${extra[@]}"} "$@" 2>&1)"; RC=$?
}
ver() { "$1/x-ui" | awk '{print $2}'; }
core() { "$1/bin/xray-linux-$arch" | awk '{print $2}'; }   # the version a fake core reports

echo "casavpn-upgrade"
run "$UP" --dry-run --offline-xui "$T/new.tar.gz"
expect "--dry-run prints the plan" 0 "would stop x-ui"
yes "  ...and changes nothing" test "$(ver "$XUI")" = 1.0.0
yes "  ...and never touched systemctl" test ! -s "$FAKE_SYSTEMCTL_LOG"

write_pin "0000000000000000000000000000000000000000000000000000000000000000"
run "$UP" --yes --no-backup --offline-xui "$T/new.tar.gz"
expect "a tarball that does not match the pin is refused" 1 "does not match the pinned value"
yes "  ...the installed tree is untouched" test "$(ver "$XUI")" = 1.0.0
yes "  ...x-ui was never stopped" bash -c "! grep -q '^stop x-ui' '$FAKE_SYSTEMCTL_LOG'"
write_pin "$SUM"

run "$UP" --yes --no-backup --offline-xui "$T/new.tar.gz"
expect "a good upgrade succeeds" 0 "x-ui 2.0.0 is up"
yes "  ...the new tree is installed" test "$(ver "$XUI")" = 2.0.0
yes "  ...the old tree is kept aside" bash -c "ls -d '$T'/usr/local/x-ui.bak-1.0.0-* >/dev/null 2>&1"
yes "  ...the database was snapshotted" bash -c "test -s '$T'/state/latest/x-ui.db"
yes "  ...the unit of the release replaced the old one" grep -q "new unit" "$T/etc/systemd/x-ui.service"
yes "  ...the old unit is saved for the rollback" grep -q "old unit" "$T/state/latest/x-ui.service"
yes "  ...minClientVer was re-asserted" bash -c "sqlite3 '$DB' 'select stream_settings from inbounds' | grep -q '\"minClientVer\": \"1.8.0\"'"
yes "  ...the panel is bound to loopback" bash -c "test \"\$(sqlite3 '$DB' \"select value from settings where key='webListen'\")\" = 127.0.0.1"
yes "  ...subscriptions are bound to loopback" bash -c "test \"\$(sqlite3 '$DB' \"select value from settings where key='subListen'\")\" = 127.0.0.1"
expect "  ...the healthcheck ran" 0 "healthcheck ran"
expect "  ...and it tells you to test an old client" 0 "OLDEST client"
expect "  ...and a non-Xray client on mobile data" 0 "Shadowrocket"
yes "  ...the pinned Xray core replaced the one bundled with the new panel" test "$(core "$XUI")" = 26.7.28
yes "  ...the bundled core is kept next to it" test "$("$XUI/bin/xray-linux-$arch.bundled" | awk '{print $2}')" = 26.10.10
yes "  ...no .new file is left behind" bash -c "! ls '$XUI'/bin/*.new >/dev/null 2>&1"
expect "  ...the xray version is printed" 0 "xray core: 26.7.28"

run "$UP" --yes --no-backup --offline-xui "$T/new.tar.gz"
expect "running it again at the same version does nothing" 0 "already at 2.0.0"

echo "casavpn-rollback"
# a client added after the upgrade must disappear with the restored snapshot
sqlite3 "$DB" "update inbounds set settings='{\"clients\":[{\"email\":\"alice\"},{\"email\":\"newcomer\"}]}'"
run "$RB" --yes
expect "rollback succeeds" 0 "x-ui is up again"
yes "  ...the old tree is back" test "$(ver "$XUI")" = 1.0.0
yes "  ...with the core it had" test "$(core "$XUI")" = 26.2.0
yes "  ...the failed tree is kept" bash -c "ls -d '$T'/usr/local/x-ui.failed-* >/dev/null 2>&1"
yes "  ...the old unit is back" grep -q "old unit" "$T/etc/systemd/x-ui.service"
yes "  ...the database snapshot is back (newcomer is gone)" bash -c "! sqlite3 '$DB' 'select settings from inbounds' | grep -q newcomer"
yes "  ...the database in use before is kept" bash -c "ls '$DB'.pre-rollback-* >/dev/null 2>&1"
run "$RB" --yes
expect "a second rollback has nothing to roll back" 1 "nothing to roll back"

echo "casavpn-upgrade: automatic rollback"
make_db
run "$UP" --yes --no-backup --offline-xui "$T/new.tar.gz"
expect "set-up: upgrade again on the open port" 0 "x-ui 2.0.0 is up"
run "$RB" --yes
expect "set-up: back to 1.0.0" 0 "x-ui is up again"
printf 'CASAVPN_DOMAIN=vpn.example.com\nCASAVPN_PANEL_PORT=%s\n' "$CLOSED_PORT" >"$T/test.env"
make_db
run "$UP" --yes --no-backup --offline-xui "$T/new.tar.gz"
yes "the panel never answering rolls the upgrade back by itself" test "$(ver "$XUI")" = 1.0.0
expect "  ...and says so" 0 "rolling back"

echo "casavpn-upgrade: Xray core pin"
printf 'CASAVPN_DOMAIN=vpn.example.com\nCASAVPN_PANEL_PORT=%s\n' "$OPEN_PORT" >"$T/test.env"
make_db
yes "set-up: the tree is at 1.0.0 with its own core" test "$(ver "$XUI")$(core "$XUI")" = 1.0.026.2.0
write_core_pin "0000000000000000000000000000000000000000000000000000000000000000"
run "$UP" --yes --no-backup --offline-xui "$T/new.tar.gz"
expect "a core zip that does not match the pin is refused" 1 "Xray core download .* does not match the pinned value"
yes "  ...the installed tree is untouched" test "$(ver "$XUI")" = 1.0.0
yes "  ...x-ui was never stopped" bash -c "! grep -q '^stop x-ui' '$FAKE_SYSTEMCTL_LOG'"
run "$UP" --yes --no-backup --offline-xui "$T/new.tar.gz" --offline-xray "$T/new.tar.gz"
expect "a file that is not the core zip is refused too" 1 "does not match the pinned value"
write_core_pin "$CSUM"

OFFLINE_CORE=0
run "$UP" --yes --no-backup --offline-xui "$T/new.tar.gz"
expect "without --offline-xray the core is downloaded" 0 "x-ui 2.0.0 is up"
yes "  ...from the pinned repo and tag" grep -qx "https://github.com/example/core/releases/download/v26.7.28/$zipname" "$FAKE_CURL_LOG"
yes "  ...and installed" test "$(core "$XUI")" = 26.7.28
OFFLINE_CORE=1
run "$RB" --yes
expect "set-up: back to 1.0.0 after the pinned upgrade" 0 "x-ui is up again"
yes "  ...rollback restores the old core as well" test "$(core "$XUI")" = 26.2.0

printf 'CASAVPN_DOMAIN=vpn.example.com\nCASAVPN_PANEL_PORT=%s\nCASAVPN_XRAY_CORE=bundled\n' "$OPEN_PORT" >"$T/test.env"
make_db
run "$UP" --yes --no-backup --offline-xui "$T/new.tar.gz"
expect "CASAVPN_XRAY_CORE=bundled upgrades the panel and keeps its core" 0 "x-ui 2.0.0 is up"
yes "  ...the core is the one the new panel bundles" test "$(core "$XUI")" = 26.10.10
yes "  ...no .bundled copy is made" test ! -e "$XUI/bin/xray-linux-$arch.bundled"
yes "  ...and the core zip was never requested" bash -c "! grep -q Xray '$FAKE_CURL_LOG'"
run "$UP" --yes --offline-xui "$T/new.tar.gz"
expect "  ...running again leaves it alone" 0 "using the bundled one"

printf 'CASAVPN_DOMAIN=vpn.example.com\nCASAVPN_PANEL_PORT=%s\n' "$OPEN_PORT" >"$T/test.env"
run "$UP" --dry-run
expect "at the pinned panel version, --dry-run plans the core change" 0 "would download v26.7.28"
yes "  ...and changes nothing" test "$(core "$XUI")" = 26.10.10
run "$UP" --yes
expect "at the pinned panel version, the core pin is still re-applied" 0 "Xray core is now 26.7.28"
yes "  ...the core is pinned" test "$(core "$XUI")" = 26.7.28
yes "  ...the bundled one is kept" test "$("$XUI/bin/xray-linux-$arch.bundled" | awk '{print $2}')" = 26.10.10
yes "  ...x-ui was restarted" grep -q '^restart x-ui' "$FAKE_SYSTEMCTL_LOG"
yes "  ...the tree was not swapped" bash -c "! ls -d '$T'/usr/local/x-ui.bak-2.0.0-* >/dev/null 2>&1"
expect "  ...and it asks for a Shadowrocket test" 0 "Test a non-Xray client"
run "$UP" --yes
expect "running it again: the core is already at the pin" 0 "already at the pinned 26.7.28"
yes "  ...x-ui was not restarted" bash -c "! grep -q '^restart x-ui' '$FAKE_SYSTEMCTL_LOG'"

printf 'CASAVPN_DOMAIN=vpn.example.com\nCASAVPN_PANEL_PORT=%s\nCASAVPN_XRAY_CORE=bundled\n' "$OPEN_PORT" >"$T/test.env"
run "$UP" --yes
expect "switching to the opt-out puts the bundled core back" 0 "back to the bundled one"
yes "  ...the core is the bundled 26.10.10 again" test "$(core "$XUI")" = 26.10.10

printf 'CASAVPN_DOMAIN=vpn.example.com\nCASAVPN_PANEL_PORT=%s\nCASAVPN_XRAY_CORE=latest\n' "$OPEN_PORT" >"$T/test.env"
run "$UP" --yes
expect "an unknown CASAVPN_XRAY_CORE value is refused" 1 "CASAVPN_XRAY_CORE 'latest' is unknown"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
