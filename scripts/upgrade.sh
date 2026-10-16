#!/usr/bin/env bash
#
# casavpn-upgrade: move 3x-ui to the release pinned in xui-release.env and the
# Xray core to the one pinned in xray-core.env, with a way back.
#
#   sudo casavpn-upgrade [--dry-run] [--yes]
#   sudo casavpn-upgrade --offline-xui <tarball>      tarball you downloaded yourself
#   sudo casavpn-upgrade --offline-xray <zip>         Xray core zip you downloaded yourself
#   sudo casavpn-upgrade --trust-release-sha          accept the hash published with the release
#
# What it does, in order:
#   1. takes an encrypted backup (casavpn-backup) if AGE_RECIPIENT is set
#   2. downloads the tarball and the pinned Xray core zip and verifies both
#      SHA-256 values against the pins (nothing is touched until both pass)
#   3. stops x-ui; snapshots the database with sqlite3 .backup; moves the
#      installed tree aside (/usr/local/x-ui.bak-<old version>)
#   4. installs the new tree, then puts the pinned Xray core over the bundled one
#      (atomically; the bundled core stays as xray-linux-<arch>.bundled), starts
#      x-ui, waits for the panel, and re-asserts minClientVer and the
#      loopback-only bindings (an upgrade can rewrite them)
#   5. runs the local healthcheck
#   6. if x-ui does not come up, rolls back by itself (casavpn-rollback)
#
# A new panel release brings its own Xray core, and 26.10.10 (bundled with 3x-ui
# 3.10.2) rejects Shadowrocket at Reality: that is why the core is pinned
# (config/xray-core.env). CASAVPN_XRAY_CORE=bundled in casavpn.env opts out.
# When the panel is already at the pinned version, this still re-applies the core
# pin if the running core differs (no tree swap, x-ui restarts once).
#
# After every upgrade or core change, connect once with the OLDEST client you
# support AND with a non-Xray client (Shadowrocket) on mobile data before you
# close the terminal (docs/UPGRADING.md). To go back: sudo casavpn-rollback.
#
# Options:
#   --dry-run            show the plan, change nothing
#   --yes                do not ask for confirmation
#   --force              reinstall even if the version already matches
#   --no-backup          skip step 1 (the database snapshot in step 3 still happens)
#   --env <file>         settings file (default /etc/casavpn/casavpn.env)
#
# Test hooks: CASAVPN_XUI_DIR, CASAVPN_DB, CASAVPN_STATE_DIR, CASAVPN_SYSTEMD_DIR,
# CASAVPN_XUI_PIN and CASAVPN_XRAY_PIN (pin files), CASAVPN_PANEL_WAIT (seconds, default 30).

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

ASSUME_YES=0; FORCE=0; NO_BACKUP=0; TRUST_SHA=0; OFFLINE=""; OFFLINE_XRAY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --force) FORCE=1; shift ;;
    --no-backup) NO_BACKUP=1; shift ;;
    --trust-release-sha) TRUST_SHA=1; shift ;;
    --offline-xui) [ $# -ge 2 ] || usage; OFFLINE="$2"; shift 2 ;;
    --offline-xray) [ $# -ge 2 ] || usage; OFFLINE_XRAY="$2"; shift 2 ;;
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
case "$CASAVPN_XRAY_CORE" in pinned|bundled) ;; *) die "CASAVPN_XRAY_CORE '$CASAVPN_XRAY_CORE' is unknown (pinned | bundled)" ;; esac
CORE_PIN=""
if [ "$CASAVPN_XRAY_CORE" = pinned ]; then
  CORE_PIN="$(core_pin_file "$LIB" 2>/dev/null || true)"
  [ -n "$CORE_PIN" ] || CORE_PIN="$LIB/xray-core.env"
  [ -r "$CORE_PIN" ] || die "cannot find xray-core.env (re-run install.sh --skip-packages --skip-3xui ... to refresh it, or set CASAVPN_XRAY_CORE=bundled)"
fi

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

restart_xui() { # restart x-ui and wait for the panel; non-zero if it does not come back
  systemctl restart x-ui || return 1
  wait_panel || return 1
}

core_bin() { printf '%s/bin/xray-linux-%s' "$XUI_DIR" "$(xui_arch)"; }

# undo_core <binary> <saved previous binary>: x-ui did not come back on the new
# core; put the previous one back, restart, and fail loudly.
undo_core() {
  if install -m 0755 "$2" "$1.new" && mv -f "$1.new" "$1"; then
    if restart_xui; then die "x-ui did not come back on the new Xray core: the previous core is restored and x-ui is up again. Nothing else was changed; read 'journalctl -u x-ui -n 50'."; fi
    die "x-ui did not come back on the new Xray core, and not on the restored previous core either: read 'journalctl -u x-ui -n 50' (sudo casavpn-rollback may help after a panel upgrade)."
  fi
  rm -f "$1.new"
  die "x-ui did not come back on the new Xray core and the previous core could not be restored: copy $1.bundled over $1 by hand and restart x-ui."
}

# core_only: the panel is already at the pinned version; bring the core to the
# pin (or back to the bundled one) without swapping the tree.
core_only() {
  local bin cur want_core
  bin="$(core_bin)"
  cur="$(xray_version "$bin")"
  if [ "$CASAVPN_XRAY_CORE" = bundled ]; then
    if [ -e "$bin.bundled" ] && ! cmp -s "$bin" "$bin.bundled"; then
      step "Xray core: back to the bundled one (CASAVPN_XRAY_CORE=bundled)"
      [ "$DRY_RUN" = 0 ] || { log "  would restore $bin.bundled over $bin and restart x-ui"; return 0; }
      cp -p "$bin" "$TMP/prev-core"
      restore_bundled_core "$XUI_DIR" || die "could not restore $bin.bundled"
      restart_xui || undo_core "$bin" "$TMP/prev-core"
      ok "Xray core is now $(xray_version "$bin")"
      core_test_reminder
    else
      ok "Xray core: using the bundled one ($cur), as CASAVPN_XRAY_CORE=bundled asks"
    fi
    return 0
  fi
  want_core="$(read_pin "$CORE_PIN" XRAY_CORE_VERSION)"
  if [ "$cur" = "${want_core#v}" ] && [ "$FORCE" = 0 ]; then
    ok "Xray core is already at the pinned ${want_core#v}"
    return 0
  fi
  step "Xray core: ${cur:-unknown} -> ${want_core#v} (pin: $CORE_PIN)"
  if [ "$DRY_RUN" = 1 ]; then
    log "  would download $want_core, verify its SHA-256, install it over $bin (a .new file, then mv -f), keep the bundled core as $bin.bundled, restart x-ui"
    return 0
  fi
  if [ "$ASSUME_YES" = 0 ] && [ -t 0 ]; then
    printf '  Replace the Xray core now? The VPN drops for a few seconds. [y/N] ' >&2
    read -r reply || reply=n
    case "$reply" in y|Y|yes) ;; *) die "cancelled" ;; esac
  fi
  mkdir -p "$TMP/core"
  fetch_xray_core "$CORE_PIN" "$TMP/core" "$OFFLINE_XRAY"
  cp -p "$bin" "$TMP/prev-core"
  install_xray_core "$XUI_DIR" "$TMP/core/xray"
  restart_xui || undo_core "$bin" "$TMP/prev-core"
  ok "Xray core is now $(xray_version "$bin") (the bundled one is kept as $bin.bundled)"
  core_test_reminder
}

core_test_reminder() {
  cat >&2 <<MSG

${C_B}Test a non-Xray client now${C_Z}: connect with Shadowrocket on mobile data (not Wi-Fi), and
open a web page. An old Xray-based client passing proves nothing about it (docs/UPGRADING.md).
  Back to the bundled core: set CASAVPN_XRAY_CORE=bundled in $ENV_FILE and run casavpn-upgrade again,
  or: sudo casavpn-rollback (after a panel upgrade).
MSG
}

want="$(read_pin "$PIN" XUI_VERSION)"
have="$(xui_version "$XUI_DIR")"
step "3x-ui upgrade: $have -> ${want#v}"
log "  pin file: $PIN"
if [ "$have" = "${want#v}" ] && [ "$FORCE" = 0 ]; then
  ok "already at ${want#v}: nothing to do (--force reinstalls)"
  core_only
  exit 0
fi

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
bakdir="$(unique_path "${XUI_DIR}.bak-${have}-${stamp}")"
rec="$(unique_path "$STATE_DIR/$stamp")"

if [ "$DRY_RUN" = 1 ]; then
  log "  would back up with casavpn-backup (AGE_RECIPIENT ${AGE_RECIPIENT:+set}${AGE_RECIPIENT:-empty})"
  log "  would download $want, verify its SHA-256 against the pin"
  if [ "$CASAVPN_XRAY_CORE" = pinned ]; then
    log "  would download Xray core $(read_pin "$CORE_PIN" XRAY_CORE_VERSION), verify its SHA-256, and install it over the bundled core (kept as xray-linux-<arch>.bundled)"
  else
    log "  CASAVPN_XRAY_CORE=bundled: would keep the Xray core that the new 3x-ui ships"
  fi
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
if [ "$CASAVPN_XRAY_CORE" = pinned ]; then
  mkdir -p "$TMP/core"
  fetch_xray_core "$CORE_PIN" "$TMP/core" "$OFFLINE_XRAY"
fi

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
# The new tree carries its own core; put the pinned one over it before x-ui starts.
if [ "$CASAVPN_XRAY_CORE" = pinned ]; then
  install_xray_core "$XUI_DIR" "$TMP/core/xray"
  ok "Xray core $(xray_version "$TMP/core/xray") installed over the bundled one (kept as xray-linux-*.bundled)"
fi
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
log "  xray core: $(xray_version "$(core_bin)" || true)"

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

${C_B}Now test with your OLDEST client and with Shadowrocket${C_Z} (before you close this terminal):
  Connect once with the oldest device or app you support, and once with Shadowrocket on
  mobile data (not Wi-Fi), and open a web page through each. An Xray-based client passing
  does not prove the iOS clients work (docs/UPGRADING.md, "Changing the Xray core").
  If it fails: sudo casavpn-rollback    (restores the old tree and the database snapshot)
  The old tree stays at $bakdir; delete it once you are sure.
MSG
