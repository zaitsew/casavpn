#!/usr/bin/env bash
#
# install.sh: set up CasaVPN on a fresh Raspberry Pi OS / Debian / Ubuntu host.
#
#   sudo ./install.sh --dry-run     show everything it would do; changes nothing
#   sudo ./install.sh               do it
#
# Settings come from /etc/casavpn/casavpn.env (see casavpn.env.example). If the
# file does not exist, install.sh creates it from the example and stops (exit 3)
# so you can fill it in.
#
# What it does, in order (each step can be skipped with --skip-<step>):
#   packages    apt: nginx nftables fail2ban sqlite3 jq age zstd certbot ...
#   files       our scripts to /usr/local/bin, helpers to /usr/local/lib/casavpn
#   3xui        download the pinned 3x-ui release, verify its SHA-256, install,
#               set generated panel credentials and a secret base path, bind
#               the panel and subscription server to 127.0.0.1
#   certs       a Let's Encrypt certificate by DNS-01 through Cloudflare
#               (needs CF_API_TOKEN; port 80 is never opened)
#   nginx       the web front end: /sub/ public, the panel LAN/Tailscale only
#   ssh         key-only SSH, no root, AllowUsers (refused if it could lock you out)
#   firewall    nftables default-deny (refused if your SSH session is not from the LAN)
#   fail2ban    an sshd jail
#   timers      casavpn-ddns (every minute) and casavpn-backup (nightly)
#   updates     unattended security upgrades
#
# What it does NOT do: create the VPN inbound and its clients (the panel does
# that; the exact values are printed at the end), forward ports on your router,
# or touch anything outside this host. It never overwrites an existing
# /etc/casavpn/casavpn.env, /etc/x-ui/x-ui.db or panel credentials, and it
# keeps a copy of any foreign file it replaces (<file>.pre-casavpn).
#
# Options:
#   --dry-run             print the plan; no root needed, no env file needed
#   --env <file>          settings file (default /etc/casavpn/casavpn.env)
#   --skip-<step>         packages files 3xui certs nginx ssh firewall fail2ban timers updates
#   --tailscale           add the Tailscale rules to the firewall (default: if
#                         the tailscale command exists)
#   --offline-xui <file>  use a 3x-ui tarball you downloaded yourself (still
#                         checked against the pinned SHA-256)
#   --trust-release-sha   if the pinned hash does not match, accept the hash
#                         published next to the release instead
#   --force-firewall      load the firewall even though this SSH session is not
#                         from the LAN (you may lock yourself out)
#   --force-ssh           harden SSH even though it may lock out the user running
#                         this script
#   --yes                 do not ask for the firewall confirmation
#   --show <name>         print one generated config and exit (changes nothing):
#                         nftables | nginx | nginx-admin | sshd | fail2ban
#   -h, --help
#
# Exit codes: 0 done, 1 error, 2 usage, 3 settings file created: edit it and re-run.

set -euo pipefail
umask 022

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/scripts/lib"
[ -r "$LIB/common.sh" ] || { echo "install.sh: run it from a CasaVPN checkout (scripts/lib/common.sh is missing)" >&2; exit 1; }

DRY_RUN=0
ENV_FILE="${CASAVPN_ENV:-/etc/casavpn/casavpn.env}"
TAILSCALE=auto
OFFLINE_XUI=""
TRUST_SHA=0
FORCE_FW=0
FORCE_SSH=0
ASSUME_YES=0
SHOW=""
SKIP=" "
USE_TAILSCALE=0
PIN=""

# shellcheck source=scripts/lib/common.sh
. "$LIB/common.sh"

usage() { awk 'NR < 3 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --env) [ $# -ge 2 ] || usage; ENV_FILE="$2"; shift 2 ;;
    --skip-packages|--skip-files|--skip-3xui|--skip-certs|--skip-nginx|--skip-ssh|--skip-firewall|--skip-fail2ban|--skip-timers|--skip-updates)
      SKIP="$SKIP${1#--skip-} "; shift ;;
    --tailscale) TAILSCALE=1; shift ;;
    --offline-xui) [ $# -ge 2 ] || usage; OFFLINE_XUI="$2"; shift 2 ;;
    --trust-release-sha) TRUST_SHA=1; shift ;;
    --force-firewall) FORCE_FW=1; shift ;;
    --force-ssh) FORCE_SSH=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --show) [ $# -ge 2 ] || usage; SHOW="$2"; DRY_RUN=1; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown option: $1" >&2; usage ;;
  esac
done

skipped() { case "$SKIP" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/casavpn-install.XXXXXXXX")"
cleanup() { rm -rf "${TMP:?}"; }
trap cleanup EXIT

LEFT=()   # "what is left for you", printed at the end
leave() { LEFT+=("$*"); }

# --- paths (overridable for tests) ----------------------------------------------------
ETC="${CASAVPN_ETC:-/etc}"
BIN_DIR="${CASAVPN_BIN_DIR:-/usr/local/bin}"
LIB_DIR="${CASAVPN_LIB_DIR:-/usr/local/lib/casavpn}"
DOC_DIR="${CASAVPN_DOC_DIR:-/usr/local/share/doc/casavpn}"
XUI_DIR="${CASAVPN_XUI_DIR:-/usr/local/x-ui}"
XUI_DB="${CASAVPN_DB:-/etc/x-ui/x-ui.db}"
CRED_FILE="${CASAVPN_PANEL_CREDS:-$ETC/casavpn/panel-credentials.env}"
CF_INI="$ETC/casavpn/cloudflare.ini"
LE_DIR="${CASAVPN_LE_DIR:-/etc/letsencrypt}"
SYSTEMD_DIR="${CASAVPN_SYSTEMD_DIR:-/etc/systemd/system}"

# ======================================================================= helpers ==

# install_file <mode> <src> <dst>: skip if identical, keep a copy of a foreign file.
install_file() {
  local mode="$1" src="$2" dst="$3"
  if [ -e "$dst" ] && cmp -s "$src" "$dst"; then ok "unchanged: $dst"; return 0; fi
  if [ "$DRY_RUN" = 1 ]; then
    log "  would install $dst (mode $mode, from $(basename "$src" .rendered))"
    return 0
  fi
  backup_foreign "$dst"
  install -D -m "$mode" -o root "$src" "$dst"
  ok "installed $dst"
}

# nginx_http2_on_supported: 0 when "http2 on;" is understood (nginx 1.25.1+), or when
# nginx is not installed yet (the package install brings a current one); 1 for older
# nginx (Debian 12 ships 1.22), which wants "http2" on the listen line instead.
nginx_http2_on_supported() {
  local v a b c
  v="$(nginx -v 2>&1 | sed -n 's|.*nginx/\([0-9][0-9.]*\).*|\1|p' | head -n1)" || true
  [ -n "$v" ] || return 0
  IFS=. read -r a b c <<<"$v"
  a="${a:-0}"; b="${b:-0}"; c="${c:-0}"
  if [ "$a" -gt 1 ]; then return 0; fi
  if [ "$a" -lt 1 ]; then return 1; fi
  if [ "$b" -gt 25 ]; then return 0; fi
  if [ "$b" -lt 25 ]; then return 1; fi
  [ "$c" -ge 1 ]
}

# detect_lan_gateway: the default route's next hop, if it is an IPv4 address inside the LAN.
detect_lan_gateway() {
  local gw
  command -v ip >/dev/null 2>&1 || return 1
  gw="$(ip -4 route show default 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "via") { print $(i + 1); exit } }')" || true
  valid_ip4 "$gw" || return 1
  in_cidr "$gw" "$CASAVPN_LAN_CIDR" || return 1
  printf '%s' "$gw"
}

# resolve_lan_gateway: settle CASAVPN_LAN_GATEWAY (explicit, detected, or none).
resolve_lan_gateway() {
  case "$CASAVPN_LAN_GATEWAY" in
    none) CASAVPN_LAN_GATEWAY=""
          warn "CASAVPN_LAN_GATEWAY=none: the panel ACL has no hairpin-NAT guard (docs/HARDENING.md, 'Hairpin NAT')"
          return 0 ;;
    '') ;;
    *) ok "LAN gateway $CASAVPN_LAN_GATEWAY (from CASAVPN_LAN_GATEWAY) is denied before the LAN is allowed"; return 0 ;;
  esac
  if CASAVPN_LAN_GATEWAY="$(detect_lan_gateway)"; then
    ok "LAN gateway $CASAVPN_LAN_GATEWAY (default route) is denied before the LAN is allowed"
  else
    CASAVPN_LAN_GATEWAY=""
    warn "could not detect the router's LAN address, so the panel ACL has no hairpin-NAT guard"
    leave "Set CASAVPN_LAN_GATEWAY to your router's LAN address in $ENV_FILE and re-run install.sh, so a VPN user cannot reach the panel by hairpinning through the router (docs/HARDENING.md)."
  fi
}

# panel_base_path: the base path from the credentials file, else from an existing
# panel database, else a placeholder.
panel_base_path() {
  local b
  b="$(panel_cred PANEL_BASE_PATH 2>/dev/null || true)"
  [ -n "$b" ] || b="$(xui_db_base_path 2>/dev/null || true)"
  [ -n "$b" ] || b="panel-path-set-at-install"
  printf '%s' "$b"
}

# xui_db_base_path / xui_db_user: read-only lookups in an existing panel database.
xui_db_base_path() {
  local v
  [ -r "$XUI_DB" ] && command -v sqlite3 >/dev/null 2>&1 || return 1
  v="$(sqlite3 "$XUI_DB" "select value from settings where key='webBasePath' limit 1;" 2>/dev/null)" || return 1
  v="${v#/}"; v="${v%/}"
  [[ "$v" =~ ^[A-Za-z0-9._~-]+$ ]] || return 1
  printf '%s' "$v"
}
xui_db_user() {
  local v
  [ -r "$XUI_DB" ] && command -v sqlite3 >/dev/null 2>&1 || return 1
  v="$(sqlite3 "$XUI_DB" "select username from users order by id limit 1;" 2>/dev/null)" || return 1
  [[ "$v" =~ ^[A-Za-z0-9._@-]+$ ]] || return 1
  printf '%s' "$v"
}

# render <template>: the template with its @TOKENS@ filled in, on stdout.
render() {
  local f="$1" base_path out gw_rule http2_listen http2_on ignore_extra
  base_path="$(panel_base_path)"
  if [ -n "$CASAVPN_LAN_GATEWAY" ]; then gw_rule="deny $CASAVPN_LAN_GATEWAY;"
  else gw_rule="# no LAN gateway address known: set CASAVPN_LAN_GATEWAY (hairpin-NAT guard is OFF)"; fi
  if nginx_http2_on_supported; then http2_listen=""; http2_on="http2 on;"
  else http2_listen=" http2"; http2_on="# nginx < 1.25.1: http2 is on the listen lines above"; fi
  ignore_extra="$(printf '%s' "$CASAVPN_FAIL2BAN_IGNOREIP" | tr ',' ' ' | tr -s ' ' | sed -e 's/^ //' -e 's/ $//')"
  [ -z "$ignore_extra" ] || ignore_extra=" $ignore_extra"
  out="$(sed \
    -e "s|@DOMAIN@|$CASAVPN_DOMAIN|g" \
    -e "s|@VPN_PORT@|$CASAVPN_VPN_PORT|g" \
    -e "s|@WEB_PORT@|$CASAVPN_WEB_PORT|g" \
    -e "s|@SSH_PORT@|$CASAVPN_SSH_PORT|g" \
    -e "s|@PANEL_PORT@|$CASAVPN_PANEL_PORT|g" \
    -e "s|@SUB_PORT@|$CASAVPN_SUB_PORT|g" \
    -e "s|@LAN_CIDR@|$CASAVPN_LAN_CIDR|g" \
    -e "s|@LAN_GATEWAY_RULE@|$gw_rule|g" \
    -e "s|@HTTP2_LISTEN@|$http2_listen|g" \
    -e "s|@HTTP2_ON@|$http2_on|g" \
    -e "s|@IGNOREIP_EXTRA@|$ignore_extra|g" \
    -e "s|@ADMIN_USER@|$CASAVPN_ADMIN_USER|g" \
    -e "s|@PANEL_BASE_PATH@|$base_path|g" \
    "$f")"
  if [ "$USE_TAILSCALE" = 1 ]; then
    out="$(printf '%s\n' "$out" | sed -e 's/^#@tailscale@ //')"
  else
    out="$(printf '%s\n' "$out" | sed -e '/^#@tailscale@ /d')"
  fi
  if printf '%s\n' "$out" | grep -nE '@[A-Za-z_]+@' >&2; then
    die "unresolved @TOKEN@ in template $f (a bug in install.sh)"
  fi
  printf '%s\n' "$out"
}

# render_to <template> <dest-file>: render into a temp file for validation.
# Sets RENDERED (no subshell, so a bad template stops the installer).
RENDERED=""
render_tmp() { RENDERED="$TMP/$(basename "$1").rendered"; render "$1" >"$RENDERED"; }

in_cidr() { python3 - "$1" "$2" <<'PY'
import ipaddress, sys
try:
    sys.exit(0 if ipaddress.ip_address(sys.argv[1]) in ipaddress.ip_network(sys.argv[2], strict=False) else 1)
except ValueError:
    sys.exit(2)
PY
}

service_reload() { act systemctl reload "$1" 2>/dev/null || act systemctl restart "$1"; }

# ===================================================================== preflight ==

preflight() {
  step "Preflight"
  if [ "$DRY_RUN" = 1 ]; then
    log "  dry run: nothing will be changed"
  else
    [ "$(id -u)" -eq 0 ] || die "run as root: sudo ./install.sh"
    command -v apt-get >/dev/null 2>&1 || die "this installer supports apt-based systems (Raspberry Pi OS, Debian, Ubuntu)"
    command -v systemctl >/dev/null 2>&1 || die "systemd is required"
  fi

  if [ ! -r "$ENV_FILE" ]; then
    if [ "$DRY_RUN" = 1 ]; then
      warn "$ENV_FILE does not exist; planning with the values in casavpn.env.example"
      ENV_FILE="$HERE/casavpn.env.example"
      PLAN_FROM_EXAMPLE=1
    else
      act install -d -m 0755 "$(dirname "$ENV_FILE")"
      act install -m 0600 -o root "$HERE/casavpn.env.example" "$ENV_FILE"
      log ""
      log "Created $ENV_FILE from the example. Edit it (at least CASAVPN_DOMAIN,"
      log "CASAVPN_LAN_CIDR, CASAVPN_ADMIN_USER and CASAVPN_REALITY_TARGET: see"
      log "docs/REALITY-TARGET.md for how to choose the last one), then run install.sh again."
      exit 3
    fi
  fi
  [ -r "$ENV_FILE" ] || die "cannot read $ENV_FILE"
  if [ "$DRY_RUN" = 0 ] && [ -e "$ENV_FILE" ]; then
    local perm; perm="$(stat -c %a "$ENV_FILE" 2>/dev/null || stat -f %Lp "$ENV_FILE")"
    case "$perm" in 600|400) ;; *) warn "$ENV_FILE is mode $perm: it holds an API token; tightening to 0600"; act chmod 0600 "$ENV_FILE" ;; esac
  fi
  load_env "$ENV_FILE"
  apply_defaults
  if [ "${PLAN_FROM_EXAMPLE:-0}" = 1 ] && [ -z "$CASAVPN_REALITY_TARGET" ]; then
    CASAVPN_REALITY_TARGET=www.example.net
    warn "planning with the placeholder Reality target www.example.net; a real install needs your own choice (docs/REALITY-TARGET.md)"
  fi
  validate_env
  resolve_lan_gateway
  ok "settings are valid for $CASAVPN_DOMAIN (LAN $CASAVPN_LAN_CIDR, VPN port $CASAVPN_VPN_PORT, web port $CASAVPN_WEB_PORT)"

  USE_TAILSCALE=0
  case "$TAILSCALE" in
    1) USE_TAILSCALE=1 ;;
    auto) if command -v tailscale >/dev/null 2>&1; then USE_TAILSCALE=1; fi ;;
  esac
  [ "$USE_TAILSCALE" = 0 ] || ok "firewall will include the Tailscale rules"

  PIN="$(release_pin_file "$HERE/scripts")" || PIN=""
  [ -n "$PIN" ] || PIN="$HERE/config/xui-release.env"
  [ -r "$PIN" ] || die "cannot find config/xui-release.env"
}

# ===================================================================== packages ==

PACKAGES="nginx nftables fail2ban python3-systemd sqlite3 jq age zstd curl openssl dnsutils ca-certificates tar util-linux unattended-upgrades"
CERT_PACKAGES="certbot python3-certbot-dns-cloudflare"

step_packages() {
  step "Packages"
  local pkgs="$PACKAGES"
  if [ -n "$CF_API_TOKEN" ]; then pkgs="$pkgs $CERT_PACKAGES"; fi
  log "  $pkgs"
  act env DEBIAN_FRONTEND=noninteractive apt-get update -qq
  # shellcheck disable=SC2086
  act env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends $pkgs
}

# ======================================================================== files ==

step_files() {
  step "Our scripts and helpers"
  local f
  for f in casavpn-ddns casavpn-backup casavpn-minver; do
    install_file 0755 "$HERE/scripts/$f" "$BIN_DIR/$f"
  done
  install_file 0755 "$HERE/scripts/healthcheck.sh" "$BIN_DIR/casavpn-healthcheck"
  install_file 0755 "$HERE/scripts/upgrade.sh" "$BIN_DIR/casavpn-upgrade"
  install_file 0755 "$HERE/scripts/rollback.sh" "$BIN_DIR/casavpn-rollback"
  for f in common.sh set_min_client_ver.py check_xray_template.py render_links.py; do
    install_file 0755 "$LIB/$f" "$LIB_DIR/$f"
  done
  install_file 0644 "$PIN" "$LIB_DIR/xui-release.env"
  install_file 0755 "$HERE/scripts/gen-client-links.sh" "$LIB_DIR/gen-client-links.sh"
  for f in "$HERE"/docs/*.md; do
    [ -e "$f" ] || continue
    install_file 0644 "$f" "$DOC_DIR/$(basename "$f")"
  done
  act install -d -m 0755 "$ETC/casavpn"
}

# ======================================================================== 3x-ui ==

# adopt_existing_panel: a panel database exists but our credentials file does not
# (restored backup, reinstall, a panel set up by hand). The database is the truth:
# take the user name and base path from it, and never invent a password for it.
# 3x-ui keeps only a hash of the password, so it cannot be read back.
ADOPT_NEW_PATH=0
adopt_existing_panel() {
  local user base
  user="$(xui_db_user 2>/dev/null || true)"; base="$(xui_db_base_path 2>/dev/null || true)"
  if [ "$DRY_RUN" = 1 ]; then
    log "  $XUI_DB already exists and $CRED_FILE does not: would read the user name and base path from the database"
    log "  (3x-ui stores only a password hash: the password cannot be recovered, so none would be written or printed)"
    return 0
  fi
  [ -n "$user" ] || die "$XUI_DB exists but its panel user name cannot be read (sqlite3 missing, or the database is damaged). Restore $CRED_FILE, or move the database aside and re-run."
  if [ -z "$base" ]; then
    # Stock 3x-ui serves the panel at "/": nginx cannot proxy that safely. Pick a secret path.
    base="$(openssl rand -hex 8)"; ADOPT_NEW_PATH=1
    warn "the existing panel has no secret base path; using a generated one (it is set in the database below)"
  fi
  install -d -m 0755 "$(dirname "$CRED_FILE")"
  ( umask 077
    printf '# Written by install.sh from the existing panel database. Root only.\n# PANEL_PASSWORD is absent on purpose: 3x-ui stores only a hash. To reset it:\n#   sudo %s/x-ui setting -username <user> -password <new password> && sudo systemctl restart x-ui\nPANEL_USER=%s\nPANEL_BASE_PATH=%s\n' "$XUI_DIR" "$user" "$base" >"$CRED_FILE" )
  chmod 0600 "$CRED_FILE"
  warn "the panel database already existed: read the user name and base path from it into $CRED_FILE; the password is NOT known (see the end of this run)"
}

# ensure_panel_credentials: generated once, never overwritten, never printed.
ensure_panel_credentials() {
  if [ -e "$CRED_FILE" ]; then ok "panel credentials already exist: $CRED_FILE (kept)"; return 0; fi
  if [ -e "$XUI_DB" ]; then adopt_existing_panel; return 0; fi
  if [ "$DRY_RUN" = 1 ]; then log "  would generate panel credentials into $CRED_FILE (mode 0600, never printed)"; return 0; fi
  install -d -m 0755 "$(dirname "$CRED_FILE")"
  local user pass path
  user="admin-$(openssl rand -hex 3)"
  pass="$(openssl rand -base64 24 | tr -d '/+=\n' | cut -c1-24)"
  path="$(openssl rand -hex 8)"
  ( umask 077
    printf '# Generated by install.sh. Root only. Never commit or paste this file.\nPANEL_USER=%s\nPANEL_PASSWORD=%s\nPANEL_BASE_PATH=%s\n' "$user" "$pass" "$path" >"$CRED_FILE" )
  chmod 0600 "$CRED_FILE"
  ok "generated panel credentials in $CRED_FILE"
}

sqlite_set() { # <key> <value>
  act sqlite3 "$XUI_DB" "UPDATE settings SET value='$2' WHERE key='$1'; INSERT INTO settings (key, value) SELECT '$1', '$2' WHERE NOT EXISTS (SELECT 1 FROM settings WHERE key='$1');"
}

step_3xui() {
  step "3x-ui and Xray"
  local installed_ver=""
  if [ -x "$XUI_DIR/x-ui" ] || { [ "$DRY_RUN" = 1 ] && [ -e "$XUI_DIR/x-ui" ]; }; then
    ok "3x-ui is already installed in $XUI_DIR: left alone (use casavpn-upgrade to change versions)"
    installed_ver="yes"
  fi

  if [ -z "$installed_ver" ]; then
    local version dl="$TMP/dl"
    version="$(read_pin "$PIN" XUI_VERSION)"
    log "  pinned release: $version (config/xui-release.env)"
    if [ "$DRY_RUN" = 1 ]; then
      log "  would download x-ui-linux-<arch>.tar.gz from github.com/$(read_pin "$PIN" XUI_REPO), verify its SHA-256, and unpack it to $XUI_DIR"
    else
      mkdir -p "$dl"
      fetch_xui "$PIN" "$dl" "$TRUST_SHA" "$OFFLINE_XUI"
      tar -xzf "$dl"/x-ui-linux-*.tar.gz -C "$dl"
      [ -x "$dl/x-ui/x-ui" ] || die "the tarball has no x-ui/x-ui binary"
      rm -rf "${XUI_DIR:?}"
      mv "$dl/x-ui" "$XUI_DIR"
      chmod +x "$XUI_DIR/x-ui" "$XUI_DIR"/bin/xray-linux-* 2>/dev/null || true
      [ ! -f "$XUI_DIR/x-ui.sh" ] || install -m 0755 "$XUI_DIR/x-ui.sh" /usr/bin/x-ui
      ok "unpacked 3x-ui $version to $XUI_DIR"
      install_xui_unit
    fi
  fi

  ensure_panel_credentials

  if [ "$DRY_RUN" = 1 ]; then
    log "  would set the panel username, password, port $CASAVPN_PANEL_PORT and secret base path with 'x-ui setting' (only on a fresh database),"
    log "  and bind the panel and the subscription server to 127.0.0.1 (ports $CASAVPN_PANEL_PORT and $CASAVPN_SUB_PORT)"
    log "  would enable and start x-ui"
    return 0
  fi

  if [ ! -e "$XUI_DB" ]; then
    install -d -m 0700 "$(dirname "$XUI_DB")"
    local u p b
    u="$(panel_cred PANEL_USER)"; p="$(panel_cred PANEL_PASSWORD)"; b="$(panel_cred PANEL_BASE_PATH)"
    # The CLI takes the password as an argument, so it is visible in `ps` for
    # the instant this runs. Acceptable on a single-user host; see docs/SECURITY-MODEL.md.
    "$XUI_DIR/x-ui" setting -username "$u" -password "$p" -port "$CASAVPN_PANEL_PORT" -webBasePath "/$b/" >/dev/null 2>&1 \
      || die "'x-ui setting' failed; run it by hand to see why: $XUI_DIR/x-ui setting -h"
    "$XUI_DIR/x-ui" migrate >/dev/null 2>&1 || warn "'x-ui migrate' reported a problem (harmless on a fresh install; check 'journalctl -u x-ui')"
    ok "panel username, password, port and base path set (credentials: $CRED_FILE)"
  else
    ok "$XUI_DB already exists: panel credentials left as they are"
  fi
  [ -e "$XUI_DB" ] || die "3x-ui did not create $XUI_DB"

  systemctl stop x-ui 2>/dev/null || true
  if [ "$ADOPT_NEW_PATH" = 1 ]; then sqlite_set webBasePath "/$(panel_cred PANEL_BASE_PATH)/"; fi
  sqlite_set webListen 127.0.0.1
  sqlite_set subListen 127.0.0.1
  sqlite_set subPort "$CASAVPN_SUB_PORT"
  sqlite_set subEnable true
  sqlite_set webPort "$CASAVPN_PANEL_PORT"
  chmod 0600 "$XUI_DB" 2>/dev/null || true
  ok "panel and subscriptions bound to 127.0.0.1"
  systemctl daemon-reload
  systemctl enable --now x-ui >/dev/null 2>&1 || die "x-ui did not start; see: journalctl -u x-ui -n 50"

  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if (exec 3<>"/dev/tcp/127.0.0.1/$CASAVPN_PANEL_PORT") 2>/dev/null; then ok "the panel answers on 127.0.0.1:$CASAVPN_PANEL_PORT"; break; fi
    sleep 1
    [ "$i" -lt 10 ] || warn "the panel is not answering on 127.0.0.1:$CASAVPN_PANEL_PORT yet (check: journalctl -u x-ui -n 50)"
  done
}

install_xui_unit() {
  local unit
  for unit in "$XUI_DIR/x-ui.service.debian" "$XUI_DIR/x-ui.service"; do
    if [ -f "$unit" ]; then
      install -m 0644 "$unit" "$SYSTEMD_DIR/x-ui.service"
      ok "installed the systemd unit shipped with the release ($(basename "$unit"))"
      return 0
    fi
  done
  install -m 0644 "$HERE/config/systemd/x-ui.service.fallback" "$SYSTEMD_DIR/x-ui.service"
  warn "the release ships no systemd unit; installed our minimal fallback (no sandboxing)"
}

# ======================================================================== certs ==

# write_cloudflare_ini: certbot's renewals read the token from this file, so it is
# rewritten on EVERY run that has a token. A rotated token reaches it even when the
# certificate already exists; leaving the old one would fail renewals until expiry.
write_cloudflare_ini() {
  local want tmp
  want="$(printf 'dns_cloudflare_api_token = %s\n' "$CF_API_TOKEN")"
  if [ "$DRY_RUN" = 1 ]; then
    log "  would write $CF_INI (mode 0600) from CF_API_TOKEN, replacing any older token"
    return 0
  fi
  install -d -m 0755 "$(dirname "$CF_INI")"
  if [ -f "$CF_INI" ] && [ "$(cat "$CF_INI")" = "$want" ]; then
    chmod 0600 "$CF_INI"
    ok "$CF_INI already holds the current token"
    return 0
  fi
  tmp="$(mktemp "$CF_INI.XXXXXX")"
  ( umask 077; printf '%s\n' "$want" >"$tmp" )
  chmod 0600 "$tmp"
  mv -f "$tmp" "$CF_INI"
  ok "wrote the current CF_API_TOKEN to $CF_INI (mode 0600)"
}

step_certs() {
  step "TLS certificate (Let's Encrypt, DNS-01 through Cloudflare)"
  if [ -z "$CF_API_TOKEN" ]; then
    warn "CF_API_TOKEN is empty: no certificate, no DDNS. The VPN works without them; the subscription web port does not."
    leave "Get a certificate and turn on DDNS: set CF_API_TOKEN and CF_ZONE_ID in $ENV_FILE and run install.sh again (docs/DYNAMIC-IP.md)."
    return 0
  fi
  write_cloudflare_ini
  if [ "$CASAVPN_ACME_AGREE_TOS" != 1 ]; then
    warn "Let's Encrypt needs you to accept its Subscriber Agreement (https://letsencrypt.org/repository/)."
    warn "Read it, then set CASAVPN_ACME_AGREE_TOS=1 in $ENV_FILE and run install.sh again. Skipping the certificate."
    leave "Accept the Let's Encrypt Subscriber Agreement by setting CASAVPN_ACME_AGREE_TOS=1 in $ENV_FILE, then re-run install.sh."
    return 0
  fi
  if [ -e "$LE_DIR/live/$CASAVPN_DOMAIN/fullchain.pem" ]; then
    ok "a certificate for $CASAVPN_DOMAIN already exists (certbot renews it with the token in $CF_INI)"
  else
    if [ "$DRY_RUN" = 1 ]; then
      log "  would run certbot certonly --dns-cloudflare for $CASAVPN_DOMAIN"
    else
      local -a args=(certonly --dns-cloudflare --dns-cloudflare-credentials "$CF_INI" --dns-cloudflare-propagation-seconds 30
        -d "$CASAVPN_DOMAIN" --non-interactive --agree-tos --keep-until-expiring)
      if [ -n "$CASAVPN_ACME_EMAIL" ]; then args+=(-m "$CASAVPN_ACME_EMAIL"); else args+=(--register-unsafely-without-email); fi
      if [ "$CASAVPN_ACME_STAGING" = 1 ]; then args+=(--staging); warn "using the Let's Encrypt STAGING service: the certificate will not be trusted by clients"; fi
      certbot "${args[@]}" >&2 || die "certbot failed. Check the token's scope (Zone > DNS > Edit) and that $CASAVPN_DOMAIN is in the zone."
      ok "certificate issued for $CASAVPN_DOMAIN"
    fi
  fi
  install_file 0755 "$HERE/config/certbot-deploy-hook.sh" "$LE_DIR/renewal-hooks/deploy/casavpn-reload-nginx.sh"
  if [ "$DRY_RUN" = 1 ]; then
    log "  would make sure certbot.timer is enabled"
  else
    systemctl enable --now certbot.timer >/dev/null 2>&1 || warn "could not enable certbot.timer; renew by hand: certbot renew"
  fi
}

# ======================================================================== nginx ==

step_nginx() {
  step "nginx (web front end on port $CASAVPN_WEB_PORT)"
  install_file 0644 "$HERE/config/nginx/00-casavpn.conf" "$ETC/nginx/conf.d/00-casavpn.conf"
  render_tmp "$HERE/config/nginx/casavpn-admin-only.conf.tmpl"
  install_file 0644 "$RENDERED" "$ETC/nginx/snippets/casavpn-admin-only.conf"
  render_tmp "$HERE/config/nginx/casavpn.conf.tmpl"
  install_file 0644 "$RENDERED" "$ETC/nginx/sites-available/casavpn"

  if [ ! -e "$LE_DIR/live/$CASAVPN_DOMAIN/fullchain.pem" ] && [ "$DRY_RUN" = 0 ]; then
    warn "no certificate yet: the site is written but not enabled"
    leave "Enable the web front end once a certificate exists: re-run install.sh (it links /etc/nginx/sites-enabled/casavpn)."
    return 0
  fi
  if [ "$DRY_RUN" = 1 ]; then
    log "  would disable nginx's default site, enable sites-enabled/casavpn, run nginx -t and reload"
    return 0
  fi
  if [ -L "$ETC/nginx/sites-enabled/default" ]; then rm -f "$ETC/nginx/sites-enabled/default"; ok "disabled nginx's default site (a symlink; the file is still in sites-available)"; fi
  ln -sfn ../sites-available/casavpn "$ETC/nginx/sites-enabled/casavpn"
  if nginx -t >/dev/null 2>&1; then
    service_reload nginx
    systemctl enable nginx >/dev/null 2>&1 || true
    ok "nginx is serving $CASAVPN_DOMAIN on port $CASAVPN_WEB_PORT"
  else
    rm -f "$ETC/nginx/sites-enabled/casavpn"
    nginx -t >&2 || true
    die "nginx -t failed; the casavpn site was not enabled (output above)"
  fi
}

# ========================================================================= ssh ==

sshd_service() { if systemctl cat ssh.service >/dev/null 2>&1; then echo ssh; else echo sshd; fi; }

step_ssh() {
  step "SSH hardening"
  local dst="$ETC/ssh/sshd_config.d/00-casavpn-hardening.conf" home keys
  if [ "$DRY_RUN" = 1 ]; then
    log "  would require an authorized key for $CASAVPN_ADMIN_USER, install $dst, run sshd -t, and reload sshd (your open session stays)"
    render_tmp "$HERE/config/sshd/00-casavpn-hardening.conf.tmpl"
    return 0
  fi
  if ! id "$CASAVPN_ADMIN_USER" >/dev/null 2>&1; then
    warn "user $CASAVPN_ADMIN_USER does not exist: SSH hardening skipped"
    leave "SSH is NOT hardened: create the user $CASAVPN_ADMIN_USER (or fix CASAVPN_ADMIN_USER) and re-run install.sh."
    return 0
  fi
  home="$(getent passwd "$CASAVPN_ADMIN_USER" | cut -d: -f6)"
  keys="$home/.ssh/authorized_keys"
  if ! grep -Eq '^(ssh-|ecdsa-|sk-)' "$keys" 2>/dev/null; then
    warn "$keys has no public key: turning password login off would lock you out. SSH hardening skipped."
    leave "SSH is NOT hardened: add your public key to $keys (ssh-copy-id $CASAVPN_ADMIN_USER@<host>), test a key login, then re-run install.sh."
    return 0
  fi
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "$CASAVPN_ADMIN_USER" ] && [ "$FORCE_SSH" = 0 ]; then
    warn "you are running this as $SUDO_USER but AllowUsers would allow only $CASAVPN_ADMIN_USER. Skipped; --force-ssh overrides."
    leave "SSH is NOT hardened: run install.sh as $CASAVPN_ADMIN_USER (sudo ./install.sh), or pass --force-ssh."
    return 0
  fi
  local previous=""
  [ ! -e "$dst" ] || { previous="$TMP/sshd.previous"; cp -p "$dst" "$previous"; }
  render_tmp "$HERE/config/sshd/00-casavpn-hardening.conf.tmpl"
  install_file 0644 "$RENDERED" "$dst"
  if sshd -t 2>"$TMP/sshd.err"; then
    systemctl reload "$(sshd_service)"
    ok "sshd reloaded: key-only login for $CASAVPN_ADMIN_USER"
    leave "Open a NEW terminal and log in over SSH to confirm the hardened login works, before you close this session."
  else
    if [ -n "$previous" ]; then cp -p "$previous" "$dst"; else rm -f "$dst"; fi
    cat "$TMP/sshd.err" >&2
    die "sshd -t rejected the configuration; the drop-in was removed and sshd was not reloaded"
  fi
}

# ===================================================================== firewall ==

step_firewall() {
  step "Firewall (nftables)"
  local dst="$ETC/nftables.conf" rendered client
  render_tmp "$HERE/config/nftables.conf.tmpl"
  rendered="$RENDERED"
  if [ "$DRY_RUN" = 1 ]; then
    log "  would check this SSH session is from $CASAVPN_LAN_CIDR, validate with nft -c, install $dst, load it and enable nftables.service"
    return 0
  fi
  client="${SSH_CONNECTION:-}"; client="${client%% *}"
  if [ -n "$client" ] && [ "$FORCE_FW" = 0 ]; then
    if ! in_cidr "$client" "$CASAVPN_LAN_CIDR"; then
      warn "this SSH session comes from $client, which is outside $CASAVPN_LAN_CIDR. The firewall allows SSH from the LAN only,"
      warn "so loading it now would cut you off. Firewall skipped. Fix CASAVPN_LAN_CIDR, run from the LAN, or pass --force-firewall."
      leave "The firewall is NOT loaded: run install.sh from a machine inside $CASAVPN_LAN_CIDR (or correct CASAVPN_LAN_CIDR)."
      return 0
    fi
  fi
  command -v nft >/dev/null 2>&1 || die "nft is not installed"
  nft -c -f "$rendered" 2>"$TMP/nft.err" || { cat "$TMP/nft.err" >&2; die "nft rejected the generated firewall; nothing was loaded"; }
  ok "the generated ruleset is valid (nft -c)"

  backup_foreign "$dst"
  local previous="$TMP/nftables.previous"
  [ ! -e "$dst" ] || cp -p "$dst" "$previous"
  install -m 0755 -o root "$rendered" "$dst"
  nft -f "$dst"
  ok "firewall loaded"

  if [ -t 0 ] && [ "$ASSUME_YES" = 0 ]; then
    log ""
    log "  The firewall is live. Open a SECOND terminal and check you can still reach this host."
    log "  Type 'keep' within 90 seconds to keep it. Anything else (or silence) removes it again."
    local answer=""
    read -r -t 90 answer || true
    if [ "$answer" != keep ]; then
      nft delete table inet casavpn 2>/dev/null || true
      if [ -e "$previous" ]; then cp -p "$previous" "$dst"; else rm -f "$dst"; fi
      warn "firewall removed again (no confirmation). The file on disk was restored."
      leave "The firewall is NOT loaded: you did not confirm. Re-run install.sh --skip-3xui when you are ready."
      return 0
    fi
  fi
  systemctl enable nftables >/dev/null 2>&1 || warn "could not enable nftables.service: the rules will not survive a reboot"
  ok "nftables.service enabled: the rules load at boot"
}

# ==================================================================== fail2ban ==

step_fail2ban() {
  step "fail2ban"
  render_tmp "$HERE/config/fail2ban/casavpn.conf.tmpl"
  install_file 0644 "$RENDERED" "$ETC/fail2ban/jail.d/casavpn.conf"
  if [ "$DRY_RUN" = 1 ]; then log "  would enable and reload fail2ban"; return 0; fi
  systemctl enable --now fail2ban >/dev/null 2>&1 || warn "fail2ban did not start; see: journalctl -u fail2ban"
  fail2ban-client reload >/dev/null 2>&1 || true
}

# ====================================================================== timers ==

step_timers() {
  step "Timers: DDNS and backups"
  local f
  for f in casavpn-ddns.service casavpn-ddns.timer casavpn-backup.service casavpn-backup.timer; do
    install_file 0644 "$HERE/config/systemd/$f" "$SYSTEMD_DIR/$f"
  done
  if [ "$DRY_RUN" = 1 ]; then
    log "  would enable casavpn-ddns.timer if CF_API_TOKEN is set, and casavpn-backup.timer if AGE_RECIPIENT is set"
  else
    systemctl daemon-reload
    if [ -n "$CF_API_TOKEN" ] && [ -n "$CF_ZONE_ID" ]; then
      systemctl enable --now casavpn-ddns.timer >/dev/null 2>&1 && ok "casavpn-ddns.timer enabled (every minute)"
      /usr/local/bin/casavpn-ddns --dry-run >&2 || warn "casavpn-ddns --dry-run failed; read the message above (token scope? zone id?)"
    else
      warn "DDNS is not enabled (no Cloudflare settings)"
      leave "Dynamic IP: without DDNS the VPN stops working when your ISP changes your address (docs/DYNAMIC-IP.md)."
    fi
    if [ -n "$AGE_RECIPIENT" ]; then
      systemctl enable --now casavpn-backup.timer >/dev/null 2>&1 && ok "casavpn-backup.timer enabled (03:30 daily)"
    else
      warn "backups are not enabled (AGE_RECIPIENT is empty)"
      leave "Backups: run 'age-keygen -o ~/.config/casavpn/age-identity.txt' on your LAPTOP, put the public key in AGE_RECIPIENT, re-run install.sh (docs/BACKUP.md)."
    fi
  fi
}

# ====================================================================== updates ==

step_updates() {
  step "Unattended security upgrades"
  local f="$ETC/apt/apt.conf.d/20auto-upgrades"
  if [ -e "$f" ]; then ok "$f exists (kept)"; return 0; fi
  if [ "$DRY_RUN" = 1 ]; then log "  would write $f"; return 0; fi
  printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' >"$f"
  ok "enabled daily security upgrades"
}

# ======================================================================= summary ==

# print_panel_access: how to open the panel, and where its credentials are, truthfully.
print_panel_access() {
  cat >&2 <<EOF
  Open the panel from a machine on the LAN, by the HOSTNAME. The certificate is issued
  for $CASAVPN_DOMAIN and nginx refuses a TLS handshake for a bare IP, so point the name at
  this host's LAN address on that machine (a hosts entry, or split DNS on your router):
      echo '<LAN_IP> $CASAVPN_DOMAIN' | sudo tee -a /etc/hosts
      https://$CASAVPN_DOMAIN:$CASAVPN_WEB_PORT/<base path>/
  Over Tailscale do the same with the host's Tailscale address. If the name points at your
  PUBLIC address the request hairpins through the router and is refused on purpose.
  (Before the certificate exists nginx is not serving it yet; tunnel instead:
      ssh -L 8080:127.0.0.1:$CASAVPN_PANEL_PORT $CASAVPN_ADMIN_USER@<LAN_IP>   then   http://127.0.0.1:8080/<base path>/ )
EOF
  if [ -n "$(panel_cred PANEL_PASSWORD 2>/dev/null || true)" ]; then
    cat >&2 <<EOF
  The base path, username and password are in $CRED_FILE (root only):
      sudo cat $CRED_FILE
EOF
  elif [ -e "$XUI_DB" ] || [ -e "$CRED_FILE" ]; then
    cat >&2 <<EOF
  This panel already existed, so CasaVPN did not set a password and cannot show one
  (3x-ui stores only a hash). The base path and user name are in $CRED_FILE (root only).
  If you do not know the password, reset it and restart the panel:
      sudo $XUI_DIR/x-ui setting -username <user> -password '<new password>'
      sudo systemctl restart x-ui
EOF
  else
    cat >&2 <<EOF
  The base path, username and password are generated into $CRED_FILE (root only):
      sudo cat $CRED_FILE
EOF
  fi
}

print_inbound_guide() {
  cat >&2 <<EOF

${C_B}Create the VPN inbound in the panel${C_Z} (the one step left to you; the panel does it better than a script)

EOF
  print_panel_access
  cat >&2 <<EOF
  Inbounds -> Add Inbound:
      Remark              main
      Protocol            vless
      Listen IP           (leave empty = all interfaces)
      Port                $CASAVPN_VPN_PORT
      Transmission        TCP (RAW)
      Security            Reality
      uTLS                chrome
      Target / Dest       $CASAVPN_REALITY_TARGET:443
      SNI (Server names)  $CASAVPN_REALITY_TARGET
      Short IDs           use the generated ones
      "Get New Cert"      click it to generate the Reality key pair
  Add a client per person/device:
      Flow                xtls-rprx-vision
      Email               a label such as alice-phone (it appears in the client's link)
  Then:
      sudo casavpn-minver         # sets minClientVer=$CASAVPN_MIN_CLIENT_VER on the inbound and restarts x-ui
      casavpn-healthcheck --local
EOF
}

print_summary() {
  step "Done"
  if [ "$DRY_RUN" = 1 ]; then
    log "  dry run finished: nothing was changed."
  else
    log "  Installed. A full log of what changed is in your terminal scrollback."
  fi
  print_inbound_guide
  cat >&2 <<EOF

${C_B}What is left for you${C_Z}
  1. Router: give this host a fixed LAN address (DHCP reservation) and forward ONLY these two TCP ports to it:
       $CASAVPN_VPN_PORT  (the VPN)      $CASAVPN_WEB_PORT  (client subscriptions)
     Do not forward 22, $CASAVPN_PANEL_PORT or $CASAVPN_SUB_PORT. Port 80 is not needed.
  2. Create the inbound and clients in the panel (above), turn on the panel's two-factor login (docs/HARDENING.md).
  3. Test from OUTSIDE your home network (a phone on mobile data): docs/CLIENTS.md.
EOF
  local n=4 item
  for item in ${LEFT[@]+"${LEFT[@]}"}; do
    printf '  %d. %s\n' "$n" "$item" >&2
    n=$((n + 1))
  done
  if [ "$USE_TAILSCALE" = 1 ]; then
    printf '  %d. Tailscale: run "sudo tailscale up" and open the URL it prints (the firewall already allows it).\n' "$n" >&2
  fi
  log ""
  log "  CasaVPN 0.1.0 is a first release: the installer is covered by offline tests, not yet by a run on a clean host. Read the CHANGELOG, and check each step above."
}

# ========================================================================== main ==

show_config() {
  case "$SHOW" in
    nftables)    render "$HERE/config/nftables.conf.tmpl" ;;
    nginx)       render "$HERE/config/nginx/casavpn.conf.tmpl" ;;
    nginx-admin) render "$HERE/config/nginx/casavpn-admin-only.conf.tmpl" ;;
    sshd)        render "$HERE/config/sshd/00-casavpn-hardening.conf.tmpl" ;;
    fail2ban)    render "$HERE/config/fail2ban/casavpn.conf.tmpl" ;;
    *) echo "--show: unknown name '$SHOW' (nftables | nginx | nginx-admin | sshd | fail2ban)" >&2; exit 2 ;;
  esac
}

main() {
  if [ -n "$SHOW" ]; then
    preflight >&2
    show_config
    exit 0
  fi
  preflight
  skipped packages  || step_packages
  skipped files     || step_files
  skipped 3xui      || step_3xui
  skipped certs     || step_certs
  skipped nginx     || step_nginx
  skipped ssh       || step_ssh
  skipped firewall  || step_firewall
  skipped fail2ban  || step_fail2ban
  skipped timers    || step_timers
  skipped updates   || step_updates
  print_summary
  if [ "$DRY_RUN" = 0 ] && command -v casavpn-healthcheck >/dev/null 2>&1; then
    step "Health check"
    casavpn-healthcheck --local --env "$ENV_FILE" || true
  fi
}

main
