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

make_tree() { # <dir> <version> : a fake installed 3x-ui tree
  mkdir -p "$1/bin"
  printf '#!/bin/sh\necho "x-ui %s"\n' "$2" >"$1/x-ui"; chmod +x "$1/x-ui"
}
XUI="$T/usr/local/x-ui"
make_tree "$XUI" 1.0.0

# the new release as a tarball, with a unit file of its own
NEW="$T/new/x-ui"; make_tree "$NEW" 2.0.0
printf '[Service]\nExecStart=%s/x-ui\n# new unit\n' "$XUI" >"$NEW/x-ui.service.debian"
tar -czf "$T/new.tar.gz" -C "$T/new" x-ui
SUM="$(sha256_of "$T/new.tar.gz")"
arch="$(xui_arch 2>/dev/null || echo amd64)"
write_pin() {
  printf 'XUI_VERSION=v2.0.0\nXUI_SHA256_AMD64=%s\nXUI_SHA256_ARM64=%s\nXUI_REPO=example/x-ui\n' "$1" "$1" >"$T/pin.env"
}
write_pin "$SUM"
: "$arch"

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

run() { # <script> args...
  local script="$1"; shift
  : >"$FAKE_SYSTEMCTL_LOG"
  OUT="$(env PATH="$BIN:$PATH" CASAVPN_ENV="$T/test.env" CASAVPN_XUI_DIR="$XUI" CASAVPN_DB="$DB" \
    CASAVPN_STATE_DIR="$T/state" CASAVPN_SYSTEMD_DIR="$T/etc/systemd" CASAVPN_XUI_PIN="$T/pin.env" \
    CASAVPN_PANEL_WAIT=3 "$script" --env "$T/test.env" "$@" 2>&1)"; RC=$?
}
ver() { "$1/x-ui" | awk '{print $2}'; }

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

run "$UP" --yes --no-backup --offline-xui "$T/new.tar.gz"
expect "running it again at the same version does nothing" 0 "already at 2.0.0"

echo "casavpn-rollback"
# a client added after the upgrade must disappear with the restored snapshot
sqlite3 "$DB" "update inbounds set settings='{\"clients\":[{\"email\":\"alice\"},{\"email\":\"newcomer\"}]}'"
run "$RB" --yes
expect "rollback succeeds" 0 "x-ui is up again"
yes "  ...the old tree is back" test "$(ver "$XUI")" = 1.0.0
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

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
