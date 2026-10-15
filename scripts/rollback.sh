#!/usr/bin/env bash
#
# casavpn-rollback: undo the last casavpn-upgrade.
#
#   sudo casavpn-rollback [--yes] [--keep-db]
#
# Puts the previous 3x-ui tree back (/usr/local/x-ui.bak-<version>-<stamp>),
# restores the systemd unit, and by default the database snapshot taken just
# before the upgrade. A newer panel may have migrated the database in a way the
# older one cannot read, which is why the snapshot is restored; the cost is
# that any client you added after the upgrade is gone. --keep-db keeps the
# current database instead (use it only if you know the old version can read it).
#
# The tree that is being replaced is kept as /usr/local/x-ui.failed-<stamp>.
#
# Test hooks: CASAVPN_XUI_DIR, CASAVPN_DB, CASAVPN_STATE_DIR, CASAVPN_SYSTEMD_DIR,
# CASAVPN_PANEL_WAIT (seconds, default 30).

set -euo pipefail
umask 077

LIB=""
for c in "$(dirname "${BASH_SOURCE[0]}")/lib" /usr/local/lib/casavpn; do
  if [ -r "$c/common.sh" ]; then LIB="$c"; break; fi
done
[ -n "$LIB" ] || { echo "casavpn-rollback: cannot find common.sh" >&2; exit 1; }
# shellcheck source=scripts/lib/common.sh
. "$LIB/common.sh"

usage() { awk 'NR < 3 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}" >&2; exit 2; }

ASSUME_YES=0; KEEP_DB=0
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) ASSUME_YES=1; shift ;;
    --keep-db) KEEP_DB=1; shift ;;
    --env) [ $# -ge 2 ] || usage; ENV_FILE="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown option: $1" >&2; usage ;;
  esac
done

XUI_DIR="${CASAVPN_XUI_DIR:-/usr/local/x-ui}"
XUI_DB="${CASAVPN_DB:-/etc/x-ui/x-ui.db}"
STATE_DIR="${CASAVPN_STATE_DIR:-/var/lib/casavpn/upgrades}"
SYSTEMD_DIR="${CASAVPN_SYSTEMD_DIR:-/etc/systemd/system}"

[ "$(id -u)" -eq 0 ] || die "run as root: sudo casavpn-rollback"
load_env "$ENV_FILE" || true
apply_defaults

[ -e "$STATE_DIR/latest/RECORD" ] || die "no upgrade record in $STATE_DIR: nothing to roll back"
rec="$(cd "$STATE_DIR/latest" && pwd -P)"
tree="$(grep '^tree=' "$rec/RECORD" | cut -d= -f2-)"
from="$(grep '^from=' "$rec/RECORD" | cut -d= -f2-)"
to="$(grep '^to=' "$rec/RECORD" | cut -d= -f2-)"
[ -d "$tree" ] || die "the old tree $tree is gone: cannot roll back automatically"

step "Rolling back 3x-ui $to -> $from"
if [ "$ASSUME_YES" = 0 ] && [ -t 0 ]; then
  printf '  Restore %s%s? [y/N] ' "$tree" "$([ "$KEEP_DB" = 1 ] || echo ' and the database snapshot')" >&2
  read -r reply || reply=n
  case "$reply" in y|Y|yes) ;; *) die "cancelled" ;; esac
fi

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
systemctl stop x-ui 2>/dev/null || true
if [ -d "$XUI_DIR" ]; then
  failed="$(unique_path "${XUI_DIR}.failed-$stamp")"
  mv "$XUI_DIR" "$failed"
  ok "the current tree is kept as $failed"
fi
mv "$tree" "$XUI_DIR"
ok "restored the $from tree"
if [ -e "$rec/x-ui.service" ]; then install -m 0644 "$rec/x-ui.service" "$SYSTEMD_DIR/x-ui.service"; ok "restored the systemd unit"; fi
if [ "$KEEP_DB" = 0 ] && [ -e "$rec/x-ui.db" ]; then
  [ ! -e "$XUI_DB" ] || cp -p "$XUI_DB" "$(unique_path "$XUI_DB.pre-rollback-$stamp")"
  rm -f "$XUI_DB-wal" "$XUI_DB-shm"
  cp -p "$rec/x-ui.db" "$XUI_DB"
  chmod 0600 "$XUI_DB"
  ok "restored the database snapshot (the one in use until now is $XUI_DB.pre-rollback-$stamp)"
fi
systemctl daemon-reload 2>/dev/null || true
systemctl start x-ui
wait_s="${CASAVPN_PANEL_WAIT:-30}"
for i in $(seq 1 "$wait_s"); do
  if (exec 3<>"/dev/tcp/127.0.0.1/$CASAVPN_PANEL_PORT") 2>/dev/null; then ok "x-ui is up again"; break; fi
  sleep 1
  [ "$i" -lt "$wait_s" ] || warn "the panel does not answer on 127.0.0.1:$CASAVPN_PANEL_PORT: check 'journalctl -u x-ui -n 50'"
done
rm -f "$STATE_DIR/latest"
log ""
log "  Rolled back. Connect with a client to confirm the VPN works."
