#!/usr/bin/env bash
#
# casavpn-upgrade: move 3x-ui (and the Xray core it bundles) to the release
# pinned in xui-release.env, with a way back.
#
#   sudo casavpn-upgrade [--dry-run] [--yes]
#   sudo casavpn-upgrade --offline-xui <tarball>      tarball you downloaded yourself
#   sudo casavpn-upgrade --trust-release-sha          accept the hash published with the release
#
# What it does, in order:
#   1. takes an encrypted backup (casavpn-backup) if AGE_RECIPIENT is set
#   2. downloads the tarball and verifies its SHA-256 against the pin
#   3. stops x-ui; snapshots the database with sqlite3 .backup; moves the
#      installed tree aside (/usr/local/x-ui.bak-<old version>)
#   4. installs the new tree, starts x-ui, waits for the panel, and re-asserts
#      minClientVer and the loopback-only bindings (an upgrade can rewrite them)
#   5. runs the local healthcheck
#   6. if x-ui does not come up, rolls back by itself (casavpn-rollback)
#
# A newer Xray core can change what old clients can still do. After every
# upgrade, connect once with the OLDEST client you support before you close the
# terminal (docs/UPGRADING.md). To go back: sudo casavpn-rollback.
#
# Options:
#   --dry-run            show the plan, change nothing
#   --yes                do not ask for confirmation
#   --force              reinstall even if the version already matches
#   --no-backup          skip step 1 (the database snapshot in step 3 still happens)
#   --env <file>         settings file (default /etc/casavpn/casavpn.env)
#
# Test hooks: CASAVPN_XUI_DIR, CASAVPN_DB, CASAVPN_STATE_DIR, CASAVPN_SYSTEMD_DIR,
# CASAVPN_XUI_PIN (pin file), CASAVPN_PANEL_WAIT (seconds, default 30).

set -euo pipefail
umask 077

LIB=""
for c in "$(dirname "${BASH_SOURCE[0]}")/lib" /usr/local/lib/casavpn; do
  if [ -r "$c/common.sh" ]; then LIB="$c"; break; fi
done
[ -n "$LIB" ] || { echo "casavpn-upgrade: cannot find common.sh" >&2; exit 1; }
# shellcheck source=scripts/lib/common.sh
. "$LIB/common.sh"

usage() { awk 'NR < 3 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}" >&2; exit 2; }

ASSUME_YES=0; FORCE=0; NO_BACKUP=0; TRUST_SHA=0; OFFLINE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --force) FORCE=1; shift ;;
    --no-backup) NO_BACKUP=1; shift ;;
    --trust-release-sha) TRUST_SHA=1; shift ;;
    --offline-xui) [ $# -ge 2 ] || usage; OFFLINE="$2"; shift 2 ;;
    --env) [ $# -ge 2 ] || usage; ENV_FILE="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown option: $1" >&2; usage ;;
  esac
done

XUI_DIR="${CASAVPN_XUI_DIR:-/usr/local/x-ui}"
XUI_DB="${CASAVPN_DB:-/etc/x-ui/x-ui.db}"
STATE_DIR="${CASAVPN_STATE_DIR:-/var/lib/casavpn/upgrades}"
SYSTEMD_DIR="${CASAVPN_SYSTEMD_DIR:-/etc/systemd/system}"
PIN="$(release_pin_file "$LIB" 2>/dev/null || true)"
[ -n "$PIN" ] || PIN="$LIB/xui-release.env"
[ -r "$PIN" ] || die "cannot find xui-release.env"

[ "$DRY_RUN" = 1 ] || [ "$(id -u)" -eq 0 ] || die "run as root: sudo casavpn-upgrade"
[ -x "$XUI_DIR/x-ui" ] || die "3x-ui is not installed in $XUI_DIR (run install.sh first)"
load_env "$ENV_FILE" || warn "cannot read $ENV_FILE; using defaults"
apply_defaults

TMP="$(mktemp -d "${TMPDIR:-/tmp}/casavpn-upgrade.XXXXXXXX")"
trap 'rm -rf "${TMP:?}"' EXIT

xui_version() { # <dir>: the version the binary reports, or "unknown"
  local v
  for flag in -v --version version; do
    v="$("$1/x-ui" "$flag" 2>/dev/null | head -n1 | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
    if [ -n "$v" ]; then echo "$v"; return; fi
  done
  echo unknown
}

wait_panel() { # wait up to 30 s for the loopback panel port
  local _n
  for _n in $(seq 1 "${CASAVPN_PANEL_WAIT:-30}"); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$CASAVPN_PANEL_PORT") 2>/dev/null; then return 0; fi
    sleep 1
  done
  return 1
}

want="$(read_pin "$PIN" XUI_VERSION)"
have="$(xui_version "$XUI_DIR")"
step "3x-ui upgrade: $have -> ${want#v}"
log "  pin file: $PIN"
if [ "$have" = "${want#v}" ] && [ "$FORCE" = 0 ]; then
  ok "already at ${want#v}: nothing to do (--force reinstalls)"
  exit 0
fi

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
bakdir="$(unique_path "${XUI_DIR}.bak-${have}-${stamp}")"
rec="$(unique_path "$STATE_DIR/$stamp")"

if [ "$DRY_RUN" = 1 ]; then
  log "  would back up with casavpn-backup (AGE_RECIPIENT ${AGE_RECIPIENT:+set}${AGE_RECIPIENT:-empty})"
  log "  would download $want, verify its SHA-256 against the pin"
  log "  would stop x-ui, snapshot $XUI_DB to $rec/x-ui.db, move $XUI_DIR to $bakdir"
  log "  would install the new tree, start x-ui, wait for 127.0.0.1:$CASAVPN_PANEL_PORT"
  log "  would re-assert minClientVer=$CASAVPN_MIN_CLIENT_VER and the loopback bindings, run the healthcheck"
  exit 0
fi

if [ "$ASSUME_YES" = 0 ] && [ -t 0 ]; then
  printf '  Upgrade 3x-ui %s -> %s now? The VPN is down for about a minute. [y/N] ' "$have" "${want#v}" >&2
  read -r reply || reply=n
  case "$reply" in y|Y|yes) ;; *) die "cancelled" ;; esac
fi

# 1. backup
if [ "$NO_BACKUP" = 0 ] && [ -n "$AGE_RECIPIENT" ] && command -v casavpn-backup >/dev/null 2>&1; then
  log "  taking an encrypted backup first ..."
  casavpn-backup >/dev/null || die "the backup failed; nothing was changed (--no-backup skips it)"
  ok "backup written"
else
  warn "no off-host backup taken (AGE_RECIPIENT empty or --no-backup); the database snapshot below still happens"
fi

# 2. download + verify (nothing is touched until this passes)
mkdir -p "$TMP/dl"
fetch_xui "$PIN" "$TMP/dl" "$TRUST_SHA" "$OFFLINE"
tar -xzf "$TMP"/dl/x-ui-linux-*.tar.gz -C "$TMP/dl"
[ -x "$TMP/dl/x-ui/x-ui" ] || die "the tarball has no x-ui/x-ui binary; nothing was changed"
chmod +x "$TMP/dl/x-ui/x-ui" "$TMP"/dl/x-ui/bin/xray-linux-* 2>/dev/null || true

# 3. snapshot + move aside
mkdir -p "$rec"
systemctl stop x-ui
if [ -e "$XUI_DB" ]; then
  sqlite3 "$XUI_DB" ".backup '$rec/x-ui.db'" || { systemctl start x-ui || true; die "could not snapshot the database; nothing was changed"; }
fi
[ ! -e "$SYSTEMD_DIR/x-ui.service" ] || cp -p "$SYSTEMD_DIR/x-ui.service" "$rec/x-ui.service"
printf 'from=%s\nto=%s\ntree=%s\n' "$have" "${want#v}" "$bakdir" >"$rec/RECORD"
mv "$XUI_DIR" "$bakdir"
ln -sfn "$rec" "$STATE_DIR/latest"
ok "old tree kept at $bakdir; database snapshot at $rec/x-ui.db"

# 4. install the new tree
mv "$TMP/dl/x-ui" "$XUI_DIR"
for unit in "$XUI_DIR/x-ui.service.debian" "$XUI_DIR/x-ui.service"; do
  if [ -f "$unit" ]; then install -m 0644 "$unit" "$SYSTEMD_DIR/x-ui.service"; ok "refreshed the systemd unit from the release ($(basename "$unit"))"; break; fi
done
[ ! -f "$XUI_DIR/x-ui.sh" ] || install -m 0755 "$XUI_DIR/x-ui.sh" /usr/bin/x-ui 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true
systemctl start x-ui || true
if ! wait_panel; then
  warn "the panel did not come up on 127.0.0.1:$CASAVPN_PANEL_PORT in time: rolling back"
  exec "$(command -v casavpn-rollback || echo "$(dirname "${BASH_SOURCE[0]}")/rollback.sh")" --yes
fi
ok "x-ui $(xui_version "$XUI_DIR") is up"

# re-assert what an upgrade may have reset
systemctl stop x-ui
python3 "$LIB/set_min_client_ver.py" --db "$XUI_DB" --version "$CASAVPN_MIN_CLIENT_VER" --port "$CASAVPN_VPN_PORT" || warn "minClientVer could not be set (is there a Reality inbound on port $CASAVPN_VPN_PORT?)"
set_setting() { # <key> <value>
  sqlite3 "$XUI_DB" "UPDATE settings SET value='$2' WHERE key='$1'; INSERT INTO settings (key, value) SELECT '$1', '$2' WHERE NOT EXISTS (SELECT 1 FROM settings WHERE key='$1');"
}
set_setting webListen 127.0.0.1
set_setting subListen 127.0.0.1
systemctl start x-ui
wait_panel || warn "the panel is slow to come back; check 'systemctl status x-ui'"

step "Health check"
casavpn-healthcheck --local --env "$ENV_FILE" || warn "the healthcheck reported problems: read them before you close this terminal"

cat >&2 <<MSG

${C_B}Now test with your OLDEST client${C_Z} (before you close this terminal):
  Connect once with the oldest device or app you support, and open a web page through it.
  If it fails: sudo casavpn-rollback    (restores the old tree and the database snapshot)
  The old tree stays at $bakdir; delete it once you are sure.
MSG
