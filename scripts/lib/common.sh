# shellcheck shell=bash
#
# common.sh: helpers shared by install.sh, casavpn-upgrade and casavpn-rollback.
# Sourced, never executed. Compatible with bash 3.2 so `install.sh --dry-run`
# also works on a Mac.
#
# The caller sets (before or after sourcing):
#   DRY_RUN=0|1      act() and friends only print when 1
#   ENV_FILE         the settings file (default /etc/casavpn/casavpn.env)

: "${DRY_RUN:=0}"
: "${ENV_FILE:=/etc/casavpn/casavpn.env}"

if [ -t 2 ]; then C_R=$'\033[31m'; C_Y=$'\033[33m'; C_G=$'\033[32m'; C_B=$'\033[1m'; C_Z=$'\033[0m'; else C_R=""; C_Y=""; C_G=""; C_B=""; C_Z=""; fi
log()  { printf '%s\n' "$*" >&2; }
step() { printf '\n%s== %s%s\n' "$C_B" "$*" "$C_Z" >&2; }
ok()   { printf '  %sok%s    %s\n' "$C_G" "$C_Z" "$*" >&2; }
warn() { printf '  %swarn%s  %s\n' "$C_Y" "$C_Z" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$C_R" "$C_Z" "$*" >&2; exit 1; }

# act <cmd...>: run a command, or only print it under --dry-run.
act() {
  if [ "$DRY_RUN" = 1 ]; then printf '  would run: %s\n' "$*" >&2; return 0; fi
  "$@"
}

# load_env <file>: parse KEY=VALUE lines (never sourced, never executed).
# A variable that is already set in the environment wins over the file.
load_env() {
  local file="$1" line key val
  _ENV_SET="${_ENV_SET:-}"
  [ -r "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*|[[:space:]]*'#'*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"; val="${line#*=}"
    key="${key#"${key%%[![:space:]]*}"}"; key="${key%"${key##*[![:space:]]}"}"
    case "$key" in ''|*[!A-Za-z0-9_]*|[0-9]*) continue ;; esac
    val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
    case "$val" in
      \"*\") val="${val#\"}"; val="${val%\"}" ;;
      \'*\') val="${val#\'}"; val="${val%\'}" ;;
    esac
    # The environment wins over the file; within the file the last line wins.
    # An empty value in the file is still "set".
    if [ -z "${!key+x}" ] || [[ " $_ENV_SET " == *" $key "* ]]; then
      export "$key=$val"
      [[ " $_ENV_SET " == *" $key "* ]] || _ENV_SET="$_ENV_SET $key"
    fi
  done <"$file"
}

# apply_defaults: the documented defaults for everything optional.
apply_defaults() {
  : "${CASAVPN_VPN_PORT:=443}"
  : "${CASAVPN_WEB_PORT:=8443}"
  : "${CASAVPN_SSH_PORT:=22}"
  : "${CASAVPN_PANEL_PORT:=2053}"
  : "${CASAVPN_SUB_PORT:=2096}"
  : "${CASAVPN_LAN_CIDR:=192.168.0.0/24}"
  # The router's LAN address. Empty = detect it from the default route; "none" = no deny rule.
  : "${CASAVPN_LAN_GATEWAY:=}"
  : "${CASAVPN_FAIL2BAN_IGNOREIP:=}"
  : "${CASAVPN_ADMIN_USER:=pi}"
  # No default on purpose: a shared default site is a fingerprint (docs/REALITY-TARGET.md).
  : "${CASAVPN_REALITY_TARGET:=}"
  : "${CASAVPN_MIN_CLIENT_VER:=1.8.0}"
  # pinned = the Xray core in config/xray-core.env; bundled = whatever 3x-ui ships.
  : "${CASAVPN_XRAY_CORE:=pinned}"
  : "${CASAVPN_DDNS_PROVIDER:=cloudflare}"
  : "${CASAVPN_ACME_STAGING:=0}"
  : "${CASAVPN_ACME_AGREE_TOS:=0}"
  : "${CASAVPN_BACKUP_KEEP:=14}"
  : "${CF_API_TOKEN:=}"
  : "${CF_ZONE_ID:=}"
  : "${NTFY_URL:=}"
  # The alert relay of the iPhone app (docs/APP.md). Both or neither.
  : "${CASAVPN_RELAY_URL:=}"
  : "${CASAVPN_RELAY_TOKEN:=}"
  : "${AGE_RECIPIENT:=}"
  : "${CASAVPN_ACME_EMAIL:=}"
  : "${CASAVPN_BACKUP_GROUP:=}"
  : "${CASAVPN_SSH_TARGET:=}"
  export CASAVPN_VPN_PORT CASAVPN_WEB_PORT CASAVPN_SSH_PORT CASAVPN_PANEL_PORT CASAVPN_SUB_PORT \
    CASAVPN_LAN_CIDR CASAVPN_LAN_GATEWAY CASAVPN_FAIL2BAN_IGNOREIP CASAVPN_ADMIN_USER CASAVPN_REALITY_TARGET CASAVPN_MIN_CLIENT_VER CASAVPN_XRAY_CORE \
    CASAVPN_DDNS_PROVIDER CASAVPN_ACME_STAGING CASAVPN_ACME_AGREE_TOS CASAVPN_BACKUP_KEEP
}

valid_port() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
valid_host() { [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
valid_ip4() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local o IFS=.
  # shellcheck disable=SC2086
  set -- $1
  for o in "$@"; do [ "$o" -le 255 ] || return 1; done
}
valid_cidr() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || return 1
  local ip="${1%/*}" bits="${1#*/}" o IFS=.
  # shellcheck disable=SC2086
  set -- $ip
  for o in "$@"; do [ "$o" -le 255 ] || return 1; done
  [ "$bits" -le 32 ]
}

# validate_env: die with every problem at once, not one per run.
validate_env() {
  local bad=0 p
  complain() { log "  - $*"; bad=1; }
  log "Checking $ENV_FILE ..."
  if [ -z "${CASAVPN_DOMAIN:-}" ]; then complain "CASAVPN_DOMAIN is not set"
  elif ! valid_host "$CASAVPN_DOMAIN"; then complain "CASAVPN_DOMAIN is not a hostname: $CASAVPN_DOMAIN"; fi
  valid_cidr "$CASAVPN_LAN_CIDR" || complain "CASAVPN_LAN_CIDR is not a CIDR like 192.168.0.0/24: $CASAVPN_LAN_CIDR"
  case "$CASAVPN_LAN_GATEWAY" in ''|none) ;; *) valid_ip4 "$CASAVPN_LAN_GATEWAY" || complain "CASAVPN_LAN_GATEWAY is not an IPv4 address (or 'none'): $CASAVPN_LAN_GATEWAY" ;; esac
  if [ -n "$CASAVPN_FAIL2BAN_IGNOREIP" ] && ! [[ "$CASAVPN_FAIL2BAN_IGNOREIP" =~ ^[0-9A-Fa-f:./,[:space:]]+$ ]]; then
    complain "CASAVPN_FAIL2BAN_IGNOREIP is not a list of addresses or CIDRs separated by spaces or commas: $CASAVPN_FAIL2BAN_IGNOREIP"
  fi
  [[ "$CASAVPN_ADMIN_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || complain "CASAVPN_ADMIN_USER is not a valid user name: $CASAVPN_ADMIN_USER"
  for p in VPN_PORT WEB_PORT SSH_PORT PANEL_PORT SUB_PORT; do
    eval "valid_port \"\$CASAVPN_$p\"" || complain "CASAVPN_$p is not a port (1-65535)"
  done
  if [ "$CASAVPN_VPN_PORT" = "$CASAVPN_WEB_PORT" ]; then complain "CASAVPN_VPN_PORT and CASAVPN_WEB_PORT must differ"; fi
  if [ "$CASAVPN_PANEL_PORT" = "$CASAVPN_SUB_PORT" ]; then complain "CASAVPN_PANEL_PORT and CASAVPN_SUB_PORT must differ"; fi
  if [ -z "$CASAVPN_REALITY_TARGET" ]; then complain "CASAVPN_REALITY_TARGET is empty: choose the site Reality imitates, see docs/REALITY-TARGET.md"
  elif ! valid_host "$CASAVPN_REALITY_TARGET"; then complain "CASAVPN_REALITY_TARGET is not a hostname: $CASAVPN_REALITY_TARGET"; fi
  if [ "$CASAVPN_VPN_PORT" != 443 ]; then warn "CASAVPN_VPN_PORT is $CASAVPN_VPN_PORT, not 443: Xray warns that a non-443 Reality port makes the server's IP more likely to be blocked (docs/REALITY-TARGET.md)"; fi
  [[ "$CASAVPN_MIN_CLIENT_VER" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || complain "CASAVPN_MIN_CLIENT_VER is not a version like 1.8.0"
  case "$CASAVPN_XRAY_CORE" in pinned|bundled) ;; *) complain "CASAVPN_XRAY_CORE '$CASAVPN_XRAY_CORE' is unknown (pinned | bundled)" ;; esac
  case "$CASAVPN_DDNS_PROVIDER" in cloudflare) ;; *) complain "CASAVPN_DDNS_PROVIDER '$CASAVPN_DDNS_PROVIDER' is unknown (cloudflare)" ;; esac
  if [ -n "$AGE_RECIPIENT" ] && ! [[ "$AGE_RECIPIENT" =~ ^age1[a-z0-9]{50,}$ ]]; then complain "AGE_RECIPIENT is not an age public key (age1...)"; fi
  if [ -n "$CF_API_TOKEN" ] && [ -z "$CF_ZONE_ID" ]; then complain "CF_API_TOKEN is set but CF_ZONE_ID is not"; fi
  if [ -n "$CASAVPN_RELAY_URL" ] && ! [[ "$CASAVPN_RELAY_URL" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$ ]]; then complain "CASAVPN_RELAY_URL is not an https:// URL: $CASAVPN_RELAY_URL"; fi
  if [ -n "$CASAVPN_RELAY_URL" ] && [ -z "$CASAVPN_RELAY_TOKEN" ]; then complain "CASAVPN_RELAY_URL is set but CASAVPN_RELAY_TOKEN (the host token) is not"; fi
  if [ -z "$CASAVPN_RELAY_URL" ] && [ -n "$CASAVPN_RELAY_TOKEN" ]; then complain "CASAVPN_RELAY_TOKEN is set but CASAVPN_RELAY_URL is not"; fi
  if [ -n "$CASAVPN_RELAY_TOKEN" ] && [[ "$CASAVPN_RELAY_TOKEN" =~ [^A-Za-z0-9._~+/=-] ]]; then complain "CASAVPN_RELAY_TOKEN has characters a token should not have (letters, digits and . _ ~ + / = - only)"; fi
  [ "$bad" = 0 ] || die "fix the settings above in $ENV_FILE and run again"
}

# unique_path <path>: <path>, or <path>.2, .3 ... when it already exists.
unique_path() {
  local p="$1" n=2
  while [ -e "$p" ]; do p="$1.$n"; n=$((n + 1)); done
  printf '%s' "$p"
}

# --- 3x-ui release pin -----------------------------------------------------------
# release_pin_file: config/xui-release.env, next to the repo or installed.
release_pin_file() {
  local here="${1:-}" c
  if [ -n "${CASAVPN_XUI_PIN:-}" ]; then printf '%s' "$CASAVPN_XUI_PIN"; return 0; fi
  for c in "$here/../../config/xui-release.env" "$here/../config/xui-release.env" "$here/config/xui-release.env" "$here/xui-release.env" /usr/local/lib/casavpn/xui-release.env; do
    if [ -r "$c" ]; then printf '%s' "$c"; return 0; fi
  done
  return 1
}

# read_pin <file> <KEY>
read_pin() { grep -E "^$2=" "$1" | tail -n1 | cut -d= -f2- ; }

xui_arch() {
  case "$(uname -m)" in
    aarch64|arm64) echo arm64 ;;
    x86_64|amd64)  echo amd64 ;;
    *) return 1 ;;
  esac
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# fetch_xui <pin-file> <dest-dir> [trust-release-sha=0] [offline-tarball]
# Leaves <dest-dir>/x-ui-linux-<arch>.tar.gz, verified against the pinned
# SHA-256. If the pinned hash for this architecture is empty, or does not match,
# it stops, unless the caller passed trust=1, in which case the hash published
# next to the release is used instead (that proves the download is intact, not
# that the release is genuine: both come from the same place).
fetch_xui() {
  local pin="$1" dest="$2" trust="${3:-0}" offline="${4:-}" arch version repo want got file url
  arch="$(xui_arch)" || die "unsupported CPU architecture: $(uname -m) (3x-ui ships amd64 and arm64)"
  version="$(read_pin "$pin" XUI_VERSION)"; repo="$(read_pin "$pin" XUI_REPO)"
  [ -n "$version" ] && [ -n "$repo" ] || die "$pin is missing XUI_VERSION or XUI_REPO"
  if [ "$arch" = arm64 ]; then want="$(read_pin "$pin" XUI_SHA256_ARM64)"; else want="$(read_pin "$pin" XUI_SHA256_AMD64)"; fi
  file="$dest/x-ui-linux-$arch.tar.gz"
  if [ -n "$offline" ]; then
    [ -r "$offline" ] || die "cannot read $offline"
    cp "$offline" "$file"
  else
    url="https://github.com/$repo/releases/download/$version/x-ui-linux-$arch.tar.gz"
    log "  downloading $url"
    curl -fL --proto '=https' --tlsv1.2 --retry 3 --max-time 300 -o "$file" "$url" || die "download failed: $url"
  fi
  got="$(sha256_of "$file")"
  if [ -n "$want" ] && [ "$got" = "$want" ]; then
    ok "sha256 matches the pinned value ($version, $arch)"
    return 0
  fi
  if [ "$trust" != 1 ]; then
    rm -f "$file"
    die "sha256 of the download ($got) does not match the pinned value (${want:-none for $arch}). Nothing was installed. If you are deliberately installing a different release, update config/xui-release.env, or pass --trust-release-sha to use the hash published next to the release."
  fi
  [ -z "$offline" ] || die "--trust-release-sha cannot be combined with --offline-xui (there is no release to ask)"
  local pub
  pub="$(curl -fsSL --proto '=https' --tlsv1.2 --max-time 60 "$url.sha256" 2>/dev/null | awk '{print $1; exit}')"
  if [ -n "$pub" ] && [ "$got" = "$pub" ]; then
    warn "pinned hash did not match, but the hash published with the release does ($version): continuing because you passed --trust-release-sha"
    return 0
  fi
  rm -f "$file"
  die "sha256 of the download ($got) matches neither the pinned value nor the published one (${pub:-unavailable}). Nothing was installed."
}

# --- Xray core pin ---------------------------------------------------------------
# The core 3x-ui bundles is replaced by the one in config/xray-core.env, handled
# like the tarball pin: parsed, downloaded over HTTPS, refused on a SHA-256
# mismatch. Why it exists: config/xray-core.env.

# core_pin_file: config/xray-core.env, next to the repo or installed.
core_pin_file() {
  local here="${1:-}" c
  if [ -n "${CASAVPN_XRAY_PIN:-}" ]; then printf '%s' "$CASAVPN_XRAY_PIN"; return 0; fi
  for c in "$here/../../config/xray-core.env" "$here/../config/xray-core.env" "$here/config/xray-core.env" "$here/xray-core.env" /usr/local/lib/casavpn/xray-core.env; do
    if [ -r "$c" ]; then printf '%s' "$c"; return 0; fi
  done
  return 1
}

# xray_version <binary>: the version it reports (26.7.28), or empty.
xray_version() {
  "$1" version 2>/dev/null | head -n1 | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true
}

# fetch_xray_core <pin-file> <dest-dir> [offline-zip]
# Leaves the verified, executable core at <dest-dir>/xray. The zip's SHA-256 must
# match the pin (there is no "trust the published hash" escape here: the point of
# the pin is that the core is the one that was tested). The binary must also run
# and report the pinned version, so a wrong-architecture or truncated file stops
# here, before anything on the host is touched.
fetch_xray_core() {
  local pin="$1" dest="$2" offline="${3:-}" arch version repo want got zipname url zip
  arch="$(xui_arch)" || die "unsupported CPU architecture: $(uname -m) (the Xray core pin covers amd64 and arm64)"
  version="$(read_pin "$pin" XRAY_CORE_VERSION)"; repo="$(read_pin "$pin" XRAY_CORE_REPO)"
  [ -n "$version" ] && [ -n "$repo" ] || die "$pin is missing XRAY_CORE_VERSION or XRAY_CORE_REPO"
  if [ "$arch" = arm64 ]; then want="$(read_pin "$pin" XRAY_CORE_SHA256_ARM64)"; zipname=Xray-linux-arm64-v8a.zip
  else want="$(read_pin "$pin" XRAY_CORE_SHA256_AMD64)"; zipname=Xray-linux-64.zip; fi
  [ -n "$want" ] || die "$pin has no SHA-256 for $zipname: refusing to install an unverified core"
  zip="$dest/$zipname"
  if [ -n "$offline" ]; then
    [ -r "$offline" ] || die "cannot read $offline"
    cp "$offline" "$zip"
  else
    url="https://github.com/$repo/releases/download/$version/$zipname"
    log "  downloading $url"
    curl -fL --proto '=https' --tlsv1.2 --retry 3 --max-time 300 -o "$zip" "$url" || die "download failed: $url"
  fi
  got="$(sha256_of "$zip")"
  if [ "$got" != "$want" ]; then
    rm -f "$zip"
    die "sha256 of the Xray core download ($got) does not match the pinned value ($want). Nothing was installed. If you are deliberately moving the pin, update config/xray-core.env; CASAVPN_XRAY_CORE=bundled skips the pin."
  fi
  ok "Xray core sha256 matches the pinned value ($version, $arch)"
  python3 -I "$(dirname "${BASH_SOURCE[0]}")/extract_zip_member.py" "$zip" xray "$dest/xray" \
    || die "could not unpack the xray binary from $zipname; nothing was installed"
  chmod 0755 "$dest/xray"
  got="$(xray_version "$dest/xray")"
  [ "$got" = "${version#v}" ] || die "the downloaded core reports version '${got:-none}', not ${version#v}: it will not run here, or is not the pinned release. Nothing was installed."
}

# install_xray_core <xui-dir> <staged-binary>
# Puts the core over <xui-dir>/bin/xray-linux-<arch> atomically (a .new file and
# mv -f: a plain cp fails with "Text file busy" on a running binary). The core
# 3x-ui shipped is kept once as xray-linux-<arch>.bundled.
install_xray_core() {
  local dir="$1" staged="$2" arch target
  arch="$(xui_arch)" || return 1
  target="$dir/bin/xray-linux-$arch"
  mkdir -p "$dir/bin"
  if [ -e "$target" ] && [ ! -e "$target.bundled" ]; then
    if ! { cp -p "$target" "$target.bundled.new" && mv -f "$target.bundled.new" "$target.bundled"; }; then
      rm -f "$target.bundled.new"; die "could not keep the bundled core as $target.bundled; nothing was replaced"
    fi
  fi
  if ! { install -m 0755 "$staged" "$target.new" && mv -f "$target.new" "$target"; }; then
    rm -f "$target.new"; die "could not install the Xray core to $target"
  fi
}

# restore_bundled_core <xui-dir>: put <target>.bundled back (atomically). Returns 1 if there is none.
restore_bundled_core() {
  local dir="$1" arch target
  arch="$(xui_arch)" || return 1
  target="$dir/bin/xray-linux-$arch"
  [ -e "$target.bundled" ] || return 1
  if ! { cp -p "$target.bundled" "$target.new" && mv -f "$target.new" "$target"; }; then
    rm -f "$target.new"; return 1
  fi
}

# panel_cred <KEY>: a value from /etc/casavpn/panel-credentials.env (root only).
panel_cred() {
  local f="${CASAVPN_PANEL_CREDS:-/etc/casavpn/panel-credentials.env}"
  [ -r "$f" ] || return 1
  grep -E "^$1=" "$f" | tail -n1 | cut -d= -f2-
}

# backup_foreign <path>: copy a file we are about to replace unless it is ours.
backup_foreign() {
  local f="$1"
  [ -e "$f" ] || return 0
  if grep -q 'CasaVPN' "$f" 2>/dev/null; then return 0; fi
  [ -e "$f.pre-casavpn" ] && return 0
  act cp -p "$f" "$f.pre-casavpn"
  log "  kept the previous $f as $f.pre-casavpn"
}
