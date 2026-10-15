#!/usr/bin/env bash
#
# Offline test of the backup chain: casavpn-backup -> (pull-backups.sh) ->
# restore-drill.sh, run against a fake root with a throwaway age keypair.
# Touches nothing outside a temp dir. Needs: age, sqlite3, tar, rsync, zstd|gzip.
# Runs on macOS and Linux.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REPO="$PWD"

for tool in age age-keygen sqlite3 tar rsync; do
  command -v "$tool" >/dev/null || { echo "SKIP/FAIL: $tool is required (brew install $tool / apt install $tool)"; exit 1; }
done

T="$(mktemp -d "${TMPDIR:-/tmp}/casavpn-backup-test.XXXXXXXX")"
export TMPDIR="$T"   # every script under test makes its temp dirs here, so leaks are visible
BG_PID=""
cleanup() {
  [[ -n "$BG_PID" ]] && kill "$BG_PID" 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT

PASS=0; FAILN=0
pass() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAILN=$((FAILN + 1)); printf 'FAIL %s\n' "$1"; }
check() { # check "name" cmd...
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi
}
expect() { # expect "name" WANT_RC GOT_RC
  if [[ "$3" -eq "$2" ]]; then pass "$1 (got $3)"; else fail "$1 (got $3, wanted $2)"; fi
}
count_files() { # count_files dir glob-pattern
  find "$1" -maxdepth 1 -name "$2" -type f 2>/dev/null | wc -l | tr -d ' '
}
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
check_not() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "$name"; else pass "$name"; fi
}

stamp_ago() { # hours ago as a backup stamp
  local h="$1" e
  e=$(( $(date -u +%s) - h * 3600 ))
  date -u -d "@$e" +%Y%m%dT%H%M%SZ 2>/dev/null || date -u -r "$e" +%Y%m%dT%H%M%SZ
}

# --- fake root --------------------------------------------------------------------

FAKE="$T/fake"
SENTINEL="SENTINEL-TOKEN-9f3a"
mkdir -p "$FAKE"/etc/{x-ui,casavpn,ssh/sshd_config.d,fail2ban/jail.d,nginx/{sites-available,sites-enabled,conf.d},letsencrypt/{live/vpn.example.test,archive/vpn.example.test},systemd/system,apt/apt.conf.d} \
         "$FAKE"/usr/local/x-ui/bin "$FAKE"/usr/local/bin "$FAKE"/usr/local/lib/casavpn "$FAKE"/var/backups

echo "table inet filter {}"            >"$FAKE/etc/nftables.conf"
echo "PasswordAuthentication no"       >"$FAKE/etc/ssh/sshd_config.d/00-hardening.conf"
echo "[sshd]"                          >"$FAKE/etc/fail2ban/jail.local"
echo "server { listen 8443; }"         >"$FAKE/etc/nginx/sites-available/vpn.example.test"
ln -s ../sites-available/vpn.example.test   "$FAKE/etc/nginx/sites-enabled/vpn.example.test"
echo "map \$http_upgrade \$cu {}"      >"$FAKE/etc/nginx/conf.d/upgrade.conf"
echo "CF_API_TOKEN=$SENTINEL"          >"$FAKE/etc/casavpn/casavpn.env"
echo "[Service]"                       >"$FAKE/etc/systemd/system/casavpn-ddns.service"
echo "#!/bin/sh"                     >"$FAKE/usr/local/bin/casavpn-ddns"
echo "# lib"                        >"$FAKE/usr/local/lib/casavpn/set_min_client_ver.py"
echo "PEM-DATA-$SENTINEL"              >"$FAKE/etc/letsencrypt/archive/vpn.example.test/privkey1.pem"
ln -s ../../archive/vpn.example.test/privkey1.pem "$FAKE/etc/letsencrypt/live/vpn.example.test/privkey.pem"
echo "[Service]"                       >"$FAKE/etc/systemd/system/x-ui.service"
echo "PRETTY_NAME=\"Debian GNU/Linux 13 (fake)\"" >"$FAKE/etc/os-release"
printf '#!/bin/sh\necho "3x-ui v9.9.9-test"\n'  >"$FAKE/usr/local/x-ui/x-ui"
printf '#!/bin/sh\necho "Xray 26.7.28 (test)"\n' >"$FAKE/usr/local/x-ui/bin/xray-linux-arm64"
chmod +x "$FAKE/usr/local/x-ui/x-ui" "$FAKE/usr/local/x-ui/bin/xray-linux-arm64"

DB="$FAKE/etc/x-ui/x-ui.db"
UUID_A="$(python3 -c 'import uuid; print(uuid.uuid4())')"   # generated, never committed
sqlite3 "$DB" >/dev/null <<SQL
PRAGMA journal_mode=WAL;
CREATE TABLE inbounds (id INTEGER PRIMARY KEY, remark TEXT, settings TEXT, stream_settings TEXT);
INSERT INTO inbounds VALUES (1,'main','{"clients":[{"id":"$UUID_A"},{"id":"u2"}]}','{"realitySettings":{"privateKey":"PRIVATE-$SENTINEL"}}');
INSERT INTO inbounds VALUES (2,'sub','{"clients":[{"id":"u3"}]}','{}');
SQL

# Keep a writer connection open and add a row that only lives in the WAL, to
# prove the snapshot reads through the WAL (a plain cp would lose it).
mkfifo "$T/fifo"
sqlite3 "$DB" <"$T/fifo" >/dev/null 2>&1 &
BG_PID=$!
exec 3>"$T/fifo"
echo ".timeout 5000" >&3
echo "UPDATE inbounds SET settings='{\"clients\":[{\"id\":\"$UUID_A\"},{\"id\":\"u2\"},{\"id\":\"wal-only\"}]}' WHERE id=1;" >&3
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s "$DB-wal" ]] && break; sleep 0.3; done
check "fixture: the new row is only in the WAL" test -s "$DB-wal"

# --- key pair -----------------------------------------------------------------------

age-keygen -o "$T/id.txt" >/dev/null 2>&1
chmod 600 "$T/id.txt"
RECIP="$(age-keygen -y "$T/id.txt")"
age-keygen -o "$T/other-id.txt" >/dev/null 2>&1

OUT="$T/out"
bk() { # bk STAMP [args...] -> runs the backup with the fake root
  local stamp="$1"; shift
  CASAVPN_BACKUP_ROOT="$FAKE" CASAVPN_BACKUP_DEST="$OUT" CASAVPN_BACKUP_STAMP="$stamp" \
  CASAVPN_BACKUP_TMP="$T" "$REPO/scripts/casavpn-backup" "$@"
}

# --- 1. refuses to run unencrypted ------------------------------------------------------

env -u AGE_RECIPIENT bash -c "$(declare -f bk); T='$T'; FAKE='$FAKE'; OUT='$OUT'; REPO='$REPO'; bk 20260101T000000Z" >"$T/refuse.log" 2>&1
rc=$?
expect "refuses without AGE_RECIPIENT" 1 "$rc"
check "  ...and said why" grep -q "Refusing to write an unencrypted archive" "$T/refuse.log"
check "  ...and wrote nothing" bash -c "[[ -z \"\$(ls -A '$OUT' 2>/dev/null)\" ]]"

# --- 2. a failing run leaves no partial archive ------------------------------------------

AGE_RECIPIENT="age1$(printf '%s' notarealkey{1..5} | tr -d " ")xx" bk 20260101T000001Z >/dev/null 2>&1
rc=$?
expect "bad recipient fails" 1 "$rc"
check "  ...and leaves no archive or .partial file" bash -c "[[ -z \"\$(ls -A '$OUT' 2>/dev/null)\" ]]"

# --- 3. encrypted backups, retention ------------------------------------------------------

export AGE_RECIPIENT="$RECIP"
last=""
for i in 1 2 3 4 5; do
  last="$(CASAVPN_BACKUP_KEEP=3 bk "2026010${i}T033000Z" 2>"$T/bk.log")" || { fail "backup run $i"; cat "$T/bk.log"; }
done
check "backup produced an .age archive" test -s "$last"
check "  ...named with zstd/gzip + .age" bash -c "[[ '$last' == *.tar.zst.age || '$last' == *.tar.gz.age ]]"
check "  ...age header present" bash -c "[[ \"\$(head -c 21 '$last')\" == age-encryption.org/v1 ]]"
n="$(count_files "$OUT" 'casavpn-*')"
expect "retention keeps the newest 3" 3 "$n"
check "  ...and it kept the newest one" test -e "$OUT/casavpn-20260105T033000Z.tar.zst.age" -o -e "$OUT/casavpn-20260105T033000Z.tar.gz.age"
check "no .partial or plaintext left in the destination" bash -c "[[ -z \"\$(find '$OUT' -name '.*partial' -o -name 'x-ui.db' -o -name '*.tar' | head -1)\" ]]"
check "no staging directory left behind" bash -c "[[ -z \"\$(ls -d '$T'/casavpn-backup.* 2>/dev/null)\" ]]"
check_not "archive bytes do not contain the sentinel secret" grep -q "$SENTINEL" "$last"
check_not "archive bytes do not contain the Reality key marker" grep -q "privateKey" "$last"
expect "archive mode is 0600" 600 "$(mode_of "$last")"

# A source file that cannot be copied must fail the run and prune nothing, even
# when retention (KEEP=1) would otherwise delete the older archives.
if [[ "$(id -u)" -ne 0 ]]; then
  before="$(find "$OUT" -type f | sort | tr '\n' ' ')"
  UNREADABLE="$FAKE/etc/nginx/conf.d/unreadable.conf"
  echo "x" >"$UNREADABLE"; chmod 000 "$UNREADABLE"
  CASAVPN_BACKUP_KEEP=1 bk 20260109T033000Z >"$T/unread.log" 2>&1
  rc=$?
  chmod 600 "$UNREADABLE"; rm -f "$UNREADABLE"
  expect "an uncopyable source file fails the backup" 1 "$rc"
  check "  ...and says which path" grep -q "cannot copy etc/nginx/conf.d" "$T/unread.log"
  check "  ...nothing was pruned and no new archive appeared" test "$(find "$OUT" -type f | sort | tr '\n' ' ')" = "$before"
else
  echo "  skip (running as root: a mode-000 file is still readable)"
fi

# --- 4. plaintext only with the flag ---------------------------------------------------------

env -u AGE_RECIPIENT bash -c "$(declare -f bk); T='$T'; FAKE='$FAKE'; OUT='$T/plain'; REPO='$REPO'; CASAVPN_BACKUP_DEST='$T/plain'; export CASAVPN_BACKUP_DEST; bk 20260201T000000Z --allow-plaintext" >"$T/plain.log" 2>&1
check "--allow-plaintext writes an unencrypted archive" bash -c "ls '$T'/plain/casavpn-20260201T000000Z.tar.* >/dev/null"

# --- 5. restore drill -------------------------------------------------------------------------

DRILL="$REPO/scripts/restore-drill.sh"
"$DRILL" --identity "$T/id.txt" --dir "$OUT" >"$T/drill.log" 2>&1
rc=$?
expect "restore drill passes on the newest archive" 0 "$rc"
[[ $rc -eq 0 ]] || cat "$T/drill.log"
check "  ...integrity_check ok" grep -q "integrity_check: ok" "$T/drill.log"
check "  ...2 inbounds" grep -qE "inbounds: +2$" "$T/drill.log"
check "  ...4 clients (includes the WAL-only row)" grep -qE "clients: +4$" "$T/drill.log"
check "  ...manifest carries the 3x-ui version" grep -q "v9.9.9-test" "$T/drill.log"
check "  ...manifest carries the xray version" grep -q "Xray 26.7.28" "$T/drill.log"
check_not "  ...no UUID, key or token in the output" grep -qE "$UUID_A|$SENTINEL|PRIVATE-|wal-only" "$T/drill.log"
check "  ...left no temp directory" bash -c "[[ -z \"\$(ls -d '$T'/casavpn-drill.* 2>/dev/null)\" ]]"

# the same, with the identity handed over as a process substitution (keychain use)
check "drill accepts an identity from <(...)" "$DRILL" --identity <(cat "$T/id.txt") --dir "$OUT"
check_not "drill rejects the wrong identity" "$DRILL" --identity "$T/other-id.txt" --dir "$OUT"

head -c 200 "$last" >"$T/trunc.tar.zst.age"
check_not "drill rejects a truncated archive" "$DRILL" --identity "$T/id.txt" --archive "$T/trunc.tar.zst.age"

# the manifest must actually describe what was captured
tarx="$T/xtract"; mkdir -p "$tarx"
if [[ "$last" == *.zst.age ]]; then age -d -i "$T/id.txt" "$last" | zstd -dc | tar -xf - -C "$tarx"
else age -d -i "$T/id.txt" "$last" | gzip -dc | tar -xf - -C "$tarx"; fi
for rel in etc/nftables.conf etc/ssh/sshd_config.d/00-hardening.conf etc/fail2ban/jail.local \
           etc/nginx/sites-available/vpn.example.test etc/nginx/conf.d/upgrade.conf etc/casavpn/casavpn.env \
           etc/systemd/system/casavpn-ddns.service usr/local/bin/casavpn-ddns usr/local/lib/casavpn/set_min_client_ver.py \
           etc/letsencrypt/archive/vpn.example.test/privkey1.pem etc/systemd/system/x-ui.service; do
  check "archive contains /$rel" test -e "$tarx/rootfs/$rel"
done
check "archive keeps the sites-enabled symlink (nginx activation)" test -L "$tarx/rootfs/etc/nginx/sites-enabled/vpn.example.test"
check "archive keeps the letsencrypt live/ symlink" test -L "$tarx/rootfs/etc/letsencrypt/live/vpn.example.test/privkey.pem"
check "archive has dpkg-selections.txt" test -f "$tarx/dpkg-selections.txt"
check "manifest lists what was captured" grep -q '^included=/etc/nftables.conf$' "$tarx/MANIFEST"
check "manifest lists what was absent" grep -q '^missing=/etc/apt/apt.conf.d/20auto-upgrades$' "$tarx/MANIFEST"

# --- 6. pull-backups.sh --------------------------------------------------------------------------

PULL="$REPO/scripts/pull-backups.sh"
pull() { CASAVPN_PULL_LOCAL_SRC="$1" CASAVPN_BACKUP_LOCAL="$2" "$PULL"; }
mk() { : >/dev/null; printf 'x' >"$1/casavpn-$2.tar.zst.age"; }

R="$T/remote-fresh"; mkdir -p "$R"; mk "$R" "$(stamp_ago 30)"; mk "$R" "$(stamp_ago 6)"
printf 'x' >"$R/casavpn-plaintext.tar.zst"          # must never be pulled
L1="$T/local1"
pull "$R" "$L1" >"$T/pull1.log" 2>&1; rc=$?
expect "pull: fresh remote" 0 "$rc"
[[ $rc -eq 0 ]] || cat "$T/pull1.log"
expect "  ...copied both archives" 2 "$(count_files "$L1" '*.age')"
check "  ...never copies a non-.age file" bash -c "[[ ! -e '$L1/casavpn-plaintext.tar.zst' ]]"
check "  ...wrote the heartbeat" test -s "$L1/.last-pull"
pulled_modes=""
for f in "$L1"/*.age; do pulled_modes="$pulled_modes $(mode_of "$f")"; done
expect "  ...pulled copies are mode 0600 (x2)" 0 "$([[ "$pulled_modes" == " 600 600" ]] && echo 0 || echo 1)"

# a damaged local copy (same size AND different size) must be replaced by a pull
good="$(find "$R" -name 'casavpn-*.age' | sort | tail -n 1)"
bad="$L1/$(basename "$good")"
printf 'y' >"$bad"                      # same size as the 1-byte fixture, other content
pull "$R" "$L1" >/dev/null 2>&1
check "pull: replaces a same-size damaged local copy" cmp -s "$good" "$bad"
printf 'damaged-longer' >"$bad"
pull "$R" "$L1" >/dev/null 2>&1
check "pull: replaces a different-size damaged local copy" cmp -s "$good" "$bad"
expect "  ...and keeps it mode 0600" 600 "$(mode_of "$bad")"

R2="$T/remote-stale"; mkdir -p "$R2"; mk "$R2" "$(stamp_ago 60)"
pull "$R2" "$T/local2" >"$T/pull2.log" 2>&1; rc=$?
expect "pull: newest remote older than 48h" 2 "$rc"
check "  ...says ALERT" grep -q ALERT "$T/pull2.log"
check "  ...no heartbeat for a stale remote" bash -c "[[ ! -e '$T/local2/.last-pull' ]]"

R3="$T/remote-empty"; mkdir -p "$R3"
pull "$R3" "$T/local3" >"$T/pull3.log" 2>&1; rc=$?
expect "pull: Pi has no backups" 2 "$rc"

# a fresh but zero-byte archive on the host is not a successful pull
R8="$T/remote-zero"; mkdir -p "$R8"; mk "$R8" "$(stamp_ago 30)"; : >"$R8/casavpn-$(stamp_ago 2).tar.zst.age"
pull "$R8" "$T/local8" >"$T/pull8.log" 2>&1; rc=$?
expect "pull: a zero-byte newest remote archive fails" 2 "$rc"
check "  ...says ALERT" grep -q ALERT "$T/pull8.log"
check "  ...writes no heartbeat" bash -c "[[ ! -e '$T/local8/.last-pull' ]]"
check "  ...keeps no empty local file" bash -c "[[ -z \"\$(find '$T/local8' -name '*.age' -size 0)\" ]]"
R9="$T/remote-zero-only"; mkdir -p "$R9"; : >"$R9/casavpn-$(stamp_ago 2).tar.zst.age"
pull "$R9" "$T/local9" >"$T/pull9.log" 2>&1; rc=$?
expect "pull: only a zero-byte remote archive fails too" 2 "$rc"

pull "$T/nowhere" "$L1" >"$T/pull4.log" 2>&1; rc=$?
expect "pull: Pi unreachable, recent local copy" 0 "$rc"
check "  ...with a warning" grep -q WARNING "$T/pull4.log"

L5="$T/local5"; mkdir -p "$L5"; mk "$L5" "$(stamp_ago $((24 * 8)))"
pull "$T/nowhere" "$L5" >"$T/pull5.log" 2>&1; rc=$?
expect "pull: unreachable, local copy older than 7d" 3 "$rc"

pull "$T/nowhere" "$T/local6" >"$T/pull6.log" 2>&1; rc=$?
expect "pull: unreachable, nothing local" 3 "$rc"

R7="$T/remote-many"; mkdir -p "$R7"
for h in 100 90 80 70 60 50 40 30 20 10 5; do mk "$R7" "$(stamp_ago $h)"; done
CASAVPN_KEEP_LOCAL=4 pull "$R7" "$T/local7" >/dev/null 2>&1
n="$(count_files "$T/local7" '*.age')"
expect "pull: local retention keeps CASAVPN_KEEP_LOCAL=4" 4 "$n"

echo
echo "$PASS passed, $FAILN failed"
[[ $FAILN -eq 0 ]]
